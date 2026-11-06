//
//  SDPCodecFilter.swift
//  MeetingKit
//
//  把 SDP 里的视频编码收窄到 H.264。
//
//  为什么必须做这件事：WebRTC 的默认视频编码顺序是 VP8 优先，Chrome 的
//  offer 也把 VP8 排在前面；answer 只能按 offer 的顺序挑一个，于是协商
//  结果就是 VP8。iOS 上没有 VP8 硬件编码器，880×1920@24fps 的屏幕内容
//  全靠 CPU 软编——真机上的表现是：
//
//    · SCK 出了 319 帧，framesEncoded 只有 37 帧（编码器跟不上）；
//    · 每帧只切出 2.8 个 RTP 包（约 3.5KB），画面糊成块；
//    · 帧率掉到 7fps，看着就是"特别卡"。
//
//  H.264 在 iPhone 上是硬件编码，同样画质 CPU 占用低一个数量级。
//  浏览器侧（Chrome / Safari / Edge）都支持 H.264，不会有兼容性损失。
//
//  做法是在 SDP 落地前把每条 `m=video` 的 payload 列表收窄成
//  「H264 + 它对应的 RTX」。不改 a=rtpmap 等属性行——多余的行不会
//  影响协商，但删错了会让 SDP 不合法。
//

import Foundation

enum SDPCodecFilter {

    /// 只保留 H.264（及其重传通道）。没有 H264 时原样返回。
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
}
