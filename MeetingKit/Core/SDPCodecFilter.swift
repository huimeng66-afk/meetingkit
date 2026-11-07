// SDPCodecFilter.swift
// 本地视频编码筛选；保持 WebRTC 声明的 profile、level 和 packetization 原文。
// 远端描述必须原样交给 WebRTC，不能通过改 SDP 伪造对端解码能力。

import Foundation

enum SDPCodecFilter {

    /// 仅筛选 H.264 及其 RTX，不修改或补造 fmtp 能力参数。
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
            index = end
        }

        return lines.joined(separator: eol)
    }

    /// 把本地描述里 H.264 的 `profile-level-id` 抬到 Level 4.0（0x28）。
    ///
    /// 为什么必须有这一步：WebRTC M140 的 iOS 编码器（RTCVideoEncoderH264）
    /// 会把**协商到的 level** 原样交给 VideoToolbox
    /// （`kVTCompressionPropertyKey_ProfileLevel = ExtractProfile(level)`，
    /// 见 sdk/objc/components/video_codec/RTCVideoEncoderH264.mm）。
    /// Chrome / Android 的 offer 里 H.264 只有 `42001f`（Baseline **3.1**），
    /// 而 Level 3.1 的帧尺寸上限是 3600 个宏块 = 1280×720；手机竖屏整屏
    /// 880×1920 是 6600 个宏块，超出 83%，VideoToolbox 每帧都拒绝，
    /// 现场就是「采集出帧 321 / 编码 32 / 对端一直黑」。
    /// 抬到 4.0（8192 宏块）后编码器才肯按整屏出帧。
    ///
    /// 只改 level 这一个字节：profile_idc 与 constraint flags 原样保留。
    /// 接收端以码流 SPS 里的真实 level 为准，不看 fmtp，所以不会解不了。
    /// 已经 ≥ 4.0 的描述原样返回（幂等，不会把 5.x 降下来）。
    /// 把 H.264 的 `profile-level-id` 抬到 4.0。
    ///
    /// # ⚠️ 不要在 setLocalDescription 之前调用
    ///
    /// 1.9.9 试过一次，直接造成「扩展出帧 172 / 已推 RTC 169 / 发送 0 包 /
    /// 编码 0 帧」。原因是这行 fmtp 并不是"告诉对端我能编多大"，而是
    /// **本端编码器的构造参数**：`setLocalDescription` 会把它解析进
    /// VideoChannel 的 `send_codecs_`，`RTCVideoEncoderH264` 拿到后原样映射成
    /// `kVTCompressionPropertyKey_ProfileLevel`。把 `42001f` 改写成 `420028`
    /// 之后，部分 iPhone 上 VideoToolbox 直接建不出 session。
    ///
    /// 正确做法是让 level 保持协商值，尺寸/码率走 `encodings`、
    /// `maxFramerate` 与 `adaptOutputFormat`。
    ///
    /// 保留这个函数只是为了做离线实验（对一份 SDP 字符串做纯文本变换），
    /// 代码里**不允许**把它接回发送路径。
    @available(*, deprecated, message: "会破坏 VideoToolbox 会话初始化，禁止用于 setLocalDescription")
    static func raiseH264Level(_ sdp: String) -> String {
        guard sdp.contains("m=video"), sdp.contains("profile-level-id=") else { return sdp }
        let eol = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: eol)
        var changed = false
        for index in lines.indices where lines[index].hasPrefix("a=fmtp:") {
            let line = lines[index]
            guard let keyRange = line.range(of: "profile-level-id=") else { continue }
            let rest = line[keyRange.upperBound...]
            let value = String(rest.prefix(while: { $0 != ";" && $0 != " " }))
            guard value.count == 6,
                  let level = UInt8(value.suffix(2), radix: 16),
                  level < 0x28 else { continue }
            let head = value.prefix(4)
            let valueEnd = rest.index(rest.startIndex, offsetBy: value.count)
            let fullRange = keyRange.lowerBound..<valueEnd
            lines[index] = line.replacingCharacters(
                in: fullRange,
                with: "profile-level-id=\(head)28"
            )
            changed = true
        }
        return changed ? lines.joined(separator: eol) : sdp
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
    /// 仅作诊断；实际发送约束由 WebRTC 对真实 offer/answer 协商得到。
    static func h264Level(in sdp: String?) -> String {
        guard let sdp, !sdp.isEmpty else { return "-" }
        let lines = sdp.components(separatedBy: sdp.contains("\r\n") ? "\r\n" : "\n")
        for line in lines where line.hasPrefix("a=fmtp:") {
            guard let range = line.range(of: "profile-level-id=") else { continue }
            let value = String(line[range.upperBound...].prefix(while: { $0 != ";" && $0 != " " }))
            guard value.count == 6,
                  let level = UInt8(value.suffix(2), radix: 16) else { continue }
            return String(format: "L%.1f", Double(level) / 10.0)
        }
        return "-"
    }

    // MARK: - 起始码率

    /// 给每条「能发视频」的 m-line 的 H.264 fmtp 写 `x-google-start-bitrate`。
    ///
    /// 这是从 LiveKit 的 `Transport.mungeVideoStartBitrate` 搬过来的做法
    /// （client-sdk-swift / client-sdk-js / rust-sdks / client-sdk-android 四端一致）：
    ///
    /// > libwebrtc 给每条新的视频 send stream 固定 300kbps 起步，跟 encodings 的
    /// > maxBitrate 无关，所以刚发布的那几秒画面必然糊。
    ///
    /// 真机上这就是「目标码率 194kbps / 可用上行 301kbps / 受限 无 / host→host /
    /// RTT 8ms」的来源：局域网明明有几十兆，估计器却从 300k 起步，再叠加 ALR 死锁
    /// （发得少 → 不探测 → 涨不上去），永远爬不出来。
    ///
    /// 两个必须遵守的细节，都是踩过的坑：
    ///
    /// 1. **只写 start，绝不写 `x-google-max-bitrate`**。libwebrtc 会把这两个参数
    ///    从 m-line 提升到整个 `Call`（`WebRtcVideoSendChannel::ApplyChangedParams`
    ///    → `SetSdpBitrateParameters`），而 `RtpBitrateConfigurator` 每条连接只有
    ///    一份配置。写 max 就把"单条轨的上限"变成了"整条连接的总上限"，
    ///    并发轨道会被饿死。单轨上限只属于 `encodings.maxBitrateBps`。
    ///
    /// 2. **所有能发的 video m-line 写同一个值**。同样是 Call 级单份配置，
    ///    写不同的值等于"按 m-line 顺序后者覆盖前者"，行为不可预期。
    ///
    /// `recvonly` / `inactive` 的 m-line 不写：它们不发送，写了只会让同一个
    /// payload type 在不同 m-line 上参数不一致，libwebrtc 会报
    /// "A BUNDLE group contains a codec collision"。
    static func injectStartBitrate(_ sdp: String, kbps: Int) -> String {
        // 低于 300k 不给提示：LiveKit 的经验是，这个量级下把起点抬高
        // 付出的代价比省下的爬升时间更大。
        guard kbps >= 300, sdp.contains("m=video") else { return sdp }

        let eol = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: eol)
        var index = 0
        var modified = false

        while index < lines.count {
            guard lines[index].hasPrefix("m=video") else {
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count, !lines[end].hasPrefix("m=") { end += 1 }

            var sending = true
            var h264Payloads: Set<String> = []
            for i in index..<end {
                let line = lines[i]
                if line == "a=recvonly" || line == "a=inactive" { sending = false }
                guard line.hasPrefix("a=rtpmap:") else { continue }
                let body = line.dropFirst("a=rtpmap:".count)
                guard let space = body.firstIndex(of: " ") else { continue }
                let payload = String(body[body.startIndex..<space])
                let codec = String(body[body.index(after: space)...])
                if codec.uppercased().hasPrefix("H264") { h264Payloads.insert(payload) }
            }

            guard sending, !h264Payloads.isEmpty else {
                index = end
                continue
            }

            var patched: Set<String> = []
            var cursor = index
            while cursor < end {
                defer { cursor += 1 }
                guard lines[cursor].hasPrefix("a=fmtp:") else { continue }
                let body = lines[cursor].dropFirst("a=fmtp:".count)
                guard let space = body.firstIndex(of: " ") else { continue }
                let payload = String(body[body.startIndex..<space])
                guard h264Payloads.contains(payload) else { continue }
                let params = String(body[body.index(after: space)...])
                lines[cursor] = "a=fmtp:" + payload + " " + setFmtp(params, key: "x-google-start-bitrate", value: "\(kbps)")
                patched.insert(payload)
                modified = true
            }
            /* 只有 rtpmap 没有 fmtp 的 H.264 payload：补一行。
               少了它，选中的编码就没有起始码率提示。 */
            var appended: [String] = []
            for payload in h264Payloads.sorted() where !patched.contains(payload) {
                appended.append("a=fmtp:\(payload) x-google-start-bitrate=\(kbps)")
                modified = true
            }
            if !appended.isEmpty {
                lines.insert(contentsOf: appended, at: end)
                index = end + appended.count
            } else {
                index = end
            }
        }

        return modified ? lines.joined(separator: eol) : sdp
    }

    /// 在 `a=fmtp` 的参数串里设置一个键值：有就替换，没有就追加。
    private static func setFmtp(_ params: String, key: String, value: String) -> String {
        var parts = params.components(separatedBy: ";")
        var replaced = false
        var i = 0
        while i < parts.count {
            let trimmed = parts[i].trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix(key.lowercased() + "=") {
                parts[i] = "\(key)=\(value)"
                replaced = true
            }
            i += 1
        }
        if !replaced { parts.append("\(key)=\(value)") }
        return parts.joined(separator: ";")
    }
}
