//
//  SDPCodecFilter.swift
//  MeetingKit
//
//  把 SDP 里的视频编码收窄到 H.264，并把 H.264 的 level 抬到 4.0。
//
//  一、为什么要收窄到 H.264
//  WebRTC 的默认视频编码顺序是 VP8 优先，Chrome 的 offer 也把 VP8
//  排在前面；answer 只能按 offer 的顺序挑一个，于是协商结果就是 VP8。
//  iOS 上没有 VP8 硬件编码器，880×1920@24fps 的屏幕内容全靠 CPU 软编，
//  真机表现：SCK 出 319 帧、framesEncoded 只有 37 帧，每帧 2.8 个 RTP 包。
//  H.264 在 iPhone 上是硬件编码，同样画质 CPU 占用低一个数量级。
//
//  二、为什么还要抬 level（1.8.1 的关键修复）
//  Chrome 的 offer 里 H.264 只有 `profile-level-id=42001f`：
//  Baseline / **Level 3.1**。libwebrtc 会把这个 level 原样交给
//  VideoToolbox（映射到 `kVTProfileLevel_H264_Baseline_3_1`），
//  而 Level 3.1 的帧尺寸上限是 3600 个宏块（1280×720）。
//
//  手机整屏 880×1920 = 55×120 = **6600 个宏块**，超出上限 83%。
//  VideoToolbox 对每一帧都返回失败，libwebrtc 只能丢掉：
//  真机日志是「SCK 出帧 321 · 编码 32 帧 · 发送 50 包 · 目标码率 194kbps」，
//  浏览器每秒收到两三帧、每帧 1.8KB，解码出来就是**整块灰 / 画面冻住**。
//  注意这时 qualityLimitationReason 报的是 `none`——编码失败不算带宽/CPU 受限，
//  所以诊断面板一直"看起来正常"，问题被藏了整整三个版本。
//
//  Level 4.0（0x28）的上限是 8192 宏块 / 245760 宏块每秒，
//  880×1920@24fps = 158400 宏块每秒，只占 64% 的预算，编码器不再丢帧。
//
//  只改 level 那一个字节，profile_idc 与 constraint flags 原样保留：
//  `42001f → 420028`、`42e01f → 42e028`、`64001f → 640028`。
//  浏览器（Chrome / Safari / Edge 的 FFmpeg 解码器）以码流 SPS 里的真实
//  level 为准，不看 fmtp，所以不会因为这一改而解不了。
//
//  三、改法
//  在 SDP 落地前：收窄每条 `m=video` 的 payload 列表为「H264 + 它对应的 RTX」，
//  同时把每个 H264 payload 的 `a=fmtp` 里 `profile-level-id` 的 level 抬到 0x28。
//  不改其它属性行——多余的行不影响协商，删错了会让 SDP 不合法。
//

import Foundation

enum SDPCodecFilter {

    /// 目标 level：0x28 = Level 4.0（8192 宏块 / 245760 宏块每秒）。
    /// 再高没有必要：Level 5.x 只会让老设备更谨慎，4.0 已经覆盖整屏 4K 纵向。
    private static let targetLevelHex = "28"

    /// 只保留 H.264（及其重传通道），并把 level 抬到 4.0。没有 H264 时原样返回。
    static func preferH264Only(_ sdp: String) -> String {
        guard sdp.contains("m=video") else { return sdp }

        let eol = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: eol)
        var index = 0

        while index < lines.count {
            guard lines[index].hasPrefix("m=video") else {
                index += 1
                continue
            }

            // 一条 m-line 的段落到下一条 m= 为止。
            var end = index + 1
            while end < lines.count, !lines[end].hasPrefix("m=") { end += 1 }

            var h264Payloads: Set<String> = []
            var rtxPayloads: Set<String> = []
            var codecByPayload: [String: String] = [:]

            for line in lines[index..<end] where line.hasPrefix("a=rtpmap:") {
                let body = line.dropFirst("a=rtpmap:".count)
                guard let space = body.firstIndex(of: " ") else { continue }
                let payload = String(body[body.startIndex..<space])
                let codec = String(body[body.index(after: space)...])
                codecByPayload[payload] = codec
                if codec.uppercased().hasPrefix("H264") {
                    h264Payloads.insert(payload)
                }
            }

            // 没有 H264 就说明对端根本不支持，硬改会得到一条没有任何
            // 可用编码的 m-line，协商直接失败。原样放行。
            guard !h264Payloads.isEmpty else {
                index = end
                continue
            }

            /* RTX 是 NACK 重传用的独立 payload，`a=fmtp:<rtx> apt=<h264>`。
               丢了它，丢包只能等关键帧，弱网下画面会有明显停顿。 */
            for line in lines[index..<end] where line.hasPrefix("a=fmtp:") {
                let body = line.dropFirst("a=fmtp:".count)
                guard let space = body.firstIndex(of: " ") else { continue }
                let payload = String(body[body.startIndex..<space])
                let params = String(body[body.index(after: space)...])
                guard let aptRange = params.range(of: "apt=") else { continue }
                let rest = params[aptRange.upperBound...]
                let apt = String(rest.prefix(while: { $0 != ";" && $0 != " " }))
                guard h264Payloads.contains(apt) else { continue }
                if codecByPayload[payload]?.lowercased().hasPrefix("rtx") == true {
                    rtxPayloads.insert(payload)
                }
            }

            /* 抬 level。必须在收窄 payload 之前做：这一遍扫的是原始段，
               不依赖 m-line 头有没有改过。 */
            var levelPatched: Set<String> = []
            var cursor = index
            while cursor < end {
                defer { cursor += 1 }
                guard lines[cursor].hasPrefix("a=fmtp:") else { continue }
                let body = lines[cursor].dropFirst("a=fmtp:".count)
                guard let space = body.firstIndex(of: " ") else { continue }
                let payload = String(body[body.startIndex..<space])
                guard h264Payloads.contains(payload) else { continue }
                let params = String(body[body.index(after: space)...])
                lines[cursor] = "a=fmtp:" + payload + " " + raiseLevel(in: params)
                levelPatched.insert(payload)
            }
            /* 只声明了 rtpmap 没有 fmtp 的 payload（少数浏览器会这样）：
               补一行。少了 level 声明，libwebrtc 会按 Level 3.1 处理。 */
            var appended: [String] = []
            for payload in h264Payloads.sorted() where !levelPatched.contains(payload) {
                appended.append("a=fmtp:\(payload) profile-level-id=42e028")
            }

            let parts = lines[index].components(separatedBy: " ")
            guard parts.count > 3 else {
                index = end
                continue
            }
            let header = parts.prefix(3).joined(separator: " ")
            let kept = parts.dropFirst(3).filter {
                h264Payloads.contains($0) || rtxPayloads.contains($0)
            }
            guard !kept.isEmpty else {
                index = end
                continue
            }
            lines[index] = header + " " + kept.joined(separator: " ")
            if !appended.isEmpty {
                lines.insert(contentsOf: appended, at: end)
            }
            index = end + appended.count
        }

        return lines.joined(separator: eol)
    }

    /// 把 `profile-level-id` 的 level 字节抬到 0x28，profile 与约束位不动。
    /// 参数串形如 `level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f`。
    private static func raiseLevel(in params: String) -> String {
        var parts = params.components(separatedBy: ";")
        var found = false
        var i = 0
        while i < parts.count {
            let trimmed = parts[i].trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("profile-level-id=") {
                found = true
                let value = String(trimmed.dropFirst("profile-level-id=".count))
                parts[i] = "profile-level-id=" + raisedLevelValue(value)
            }
            i += 1
        }
        if !found {
            parts.append("profile-level-id=42e028")
        }
        return parts.joined(separator: ";")
    }

    /// `42001f` → `420028`；已经是 0x28 及以上的原样返回。
    private static func raisedLevelValue(_ hex: String) -> String {
        // profile-level-id 固定 6 位十六进制：profile_idc(2) + 约束位(2) + level(2)
        guard hex.count == 6 else { return "42e028" }
        let prefix = String(hex.prefix(4))
        guard let level = UInt8(String(hex.suffix(2)), radix: 16) else {
            return prefix + targetLevelHex
        }
        if level >= 0x28 { return hex }
        return prefix + targetLevelHex
    }

    /// 从 SDP 里读出第一条 video m-line 实际会用的编码名，仅供诊断显示。
    static func videoCodecName(in sdp: String?, preferredPayload: String? = nil) -> String {
        guard let sdp, !sdp.isEmpty else { return "-" }
        let lines = sdp.components(separatedBy: sdp.contains("\r\n") ? "\r\n" : "\n")
        var inVideo = false
        var order: [String] = []
        var names: [String: String] = [:]

        for line in lines {
            if line.hasPrefix("m=") {
                inVideo = line.hasPrefix("m=video")
                if inVideo {
                    order = line.components(separatedBy: " ").dropFirst(3).map { $0 }
                }
                continue
            }
            guard inVideo, line.hasPrefix("a=rtpmap:") else { continue }
            let body = line.dropFirst("a=rtpmap:".count)
            guard let space = body.firstIndex(of: " ") else { continue }
            let payload = String(body[body.startIndex..<space])
            let codec = String(body[body.index(after: space)...])
            names[payload] = codec.components(separatedBy: "/").first ?? codec
        }
        guard !order.isEmpty else { return "-" }
        let picked = preferredPayload.flatMap { names[$0] } ?? order.compactMap { names[$0] }.first
        return picked ?? "-"
    }

    /// 本地 SDP 里 H.264 实际声明的 level，形如 `L4.0`，仅供诊断显示。
    /// 这一项要是 `L3.1`，880×1920 的整屏必被编码器丢弃，看到就该报警。
    static func h264Level(in sdp: String?) -> String {
        guard let sdp, !sdp.isEmpty else { return "-" }
        for line in sdp.components(separatedBy: sdp.contains("\r\n") ? "\r\n" : "\n")
        where line.hasPrefix("a=fmtp:") {
            guard let range = line.range(of: "profile-level-id=") else { continue }
            let value = String(line[range.upperBound...].prefix(while: { $0 != ";" && $0 != " " }))
            guard value.count == 6,
                  let level = UInt8(value.suffix(2), radix: 16) else { continue }
            return String(format: "L%.1f", Double(level) / 10.0)
        }
        return "-"
    }
}
