//
//  PeerSession.swift
//  MeetingKit
//
//  单个远端参会者的 WebRTC 连接。P2P Mesh 下每人与每人一条连接，
//  本类管理一条连接的全部生命周期：SDP 协商、ICE 候选、轨道收发、ICE restart。
//
//  协商规则（与 Web 端 room.js 完全一致的 Perfect Negotiation）：
//    · polite 方 = peerId 字符串较小的一方（两端用同一规则，天然无冲突）；
//    · 双方同时 offer（glare）时 polite 方让路：rollback 自己的 offer、应答对方；
//    · 远端描述就绪前的远端候选先入队，setRemoteDescription 完成后统一冲刷；
//    · 本地候选一律直接发送，绝不与远端候选混用队列；
//    · ICE 连续失败时做 ICE restart（createOffer iceRestart:true），
//      多次 restart 无效则通知上层重建整个连接。
//
//  线程模型：本类隔离到 @MainActor。WebRTC 的 delegate 回调与 completion
//  都在库内部线程，统一 Task { @MainActor } 汇流后再碰状态，
//  保证 makingOffer / pendingRemoteCandidates 等协商状态只被主线程读写。
//

import Foundation
import WebRTC

// MARK: - 会话事件

@MainActor
protocol PeerSessionDelegate: AnyObject {

    /// 需要把 SDP 发给对端。restart 标记这是 ICE restart 产生的 offer。
    func peerSession(_ session: PeerSession, needsSignalSDP sdp: RTCSessionDescription, restart: Bool)

    /// 需要把 ICE 候选发给对端。
    func peerSession(_ session: PeerSession, needsSignalCandidate candidate: RTCIceCandidate)

    /// 连接状态变化（用于断线判定与统计）。
    func peerSession(_ session: PeerSession, didChangeConnectionState state: RTCPeerConnectionState)

    /// 收到远端视频流（摄像头或屏幕共享——共享由服务端 screen:state 事件区分，
    /// 因为 Web 端共享走 replaceTrack，链路里是同一条视频轨道）。
    func peerSession(_ session: PeerSession, didReceiveRemoteVideo track: RTCVideoTrack)

    /// 本地 ICE 彻底失败（多次 restart 无效），请求重建连接。
    func peerSessionNeedsRebuild(_ session: PeerSession)
}

// MARK: - 会话

@MainActor
final class PeerSession: NSObject {

    let peerID: String
    let polite: Bool
    private(set) var isClosed = false

    weak var delegate: PeerSessionDelegate?

    let peerConnection: RTCPeerConnection

    // MARK: 远端轨道

    private(set) var remoteAudioTrack: RTCAudioTrack?
    /// 远端视频轨道。共享期间内容为屏幕画面（replaceTrack），区分靠 screen:state 事件。
    private(set) var remoteVideoTrack: RTCVideoTrack?

    /// 远端视频渲染视图（RTCMTLVideoView），收到 track 时创建。
    private(set) var remoteVideoView: RTCMTLVideoView?

    /// 本端唯一的视频发送通道。
    ///
    /// 必须缓存引用：共享结束时会 `sender.track = 摄像头轨`，摄像头关闭时会
    /// `sender.track = nil`；一旦 track 变成 nil，`senders.first(where: { $0.track?.kind == "video" })`
    /// 就再也找不到它，第二次开共享直接推不上去——这正是"关了重新开就不行"的成因。
    private var videoSender: RTCRtpSender?

    // MARK: 协商状态

    private var makingOffer = false
    private var ignoreOffer = false
    /// 只存“远端候选”（远端描述就绪前到达的）；本地候选一律直接发送。
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var isNegotiating = false
    private var iceRestartCount = 0
    private var isRestartingIce = false
    /// ICE restart 请求到达时恰好在协商中：等回到 stable 再补发。
    private var needsRestartAfterStable = false

    private static let maxIceRestarts = 3

    // MARK: - 初始化

    init?(
        factory: RTCPeerConnectionFactory,
        peerID: String,
        iceServers: [RTCIceServer],
        polite: Bool
    ) {
        self.peerID = peerID
        self.polite = polite

        let config = RTCConfiguration()
        config.iceServers = iceServers
        // ICE 走 bundle，减少候选数量与协商轮次。
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.tcpCandidatePolicy = .enabled
        // 默认连续打洞。对 P2P Mesh 来说持续连接性优先。
        config.continualGatheringPolicy = .gatherContinually
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let pc = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: nil
        ) else {
            // 资源耗尽 / factory 状态异常：返回 nil，由上层跳过该 peer 并提示。
            print("[peer] RTCPeerConnection 创建失败：factory 状态异常")
            return nil
        }
        peerConnection = pc
        super.init()
        pc.delegate = self
    }

    deinit {
        // @MainActor 类的 deinit 是 nonisolated 的，不能访问隔离属性；
        // 关闭统一由上层（RealRTCClient）在 peer 离开时调用 close()，
        // RTCPeerConnection 本身会在释放时自清理。
    }

    // MARK: - 本地轨道

    /// 加入本地收发轨道。重复调用安全（先移除旧 sender 再重加）。
    /// 屏幕共享不走单独轨道：与 Web 端一致，共享时 replaceTrack 替换 video sender。
    func attachLocalTracks(audio: RTCAudioTrack?, video: RTCVideoTrack?) {
        let streamID = "tq-\(peerID)"

        if let audio = audio {
            ensureSender(for: audio, streamID: streamID)
        }
        if let video = video {
            ensureSender(for: video, streamID: streamID)
        }
    }

    /// 屏幕共享：用 screen 替换当前的 video sender（Web 端同款 replaceTrack 策略）。
    /// track 为 nil 时移除上行视频（结束共享且本端无摄像头）。
    func replaceVideoTrack(with track: RTCVideoTrack?) {
        guard let sender = videoSender ?? senderForVideoTrack() else {
            /* 一条 video sender 都没有（例如对端加入时本端摄像头是关的、
               共享又刚被停掉）：直接补一条上行轨，让它走一次重新协商。
               原来的实现这里直接 return，第二次开共享就永远推不上去。 */
            if let track = track {
                peerConnection.add(track, streamIds: ["tq-\(peerID)"])
                videoSender = senderForVideoTrack()
            }
            return
        }
        videoSender = sender
        sender.track = track
    }

    /// 记录并返回当前 video sender。sender.track 可能为 nil（关闭视频时），
    /// 所以不能只靠 `track?.kind` 反查，必须缓存引用。
    private func senderForVideoTrack() -> RTCRtpSender? {
        peerConnection.senders.first(where: { $0.track?.kind == "video" })
    }

    /// 调整上行视频编码参数。屏幕共享是"文字优先"，需要比摄像头更高的码率上限，
    /// 否则 1080p 画面会被 WebRTC 按摄像头模型压到 1~2Mbps，文字边缘发糊。
    func setVideoEncoding(maxBitrateBps: Int?, maxFramerate: Int?, keepResolution: Bool = false) {
        // 同样不能只靠 track.kind 反查：共享结束、摄像头关闭之后 track 可能是 nil。
        guard let sender = videoSender ?? senderForVideoTrack() else {
            return
        }
        videoSender = sender
        // RTCRtpSender.parameters 是非可选属性（M140 起），不能做可选绑定。
        let params = sender.parameters
        for encoding in params.encodings {
            if let bps = maxBitrateBps {
                encoding.maxBitrateBps = NSNumber(value: bps)
            }
            if let fps = maxFramerate {
                encoding.maxFramerate = NSNumber(value: fps)
            }
        }
        // 共享文档时宁可掉帧也不降分辨率，否则 1080p 会被降成 720p 再放大，文字糊成一片。
        // 注意：RTCRtpParameters.degradationPreference 是 NSNumber（包 RTCDegradationPreference），
        // 不是枚举本身，直接赋 .maintainResolution 编译不过。
        let preference: RTCDegradationPreference = keepResolution ? .maintainResolution : .balanced
        params.degradationPreference = NSNumber(value: preference.rawValue)
        sender.parameters = params
    }

    private func ensureSender(for track: RTCMediaStreamTrack, streamID: String) {
        // 同一 track 只挂一个 sender，重复 attach 不产生第二个上行流。
        if peerConnection.senders.contains(where: { $0.track?.trackId == track.trackId }) {
            if track.kind == "video", videoSender == nil {
                videoSender = peerConnection.senders.first(where: { $0.track?.trackId == track.trackId })
            }
            return
        }
        peerConnection.add(track, streamIds: [streamID])
        if track.kind == "video" {
            videoSender = peerConnection.senders.first(where: { $0.track?.trackId == track.trackId })
        }
    }

    // MARK: - 远端信号

    func handleRemoteSDP(_ raw: [String: Any]) {
        guard
            let type = raw["type"] as? String,
            let sdpString = raw["sdp"] as? String
        else { return }

        let description = RTCSessionDescription(type: Self.sdpType(from: type), sdp: sdpString)

        switch description.type {
        case .offer:
            handleRemoteOffer(description)
        case .answer:
            handleRemoteAnswer(description)
        default:
            break
        }
    }

    func handleRemoteCandidate(_ raw: [String: Any]) {
        guard
            let sdpMid = raw["sdpMid"] as? String,
            let sdpMLineIndex = (raw["sdpMLineIndex"] as? NSNumber)?.intValue,
            let candidateString = raw["candidate"] as? String
        else { return }

        let candidate = RTCIceCandidate(sdp: candidateString, sdpMLineIndex: Int32(sdpMLineIndex), sdpMid: sdpMid)

        if peerConnection.remoteDescription == nil {
            // 远端描述还没落地：候选先排队，setRemoteDescription 后统一冲刷。
            pendingRemoteCandidates.append(candidate)
            return
        }
        addRemoteCandidate(candidate)
    }

    private func addRemoteCandidate(_ candidate: RTCIceCandidate) {
        peerConnection.add(candidate) { [weak self] error in
            Task { @MainActor in
                if error != nil {
                    // 单条候选失败不致命：STUN/TURN 会继续产生新的候选。
                    print("[peer] add candidate failed")
                }
            }
        }
    }

    // MARK: - ICE restart

    /// 主动发起 ICE restart（断线重连后恢复连接用）。
    func restartIce() {
        guard !isClosed else { return }
        guard !isRestartingIce else { return }
        guard peerConnection.signalingState == .stable else {
            // 正在协商中：回到 stable 后再补发。
            needsRestartAfterStable = true
            return
        }
        performIceRestart()
    }

    private func performIceRestart() {
        guard !makingOffer else { return }
        isRestartingIce = true
        needsRestartAfterStable = false
        makingOffer = true
        iceRestartCount += 1

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["IceRestart": kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil
        )
        peerConnection.offer(for: constraints) { [weak self] offer, error in
            Task { @MainActor in
                guard let self = self else { return }

                guard let offer = offer, error == nil else {
                    self.makingOffer = false
                    self.isRestartingIce = false
                    self.delegate?.peerSessionNeedsRebuild(self)
                    return
                }
                self.applyLocalDescriptionAndSignal(offer, restart: true) { [weak self] in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.makingOffer = false
                        self.isRestartingIce = false
                    }
                }
            }
        }
    }

    // MARK: - 渲染绑定

    /// 远端视频渲染视图。track 到位后由上层调用绑定 renderer。
    func makeRemoteVideoView() -> RTCMTLVideoView {
        if let existing = remoteVideoView {
            return existing
        }
        let view = RTCMTLVideoView(frame: .zero)
        // 等比显示：画面完整不裁切，比例不一致时两侧/上下留黑边（与网页端一致）。
        // RTCMTLVideoView 的 videoContentMode 是 RTCVideoContentMode，取值 .scaleAspectFit / .scaleAspectFill。
        view.videoContentMode = .scaleAspectFit
        view.backgroundColor = .black
        view.clipsToBounds = true
        remoteVideoView = view
        return view
    }

    /// 把远端 track 绑到渲染视图。
    func bindRemoteVideoRenderer() {
        guard let track = remoteVideoTrack, let view = remoteVideoView else { return }
        track.remove(view)
        track.add(view)
    }

    // MARK: - 关闭

    func close() {
        guard !isClosed else { return }
        isClosed = true
        makingOffer = false
        ignoreOffer = false
        isNegotiating = false
        isRestartingIce = false
        needsRestartAfterStable = false
        pendingRemoteCandidates.removeAll()

        if let track = remoteVideoTrack, let view = remoteVideoView {
            track.remove(view)
        }
        remoteVideoView = nil
        remoteVideoTrack = nil
        remoteAudioTrack = nil

        // 断开 delegate，防止旧会话迟到的回调再进入上层（避免误杀重建后的新会话）。
        peerConnection.delegate = nil
        delegate = nil
        peerConnection.close()
    }

    // MARK: - 私有：协商

    private static func sdpType(from string: String) -> RTCSdpType {
        switch string {
        case "offer":
            return .offer
        case "pranswer":
            return .prAnswer
        default:
            return .answer
        }
    }

    private func handleRemoteOffer(_ description: RTCSessionDescription) {
        // Perfect Negotiation 的 glare 处理（与 Web 端一致）：
        //  · 非礼貌方（impolite）在冲突时丢弃对方 offer；
        //  · 礼貌方 rollback 自己的 offer 后接受对方 offer。
        let collision = makingOffer || peerConnection.signalingState != .stable
        ignoreOffer = !polite && collision
        if ignoreOffer {
            return
        }

        isNegotiating = true

        if collision && polite {
            let rollback = RTCSessionDescription(type: .rollback, sdp: "")
            peerConnection.setLocalDescription(rollback) { [weak self] error in
                Task { @MainActor in
                    guard let self = self else { return }
                    // rollback 失败也继续尝试接受对方 offer（多半仍能成功）。
                    self.acceptRemoteOffer(description)
                }
            }
        } else {
            acceptRemoteOffer(description)
        }
    }

    private func acceptRemoteOffer(_ description: RTCSessionDescription) {
        peerConnection.setRemoteDescription(description) { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                if error != nil {
                    self.isNegotiating = false
                    // setRemoteDescription 失败通常意味着远端描述与本地状态冲突，
                    // 重建连接比继续纠缠更快恢复。
                    self.delegate?.peerSessionNeedsRebuild(self)
                    return
                }
                self.flushPendingRemoteCandidates()

                let constraints = RTCMediaConstraints(
                    mandatoryConstraints: nil,
                    optionalConstraints: nil
                )
                self.peerConnection.answer(for: constraints) { [weak self] answer, error in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.isNegotiating = false
                        guard let answer = answer, error == nil else {
                            self.delegate?.peerSessionNeedsRebuild(self)
                            return
                        }
                        self.applyLocalDescriptionAndSignal(answer, restart: false)
                    }
                }
            }
        }
    }

    private func handleRemoteAnswer(_ description: RTCSessionDescription) {
        guard peerConnection.signalingState == .haveLocalOffer else {
            // 过期 answer（对方在 glare 中让路的残留），直接丢弃。
            return
        }
        peerConnection.setRemoteDescription(description) { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                if error != nil {
                    self.delegate?.peerSessionNeedsRebuild(self)
                    return
                }
                self.flushPendingRemoteCandidates()
            }
        }
    }

    /// setLocalDescription 完成后读取 pc.localDescription 发送（Web 端同款：
    /// setLocalDescription 可能对 SDP 做补全/改写）。
    private func applyLocalDescriptionAndSignal(
        _ description: RTCSessionDescription,
        restart: Bool,
        onDone: (() -> Void)? = nil
    ) {
        peerConnection.setLocalDescription(description) { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                defer { onDone?() }
                if error == nil {
                    let toSend = self.peerConnection.localDescription ?? description
                    self.delegate?.peerSession(self, needsSignalSDP: toSend, restart: restart)
                } else {
                    self.delegate?.peerSessionNeedsRebuild(self)
                }
            }
        }
    }

    private func flushPendingRemoteCandidates() {
        let queue = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        for candidate in queue {
            addRemoteCandidate(candidate)
        }
    }

    /// 触发协商：polite 方的新 offer。onNegotiationNeeded 到达时调用。
    private func negotiate() {
        guard !isClosed else { return }
        guard !makingOffer, !isNegotiating else { return }
        guard peerConnection.signalingState == .stable else { return }

        makingOffer = true
        isNegotiating = true

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        peerConnection.offer(for: constraints) { [weak self] offer, error in
            Task { @MainActor in
                guard let self = self else { return }

                guard let offer = offer, error == nil else {
                    self.makingOffer = false
                    self.isNegotiating = false
                    self.delegate?.peerSessionNeedsRebuild(self)
                    return
                }
                // makingOffer 保持到 setLocalDescription 完成、SDP 发出之后，
                // 期间到达的远端 offer 才不会被误判为无冲突。
                self.applyLocalDescriptionAndSignal(offer, restart: false) { [weak self] in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.makingOffer = false
                        self.isNegotiating = false
                    }
                }
            }
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension PeerSession: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Task { @MainActor in
            guard !self.isClosed else { return }
            if stateChanged == .stable {
                self.flushPendingRemoteCandidates()
                if self.needsRestartAfterStable {
                    self.needsRestartAfterStable = false
                    self.performIceRestart()
                }
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // Unified Plan 下走 didAddReceiver 回调，这里不处理。
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        Task { @MainActor in
            self.negotiate()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            guard !self.isClosed else { return }
            switch newState {
            case .failed:
                // ICE 彻底失败：先做 restart，restart 次数用尽则重建。
                if self.iceRestartCount >= Self.maxIceRestarts {
                    self.delegate?.peerSessionNeedsRebuild(self)
                } else {
                    self.restartIce()
                }
            case .connected, .completed:
                self.iceRestartCount = 0
                self.isRestartingIce = false
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            guard !self.isClosed else { return }
            // 本地候选一律直接发送（ICE restart 期间同样要发）。
            self.delegate?.peerSession(self, needsSignalCandidate: candidate)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in
            self.delegate?.peerSession(self, didChangeConnectionState: newState)
        }
    }

    /// Unified Plan 轨道接收。参数名必须与 ObjC 导入签名完全一致
    /// （rtpReceiver / streams），否则不满足协议要求。
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        let track = rtpReceiver.track
        Task { @MainActor in
            guard let track = track, !self.isClosed else { return }
            switch track.kind {
            case "audio":
                if let audio = track as? RTCAudioTrack {
                    self.remoteAudioTrack = audio
                    audio.isEnabled = true
                }
            case "video":
                if let video = track as? RTCVideoTrack {
                    // 替换前把旧 track 从渲染视图上摘下来，
                    // 避免两条轨道同时向同一视图出帧。
                    if let old = self.remoteVideoTrack, old !== video, let view = self.remoteVideoView {
                        old.remove(view)
                    }
                    self.remoteVideoTrack = video
                    self.delegate?.peerSession(self, didReceiveRemoteVideo: video)
                }
            default:
                break
            }
        }
    }
}
