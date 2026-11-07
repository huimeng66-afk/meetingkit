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
    /// `round` 是这一轮协商的轮次号（offer 由本端生成，answer 回带对方的）。
    /// 对端必须用同一个值回话，否则无法判断一条 answer 属于哪一轮 offer。
    func peerSession(
        _ session: PeerSession,
        needsSignalSDP sdp: RTCSessionDescription,
        restart: Bool,
        round: String?
    )

    /// 需要把 ICE 候选发给对端。
    func peerSession(_ session: PeerSession, needsSignalCandidate candidate: RTCIceCandidate)

    /// 连接状态变化（用于断线判定与统计）。
    func peerSession(_ session: PeerSession, didChangeConnectionState state: RTCPeerConnectionState)

    /// 收到远端视频流（摄像头或屏幕共享——共享由服务端 screen:state 事件区分，
    /// 因为 Web 端共享走 replaceTrack，链路里是同一条视频轨道）。
    func peerSession(_ session: PeerSession, didReceiveRemoteVideo track: RTCVideoTrack)

    /// 收到远端音频轨。用来把音频会话抢回 playAndRecord + 扬声器：
    /// 屏幕共享扩展退出后系统可能把 route 留在 videoRecording（听筒、无播放），
    /// 表现就是"收到了包但没有声音"。
    func peerSession(_ session: PeerSession, didReceiveRemoteAudio track: RTCAudioTrack)

    /// 本地 ICE 彻底失败（多次 restart 无效），请求重建连接。
    func peerSessionNeedsRebuild(_ session: PeerSession)
}

extension PeerSessionDelegate {
    /// 默认空实现：不是每个实现方都关心音频轨到达。
    func peerSession(_ session: PeerSession, didReceiveRemoteAudio track: RTCAudioTrack) {}
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

    /// 视频收发器（Unified Plan 下一条 m-line 对应一个 transceiver）。
    ///
    /// 1.5.4 起共享换轨**不再 removeTrack + addTrack**：
    /// 那会新增第二条 m-line，浏览器同时收到两条视频轨，`<video>` 往往
    /// 只播第一条（摄像头黑轨），于是 iOS 这边"已推 358 帧"，网页永远
    /// 停在"正在接收共享画面…"。
    /// 正确做法是把原 transceiver 的方向拨回 sendRecv，再 replaceTrack，
    /// 全程只有一条视频 m-line。
    private var videoTransceiver: RTCRtpTransceiver?

    /// 屏幕共享专用发送通道（1.7.2）。
    ///
    /// 与 `videoSender` 分开保存：摄像头那条 m-line 全程不动，共享另开一条
    /// sendrecv m-line。原因见 `attachScreenTrack(_:)` 的注释——真机连续出现
    /// 「sender.track 就是共享轨、轨是开的、SDP 也允许发，编码器 0 帧」，
    /// 这条路只有在 m-line 本身不可发时才会出现，replaceTrack 救不回来。
    private var screenSender: RTCRtpSender?
    private var screenTransceiver: RTCRtpTransceiver?
    /// 共享 sender 是否已被判定为"不可救"（见 ensureScreenSender 的调用方）。
    private var screenSenderDead = false
    /// 当前共享 m-line 上挂的轨道 id。同一条轨重复 attach 时不重复开 m-line。
    private var screenTrackId: String?

    /// 本端音频发送通道。
    ///
    /// 与 videoSender 同理必须缓存：麦克风轨因设备切换 / 音频会话重建被整体替换时，
    /// 只能靠这个引用做 replaceTrack；靠 `senders.first(where: track?.kind == "audio")`
    /// 在 track 短暂为 nil 的瞬间会找不到 sender，声音就再也回不来。
    private var audioSender: RTCRtpSender?

    /// 本地轨道引用（与 sender 无关）。连接重建、sender 被移除后，
    /// 靠它把同一条麦克风轨重新挂回去。
    private var localAudio: RTCAudioTrack?
    private var localVideo: RTCVideoTrack?
    /// 屏幕轨。**入会首轮协商就挂上，整个会话不再增删**。
    /// 共享只是把它 enable，停止只是 disable——不产生任何重新协商。
    private var localScreen: RTCVideoTrack?

    // MARK: 协商状态

    /// 本地 offer 发出后等了多久还没等到 answer。nil 表示当前没在等。
    ///
    /// 一条 offer 卡在这里超过几秒，就说明对端根本没回 answer（浏览器端的
    /// glare 丢弃、信令没投递、或页面已卡死）。此时 sender 上挂着轨、
    /// 轨也是开的，但 WebRTC 永远不会为它建 VideoSendStream——
    /// 诊断上就是"共享轨已挂 + 编码 0 帧"。
    private var offerSentAt: Date?
    /// offer 已发出却没等到 answer 时的原样重发次数。
    /// 浏览器在 glare 里丢一次 offer 是正常现象，以前只能干等，
    /// 等到看门狗把整条连接拆掉——现在原样重发同一份 SDP 即可，代价几 KB。
    private var offerRetryCount = 0
    private var offerRetryTask: DispatchWorkItem?

    /* ------------------------- 协商轮次（rid） ------------------------- */

    /*
     * 为什么必须有这个东西：
     *
     * 安卓那边是"按 peerId 应答"的——它不区分这条 answer 属于哪一轮 offer。
     * 而本端一旦判定连接需要重建，会立刻 close 旧 session、建新 session、
     * 马上再发一份 offer，全程几百毫秒。于是出现这个闭环：
     *
     *   ① 旧 session 的 offer A 到了安卓，安卓答了 answer A；
     *   ② 本端此时已经换成新 session，并且发了 offer B；
     *   ③ answer A 到达，新 session 的 signalingState 恰好也是 haveLocalOffer，
     *      旧代码只看状态、不看内容，于是拿 answer A 去配 offer B；
     *   ④ setRemoteDescription 报 "answer 与当前 offer 不匹配"；
     *   ⑤ 失败回调直接触发重建 → 回到 ①。
     *
     * 现场表现就是每 240ms 一轮 offer/answer、永远 `等answer · ICE new`、
     * 编码器一次都没启动、连带音频也不通。日志里能直接数到
     * 8545B 的 offer 连续来两遍、9681B 再来两遍。
     *
     * 修法：给每份 offer 编一个进程内唯一（跨 session 也不重复）的轮次号，
     * 随信令一起发；answer 必须回带同一个号。号对不上就**丢弃**，
     * 既不 setRemote，也绝不重建——它本来就只是一条迟到的旧答案。
     */
    private static var roundSeq: Int = 0
    /// 当前这一轮发出去、还没被应答的 offer 轮次号。
    private var pendingOfferRound: String?
    /// 收到的远端 offer 的轮次号，本端生成 answer 时原样回带。
    private var remoteOfferRound: String?
    /// 最近一条 answer 的轮次号（无论是否被接受），供诊断核对。
    private var lastAnswerRound: String?
    /// 因轮次不匹配被丢弃的 answer 条数。
    private var droppedAnswerCount = 0
    /// 最近一次 setRemoteDescription 失败的错误原文。
    /// 以前这里只写 `if error != nil { rebuild }`，把唯一的现场证据扔了，
    /// 结果连续几轮都在编码器上找原因。
    private var lastRemoteSetError: String?
    /// answer 连续落地失败的次数。用于区分"偶发错配"和"这条连接真的不可救"。
    private var answerSetFailureCount = 0

    /// 诊断用：把轮次现场拼成一行。
    var negotiationTrace: String {
        let pending = pendingOfferRound ?? "-"
        let last = lastAnswerRound ?? "-"
        let err = lastRemoteSetError.map { " err=\($0.prefix(90))" } ?? ""
        return "rid 待=\(pending) 收=\(last) 丢=\(droppedAnswerCount)\(err)"
    }

    var pendingOfferAge: TimeInterval? {
        guard peerConnection.signalingState == .haveLocalOffer,
              let sentAt = offerSentAt else { return nil }
        return Date().timeIntervalSince(sentAt)
    }

    private var makingOffer = false
    private var ignoreOffer = false
    /// 只存“远端候选”（远端描述就绪前到达的）；本地候选一律直接发送。
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var isNegotiating = false
    private var iceRestartCount = 0
    private var isRestartingIce = false
    /// ICE restart 请求到达时恰好在协商中：等回到 stable 再补发。
    private var needsRestartAfterStable = false
    /// 有轨道要挂、但当时正在协商：等回到 stable 再补一次。
    ///
    /// 少了这一条，`negotiate()` 的 `guard !isNegotiating` 会把这次 addTrack
    /// 静默吞掉：本地轨永远没有对应的 m-line，answer 里 audio 是 recvonly，
    /// 表现就是"收得到对方的包，自己一个包都发不出去"。
    private var needsNegotiateAfterStable = false
    /// 正在处理远端 offer（setRemoteDescription → answer 之间）。
    /// 这段时间里 addTrack 触发的 negotiationneeded 不能立刻发 offer，
    /// 否则又造一次 glare；等 answer 落地后由 needsNegotiateAfterStable 收尾。
    private var isAcceptingRemoteOffer = false

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

    /// 加入本地收发轨道。重复调用安全。
    ///
    /// `screenTrack` 是屏幕轨：它和摄像头轨**同时**进首轮 offer，
    /// 各占一条 m-line。共享开始/结束时只改 `isEnabled`，不再 addTrack /
    /// removeTrack——中途重新协商一旦被 glare 或丢包卡住，本端所有自检
    /// （sender 挂着、轨开着、SDP 允许发）都会成立，而编码器一个包都发不出去。
    func attachLocalTracks(
        audio: RTCAudioTrack?,
        video: RTCVideoTrack?,
        screenTrack: RTCVideoTrack? = nil
    ) {
        // 记住轨道本身：PeerConnection 重建换的是连接，不是麦克风。
        // 没有这两个引用，重建后的新连接就只能空着——人还在，声音没了。
        if let audio = audio { localAudio = audio }
        if let video = video { localVideo = video }
        if let screenTrack = screenTrack { localScreen = screenTrack }

        ensureLocalSenders()
        /* addTrack 之后主动推一次协商。
           WebRTC 的 negotiationNeeded 在部分版本/时序下不会回调
           （尤其是刚 new 出来的 pc 第一次 addTrack），只赌它就会两边互等。 */
        negotiate()
    }

    /// 让本地音视频轨一定挂在当前连接上。
    ///
    /// 必须在 `setRemoteDescription` **之前**调用：远端 offer 一旦落地，
    /// 应答里的 m-line 方向就定死了。此时本地还没有 audio sender，
    /// answer 就是 recvonly——之后 addTrack 只能靠重新协商补救，
    /// 而重新协商一旦被协商状态吞掉，就再也不会发生。
    ///
    /// 屏幕轨同样在这里补：对方先发 offer 时，answer 里也必须有一条
    /// sendonly 的共享 m-line，否则共享阶段又得回头重新协商。
    func ensureLocalSenders() {
        let streamID = "tq-\(peerID)"
        if let audio = localAudio { ensureSender(for: audio, streamID: streamID) }
        if let video = localVideo { ensureSender(for: video, streamID: streamID) }
        if let screen = localScreen { ensureScreenSender(screen) }
    }

    /// 建共享 sender（幂等，不触发协商）。
    ///
    /// 方向固定 `.sendOnly`：本端从不需要收自己的屏幕。这样 offer 里
    /// 这条 m-line 是 `a=sendonly`，浏览器回 `a=recvonly`，方向天然正确，
    /// 不会出现"谈成 inactive 却以为能发"的情况。
    private func ensureScreenSender(_ track: RTCVideoTrack) {
        localScreen = track
        /* 幂等判断只看自己记的 trackId，**不看 `sender.track`**。
           M140 的 Swift 包装层里 `RTCRtpSender.track` 偶尔读回 nil，
           拿它判断"已经挂了"会假阴性：真机上每开一次共享就 add 一条新
           m-line（`SDP video 2` → `video 3`），方向判定被带偏、带宽被白吃。
           `screenTrackId` 是本端写死的字符串，永远读得到。 */
        if screenSender != nil, screenTrackId == track.trackId {
            return
        }
        /* 真有 sender 但 trackId 变了：**绝不 add**（多一条 m-line 的代价
           远大于黑屏：判定会错、共享会被判成"未进SDP"、每次共享再补协商）。
           但也不能什么都不做 —— 那样 sender 上留着的是上一次的旧轨，
           帧推到新轨上永远没人消费，现场就是"采集在出帧、编码 0 帧、
           sender 明明还在"。M140 的 `RTCRtpSender.track` 是可写属性，
           等价于 ObjC 的 replaceTrack：换轨不产生任何协商。 */
        if screenSender != nil, screenTrackId != nil {
            screenSender?.track = track
            screenTrackId = track.trackId
            localScreen = track
            return
        }
        guard let newSender = peerConnection.add(track, streamIds: ["screen-\(peerID)"]) else {
            return
        }
        screenSender = newSender
        screenTransceiver = peerConnection.transceivers.first { $0.sender.senderId == newSender.senderId }
        _ = screenTransceiver?.setDirection(.sendOnly, error: nil)
        screenTrackId = track.trackId
        screenSenderDead = false
    }

    /// 诊断用：当前挂着几条上行音频、轨道是什么状态。
    var audioSenderCount: Int {
        peerConnection.senders.filter { $0.track?.kind == "audio" }.count
    }

    var localAudioStateText: String {
        guard let track = localAudio else { return "无轨道" }
        let state: String
        switch track.readyState {
        case .live: state = "live"
        case .ended: state = "ended"
        @unknown default: state = "unknown"
        }
        return "\(track.isEnabled ? "开启" : "静音")/\(state)"
    }

    /// 上行音频发不出去时的补救：把 sender 拆了重挂，再走一次协商。
    ///
    /// 只替换 `sender.track` 不够——如果这个 sender 所在的 transceiver
    /// 方向已经被 answer 定成 recvonly，换轨也不会让它开始发送。
    /// removeTrack + addTrack 会把这个 transceiver 的方向重新谈成 sendrecv。
    func forceReattachAudio(_ track: RTCAudioTrack) {
        guard !isClosed else { return }
        localAudio = track

        if let sender = audioSender ?? peerConnection.senders.first(where: { $0.track?.kind == "audio" }) {
            peerConnection.removeTrack(sender)
        }
        audioSender = nil
        audioTrackId = nil
        if let sender = peerConnection.add(track, streamIds: ["tq-\(peerID)"]) {
            audioSender = sender
            audioTrackId = track.trackId
        }
        negotiate()
    }

    // MARK: - 屏幕共享（m-line 预建，只开关轨）

    /// 开始/续接共享：打开共享轨。
    ///
    /// 共享 m-line 在入会首轮协商里就建好了（见 `ensureScreenSender`），
    /// 这里**正常情况下不需要任何协商**：sender 上一直挂着同一条轨，
    /// 打开 `isEnabled`、编码器收到帧就会发包，浏览器那条 receiver 也从头到尾
    /// 没变过，`ontrack` 早在入会时就到过了。
    ///
    /// 只有一种例外会走到 `negotiate()`：sender 真的不在（老会话、
    /// 或这条轨是后来新建的）。此时补挂一次并协商，仅此一次。
    func attachScreenTrack(_ track: RTCVideoTrack) {
        guard !isClosed else { return }

        /* 同 ensureScreenSender：不看 `sender.track`，那个属性读回 nil 时
           会把"已经挂好"判成"没挂"，于是每开一次共享就补一次协商。 */
        let alreadyAttached = screenSender != nil && screenTrackId == track.trackId
        /* 本地 sender 挂上 ≠ 这条 m-line 进了 SDP。
           对方先发 offer 时，answer 不能新增 m-line：sender 建好了、
           轨也开了，但它没有 mid，帧永远到不了编码器。这里以本地 SDP 为准，
           没进就补一次 offer（只补一次，重发由 scheduleOfferRetry 负责）。 */
        let inSDP = Self.screenMLineAcceptsSend(peerConnection.localDescription?.sdp)
            && !(screenTransceiver?.mid ?? "").isEmpty
        localScreen = track
        ensureScreenSender(track)
        track.isEnabled = true

        /* 再核一次 sender 上到底连着哪条轨。
           `RTCRtpSender.track` 每次读都会包一个新的 ObjC 对象，所以只能用
           trackId 比，不能用 `===`。id 不一致说明 sender 还连着上一轮/重建前
           的那条轨——帧推到新轨上没人消费，编码器就是 0x0 零帧。
           属性 setter 在 M140 里直通原生 SetTrack（等价 replaceTrack），
           换轨不产生协商。 */
        if let sender = screenSender, sender.track?.trackId != track.trackId {
            sender.track = track
            screenTrackId = track.trackId
            ScreenShareRuntime.note("共享 sender 已重新绑定到当前轨")
        }

        if !alreadyAttached || !inSDP {
            negotiate()
        }
    }

    /// 只换 sender 上的轨，不协商、不动 m-line。
    ///
    /// 用在"回环接收器明明有帧、编码器却 0 帧"的自愈里：这条 m-line 是好的，
    /// 坏的只是 sender 指向了另一条轨对象。
    func rebindScreenTrack(_ track: RTCVideoTrack) {
        guard !isClosed, let sender = screenSender else { return }
        sender.track = track
        screenTrackId = track.trackId
        localScreen = track
        track.isEnabled = true
    }

    /// 停止共享：只关轨，**不拆 m-line**。
    ///
    /// 拆掉 m-line 的代价是远端 receiver 变 ended、下一轮必须重新协商，
    /// 而重新协商正是之前所有"0 包 0 帧"故障的入口。留着一条 sendonly
    /// 的空 m-line 不占带宽（没有帧就没有 RTP），HTTP 时代之后这点 SDP
    /// 体积可以忽略。
    func detachScreenTrack(renotify: Bool = true) {
        localScreen?.isEnabled = false
        screenSender?.track?.isEnabled = false
    }

    /// 共享链路的一句话现场，进诊断面板。
    ///
    /// 把"看起来都对但就是 0 包"拆成三项可判定的证据：共享 m-line 有几条、
    /// 远端到底收不收、ICE 通不通。缺了这三项，前几轮只能靠猜。
    /// 本地 SDP 里 H.264 的 level，形如 `L4.0`。诊断回传用它判断
    /// "编码器是不是被 SDP 限在 3.1 而编不出整屏"。
    var screenH264Level: String {
        SDPCodecFilter.h264Level(in: peerConnection.localDescription?.sdp)
    }

    /* 这里曾经有一个 seedBandwidthEstimate，用 IMP 调
       `setBweMinBitrateBps:currentBitrateBps:maxBitrateBps:` 把带宽估计器的
       起点抬到目标的 90%。

       **它必须被删掉，因为它是 1.8.3"浏览器彻底没画面"的直接原因。**
       这个选择器进的不是"这条轨"的配置，而是
       `PeerConnectionInterface::SetBitrate(BitrateSettings)`——
       `RtpBitrateConfigurator` **每条连接只有一份**。传进去的
       `max_bitrate_bps = nil` 被包装层当成 0 落到底层，于是整条连接的
       可用带宽上限变成 0：pacer 不给配额 → 编码器目标码率归零 →
       libwebrtc 的帧丢弃器（FrameDropper）把每一帧都丢掉。

       现场数据完全对上：
         · 共享出帧 216、编码 0 帧、发送 0 包
         · **摄像头同样 0 字节**（摄像头是被连累的，这最能说明是 Call 级配置）
         · `可用上行 3.6Mbps` = 我们塞进去的 0.9×4Mbps，一分不差，
           说明估计器被钉在了种子值上，而配额是 0
         · 受限 带宽不足（不是 cpu，也不是 none）

       LiveKit 从来不用这个接口，它只往 SDP 写 `x-google-start-bitrate`。
       现在我们也只用那一条路：见 SDPCodecFilter.injectStartBitrate
       与 applyLocalDescriptionAndSignal 里的兜底码率。 */

    /// 共享那条 track 的目标码率（bps）。没协商出 encodings 时返回 0。
    var screenTargetBps: Int {
        (screenSender?.parameters.encodings ?? [])
            .compactMap { $0.maxBitrateBps?.intValue }
            .reduce(0, +)
    }

    /// 首轮协商时用来算 `x-google-start-bitrate` 的兜底码率。
    /// 取当前共享画质档位的目标码率——与真正的 encodings 上限同源，
    /// 不会出现"起始码率比单轨上限还高"的组合。
    private static var fallbackVideoBitrateBps: Int {
        RealRTCClient.screenEncodingProfile.bitrate
    }

    var screenLinkDebug: String {
        let localSDP = peerConnection.localDescription?.sdp
        let videoMLines = Self.videoMLineCount(localSDP)
        /* 除了"msid 在 SDP 里"，还必须真有 mid。
           msid 只是本端写给 SDP 的字符串；mid 才是这条 m-line 被协商、
           被分配传输通道的证据。mid 为空时 SDP 里照样能看到 msid
           （本地描述里 transceiver 一旦创建就会带上），但 WebRTC 不会为它
           建 VideoSendStream——这正是"已进SDP + 0 帧"的假象来源。 */
        let midValue = screenTransceiver?.mid ?? ""
        let screenInSDP = Self.screenMLineAcceptsSend(localSDP)
            && !midValue.isEmpty
        let remote = Self.videoDirectionAllowsReceive(peerConnection.remoteDescription?.sdp) ? "可收" : "不可收 ⚠️"
        let ice: String
        switch peerConnection.iceConnectionState {
        case .connected: ice = "connected"
        case .completed: ice = "completed"
        case .checking: ice = "checking"
        case .disconnected: ice = "disconnected ⚠️"
        case .failed: ice = "failed ⚠️"
        case .closed: ice = "closed"
        case .new: ice = "new"
        default: ice = "unknown"
        }
        /* 信令状态是"offer 到底有没有被应答"的唯一证据。
           停在 haveLocalOffer 就是浏览器没收/没回，重挂 sender 毫无意义。 */
        let signaling: String
        switch peerConnection.signalingState {
        case .stable: signaling = "stable"
        case .haveLocalOffer: signaling = "等answer ⚠️"
        case .haveRemoteOffer: signaling = "待应答"
        case .closed: signaling = "closed"
        default: signaling = "其他"
        }
        let screenSenderText = screenSender == nil ? "未建 ⚠️" : "已建"
        let screenSDPText = screenInSDP ? "已进SDP" : "未进SDP ⚠️"
        /* 编码器事实（1.7.4）：
           `mid` 为空 = 这条 m-line 没被协商；
           `enc` 为 0 = sender 没有 encoding 槽位，WebRTC 不会为它建
           VideoSendStream，帧推进去也一个包都发不出来；
           `ssrc` 为空 = 协商没分配同步源，同样编不出包。
           这三项是"挂轨/轨开/SDP 允许但 0 包"唯一能落地的判据。 */
        let midText = screenTransceiver?.mid ?? ""
        let mid = midText.isEmpty ? "-" : midText
        let encodings = screenSender?.parameters.encodings ?? []
        let ssrc = encodings.first?.ssrc?.stringValue ?? "-"
        /* 协商出来的编码 + 写进去的码率上限。
           VP8 = iOS 上只能软编，880×1920 必然既糊又卡，看到它就该改 SDP；
           `上限` 是真正落到 encoder 的数字，它要是 300k 那种默认值，
           说明 setVideoEncoding 根本没写进去（encodings 为空时会被跳过）。 */
        let codec = SDPCodecFilter.videoCodecName(in: localSDP)
        /* level 是"编码器肯不肯干活"的开关。
           `L3.1`（Chrome 默认的 42001f）帧尺寸上限 3600 宏块 = 1280×720，
           整屏 880×1920 是 6600 宏块，VideoToolbox 每帧都编不出来，
           表现是出帧 321、编码 32、浏览器冻住。看到 L3.1 就等于看到故障。 */
        let level = SDPCodecFilter.h264Level(in: localSDP)
        let capBps = encodings.first?.maxBitrateBps?.intValue ?? 0
        let capText = capBps > 0 ? String(format: "%.1fM", Double(capBps) / 1_000_000) : "未设"
        /* sender 上连的到底是不是当前这条共享轨。
           "shared m-line 在、ssrc 在、编码器在"都能成立而帧进不去，
           剩下的唯一解释就是 sender 连着另一条轨。 */
        let bound = screenSender != nil && screenTrackId == (localScreen?.trackId ?? "")
        return "SDP video \(videoMLines) · 共享\(screenSDPText) · sender \(screenSenderText)"
            + " · mid=\(mid)/enc=\(encodings.count)/ssrc=\(ssrc)"
            + " · \(codec)/\(level)/上限\(capText)"
            + " · 远端\(remote) · 信令 \(signaling) · ICE \(ice)"
            + " · 挂轨\(bound ? "一致" : "不一致 ⚠️")"
            + " · \(negotiationTrace)"
    }

    /// 本地 SDP 里有没有共享那条 m-line。
    /// 认 `a=msid:screen-...`：这是本端给共享轨指定的 stream id，
    /// 只有它真的被协商进 SDP 时才会出现。比数 m-line 条数可靠——
    /// 摄像头没建起来时也会只有一条 video，但那条不是共享。
    private static func containsScreenMSID(_ sdp: String?) -> Bool {
        sdp?.contains("a=msid:screen-") ?? false
    }

    /// 本地 SDP 里有几条 video m-line。
    /// 摄像头一条、共享一条；只有 1 条就说明共享那条根本没谈进去。
    private static func videoMLineCount(_ sdp: String?) -> Int {
        guard let sdp, !sdp.isEmpty else { return 0 }
        return sdp.split(whereSeparator: { $0.isNewline })
            .filter { $0.hasPrefix("m=video") }
            .count
    }

    /// 本地 SDP 里**带共享 msid 的那条** video m-line 是否允许本端发送。
    ///
    /// 1.7.6 及以前判的是"最后一条 video 是否 sendonly"。这个前提只在
    /// m-line 顺序固定（audio → camera → screen）时成立。真机上一次
    /// `SDP video 3` 就把判断带偏：后补的摄像头流排在共享后面、方向 sendrecv，
    /// 于是共享被误判成"未进SDP"，每开一次共享就补一次协商，m-line 越补越多。
    /// 现在按 msid 定位到共享那一段再判方向，与顺序无关。
    private static func screenMLineAcceptsSend(_ sdp: String?) -> Bool {
        guard let sdp, !sdp.isEmpty else { return false }
        var inVideo = false
        var hasScreenMSID = false
        var allows = false
        for raw in sdp.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            if line.hasPrefix("m=") {
                if inVideo, hasScreenMSID, allows { return true }
                inVideo = line.hasPrefix("m=video")
                hasScreenMSID = false
                allows = false
                continue
            }
            guard inVideo else { continue }
            if line.hasPrefix("a=msid:screen-") {
                hasScreenMSID = true
            } else if line.hasPrefix("a=sendonly") || line.hasPrefix("a=sendrecv") {
                allows = true
            } else if line.hasPrefix("a=recvonly") || line.hasPrefix("a=inactive") {
                allows = false
            }
        }
        return inVideo && hasScreenMSID && allows
    }

    /// 远端 SDP 里**共享那条** video m-line 是否允许本端发送。
    /// 远端写 recvonly / sendrecv = 它能收；inactive / sendonly = 它不收。
    ///
    /// 1.8.3 及以前取的是"最后一条 video m-line"。我们本地有 3 条 video
    /// （摄像头 / 共享 / 收对方画面），远端 answer 里排在最后的往往正是
    /// "对方发给我"的那条，它的方向天生不是 recvonly——于是这个判断
    /// **永远显示"远端可收"**，哪怕共享那条被答成 inactive。
    /// 1.8.3 现场就是"远端可收 + 0 包 0 帧"这种自相矛盾的组合。
    /// 现在按 msid 定位共享那一段再判方向；找不到 msid 时才退回旧逻辑。
    private static func videoDirectionAllowsReceive(_ sdp: String?) -> Bool {
        guard let sdp, !sdp.isEmpty else { return false }
        var inVideo = false
        var hasScreenMSID = false
        var allows = false
        var foundScreen = false
        for raw in sdp.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            if line.hasPrefix("m=") {
                if inVideo, hasScreenMSID {
                    foundScreen = true
                    if allows { return true }
                }
                inVideo = line.hasPrefix("m=video")
                hasScreenMSID = false
                allows = false
                continue
            }
            guard inVideo else { continue }
            if line.hasPrefix("a=msid:screen-") {
                hasScreenMSID = true
            } else if line.hasPrefix("a=recvonly") || line.hasPrefix("a=sendrecv") {
                allows = true
            } else if line.hasPrefix("a=inactive") || line.hasPrefix("a=sendonly") {
                allows = false
            }
        }
        if inVideo, hasScreenMSID {
            foundScreen = true
            if allows { return true }
        }
        /* 找到了共享那条且它不收 —— 结论就是"不收"，不要拿别的 m-line 洗白。 */
        if foundScreen { return false }

        /* 远端没回 msid（个别网关会剥掉）：退回"最后一条 video"的老判定。 */
        var result = false
        var scanning = false
        for raw in sdp.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            if line.hasPrefix("m=video") { scanning = true; continue }
            if line.hasPrefix("m=") { scanning = false; continue }
            guard scanning else { continue }
            if line.hasPrefix("a=recvonly") || line.hasPrefix("a=sendrecv") {
                result = true
            } else if line.hasPrefix("a=inactive") || line.hasPrefix("a=sendonly") {
                result = false
            }
        }
        return result
    }

    /// 视频上行的完整现场，供共享看门狗与诊断面板使用。
    ///
    /// 只回答"sender 上是不是这条轨"还不够，它答不了"这条轨是开的吗"
    /// "SDP 允许发吗"。少了后两项，诊断会出现"共享轨已挂 + 编码 0 帧"这种
    /// 自相矛盾的结论。
    struct VideoUplinkSummary {
        var trackExists = false
        var trackEnabled = false
        /// sender.track 就是本端要发的那条轨。
        var attached = false
        /// 本地 SDP 的视频 m-line 方向允许发送。
        var sendsUpstream = true
        /// 共享 m-line 是否真的进了本地 SDP。false = 这条轨没有 mid，
        /// 帧推进去也永远到不了编码器。
        var screenInSDP = false
        /// sender 的数量（>1 通常意味着多了一条历史 m-line）。
        var senderCount = 0
    }

    var videoUplinkSummary: VideoUplinkSummary {
        var summary = VideoUplinkSummary()
        /* 只看共享 sender。`localVideo` 现在是"摄像头那条"，拿它来判断
           共享通道会把摄像头 m-line 的绿状态当成共享发得出去。 */
        guard let track = localScreen else { return summary }
        summary.trackExists = true
        summary.trackEnabled = track.isEnabled
        summary.attached = screenSender != nil && screenTrackId == track.trackId
        // 最后一条 video m-line 就是共享那条（摄像头先建，共享后建）。
        let localSDP = peerConnection.localDescription?.sdp
        summary.screenInSDP = Self.screenMLineAcceptsSend(localSDP)
            && !(screenTransceiver?.mid ?? "").isEmpty
        summary.sendsUpstream = summary.screenInSDP
        summary.senderCount = peerConnection.senders.filter { $0.track?.kind == "video" }.count
        return summary
    }

    /// 共享 sender 的编码器事实，供 RealRTCClient 写进自愈流水。
    var screenSenderFacts: String {
        let midText = screenTransceiver?.mid ?? ""
        let mid = midText.isEmpty ? "-" : midText
        let encodings = screenSender?.parameters.encodings ?? []
        let ssrc = encodings.first?.ssrc == nil ? "无" : "有"
        return "mid=\(mid) enc=\(encodings.count) ssrc=\(ssrc)"
    }

    /// 共享 m-line 是否真的可以编码：既有 mid，又有 encoding 槽位。
    /// 两者缺一，帧推进去也不会产生任何 RTP 包。
    var screenSenderReady: Bool {
        !(screenTransceiver?.mid ?? "").isEmpty
            && ((screenSender?.parameters.encodings.count ?? 0) > 0)
    }

    /// m-line 看似在 SDP 里、实际没有传输通道时，补一次 offer。
    ///
    /// 只在自愈里调用，且由调用方保证一轮只调一次：协商本身有代价，
    /// 反复补会把连接拖进 glare。
    func renegotiateForScreen() {
        guard !isClosed else { return }
        negotiate()
    }

    /// 摄像头 / 麦克风轨的 trackId，用途同 `screenTrackId`：
    /// 幂等判断只认自己记的字符串，不依赖 `sender.track`。
    private var videoTrackId: String?
    private var audioTrackId: String?

    /// 共享轨的 trackId。看门狗用它把 `outbound-rtp` 统计里属于共享的那条
    /// 挑出来——摄像头和共享是两条独立的 send stream，合计会把"共享没发"
    /// 掩盖成"有包在发"。
    var screenTrackIdentifier: String? { screenTrackId }

    /// 本地 SDP 的 m-line 清单，形如
    /// `0=audio/sendrecv/- · 1=video/sendrecv/tq-xxx · 2=video/sendonly/screen-xxx`。
    ///
    /// 这份清单回答的是「到底有几条视频 m-line、每条是什么方向、挂的哪个流」。
    /// 真机上出现过 `SDP video 3`：多出来的那条既可能是浏览器的 recvonly 轨，
    /// 也可能是本端重复 add 出来的僵尸通道。只有把 mid / 方向 / msid 摆在一起，
    /// 才能分清它是"无害的备用 m-line"还是"正在白吃带宽的第二路共享"。
    var mLineOverview: String {
        guard let sdp = peerConnection.localDescription?.sdp, !sdp.isEmpty else { return "-" }
        var items: [String] = []
        var kind = ""
        var mid = "-"
        var direction = ""
        var msid = "-"
        func flush() {
            guard !kind.isEmpty else { return }
            items.append("\(mid)=\(kind)/\(direction.isEmpty ? "?" : direction)/\(msid)")
            kind = ""
            mid = "-"
            direction = ""
            msid = "-"
        }
        for raw in sdp.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            if line.hasPrefix("m=") {
                flush()
                kind = line.dropFirst(2).split(separator: " ").first.map(String.init) ?? ""
                continue
            }
            guard !kind.isEmpty else { continue }
            if line.hasPrefix("a=mid:") {
                mid = String(line.dropFirst(6))
            } else if line.hasPrefix("a=sendrecv") {
                direction = "sendrecv"
            } else if line.hasPrefix("a=sendonly") {
                direction = "sendonly"
            } else if line.hasPrefix("a=recvonly") {
                direction = "recvonly"
            } else if line.hasPrefix("a=inactive") {
                direction = "inactive"
            } else if line.hasPrefix("a=msid:") {
                /* `a=msid:<stream> <track>`：只留流名，track 名太长且没信息量。 */
                msid = line.dropFirst(7).split(separator: " ").first.map(String.init) ?? "-"
            }
        }
        flush()
        return items.isEmpty ? "-" : items.joined(separator: " · ")
    }

    /// 共享那条 m-line 的 mid。统计里用它把 `outbound-rtp` 分成两路：
    /// `trackIdentifier` 在包装层偶尔读回空，mid 是协商写入的，更稳。
    var screenMid: String {
        let value = screenTransceiver?.mid ?? ""
        return value
    }

    /// 记录并返回当前 video sender。sender.track 可能为 nil（关闭视频时），
    /// 所以不能只靠 `track?.kind` 反查，必须缓存引用。
    private func senderForVideoTrack() -> RTCRtpSender? {
        peerConnection.senders.first(where: { $0.track?.kind == "video" })
    }

    private func transceiverForVideoSender() -> RTCRtpTransceiver? {
        if let sender = videoSender {
            return peerConnection.transceivers.first { $0.sender.senderId == sender.senderId }
        }
        return peerConnection.transceivers.first { $0.mediaType == .video }
    }

    /// 调整上行视频编码参数。屏幕共享是"文字优先"，需要比摄像头更高的码率上限，
    /// 否则 1080p 画面会被 WebRTC 按摄像头模型压到 1~2Mbps，文字边缘发糊。
    ///
    /// `minBitrateBps` 目前**没有调用方**。1.8.3 拿它当"启动助推"，
    /// 但真正起作用的是 SDP 里的 `x-google-start-bitrate`（LiveKit 的做法），
    /// 参数留着只为接口完整，不要靠它兜底。
    ///
    /// `forScreen` 必须显式指定：摄像头和共享是两条独立的 send stream，
    /// 共用一条 sender 引用会让"停止共享后把 8Mbps 配到摄像头"或反过来。
    func setVideoEncoding(
        maxBitrateBps: Int?,
        maxFramerate: Int?,
        minBitrateBps: Int? = nil,
        keepResolution: Bool = false,
        forScreen: Bool = false
    ) {
        let target: RTCRtpSender?
        if forScreen {
            target = screenSender
        } else {
            target = videoSender ?? senderForVideoTrack()
        }
        guard let sender = target else { return }
        // RTCRtpSender.parameters 是非可选属性（M140 起），不能做可选绑定。
        let params = sender.parameters
        /* 没有 encoding 槽位时**绝不能**把参数写回去。
           协商尚未完成时 `parameters.encodings` 可能是空数组，此时
           `sender.parameters = params` 会把"空 encoding"落到底层，
           这条 sender 就再也不会有 VideoSendStream——画面上就是
           "轨开着、帧在出、编码 0 帧、发送 0 包"，而且再也不会恢复。
           宁可不设码率，也不能把通道写死。 */
        guard !params.encodings.isEmpty else { return }
        for encoding in params.encodings {
            if let bps = maxBitrateBps {
                encoding.maxBitrateBps = NSNumber(value: bps)
            }
            if let fps = maxFramerate {
                encoding.maxFramerate = NSNumber(value: fps)
            }
            if let minBps = minBitrateBps {
                encoding.minBitrateBps = NSNumber(value: minBps)
            }
        }
        /* 降级偏好按「轨道来源」定，不是按阶段定。
           LiveKit 的 `DegradationPreference.resolve(for:)` 就是这么分的：
             · 屏幕共享 → maintainResolution：字要看得清，掉帧可以接受
             · 摄像头   → maintainFramerate ：动作要连贯，掉分辨率可以接受
           之前摄像头沿用 balanced，弱网时会掉分辨率去保帧率，
           但 balanced 的取舍不确定，实测更像"两样都掉一点"。 */
        let preference: RTCDegradationPreference
        if forScreen {
            preference = keepResolution ? .maintainResolution : .balanced
        } else {
            preference = .maintainFramerate
        }
        params.degradationPreference = NSNumber(value: preference.rawValue)
        sender.parameters = params
    }

    private func ensureSender(for track: RTCMediaStreamTrack, streamID: String) {
        let isVideo = track.kind == "video"
        let knownID = isVideo ? videoTrackId : audioTrackId
        let hasSender = isVideo ? (videoSender != nil) : (audioSender != nil)

        if hasSender, knownID == track.trackId {
            if isVideo, videoTransceiver == nil { videoTransceiver = transceiverForVideoSender() }
            return
        }
        /* 同 kind 已有 sender、trackId 却变了（`setupLocalMedia` 重跑会重建轨）：
           M140 没有 replaceTrack，这里也**不 add**。理由同 ensureScreenSender。 */
        if hasSender, knownID != nil {
            return
        }
        /* 用 `add` 的返回值，不回头按 trackId 反查：
           反查依赖 `sender.track`，而这个属性在包装层里会读回 nil，
           一旦反查失败，下一次 attach 就会再 add 一条 m-line。 */
        guard let sender = peerConnection.add(track, streamIds: [streamID]) else { return }
        if isVideo {
            videoSender = sender
            videoTransceiver = transceiverForVideoSender()
            videoTrackId = track.trackId
        } else {
            audioSender = sender
            audioTrackId = track.trackId
        }
    }

    /// 用新麦克风轨替换当前上行音频（不重建 PeerConnection、不重新协商）。
    /// 这是 Jitsi `replaceTrack` 在音频侧的对应实现：设备切换、权限刚放开、
    /// 音频会话重建导致旧轨失效时，调用方 rebuild 后从这里把声音接回去。
    func replaceAudioTrack(with track: RTCAudioTrack?) {
        guard let track = track else { return }
        if let sender = audioSender ?? peerConnection.senders.first(where: { $0.track?.kind == "audio" }) {
            audioSender = sender
            sender.track = track
            return
        }
        /* 一个 audio sender 都没有：对端接入时本端还没建过音频 sender
           （极少见，例如入会时完全无麦克风权限）。补一条，走一次重新协商。 */
        peerConnection.add(track, streamIds: ["tq-\(peerID)"])
        audioSender = peerConnection.senders.first(where: { $0.track?.trackId == track.trackId })
    }

    // MARK: - 远端信号

    func handleRemoteSDP(_ raw: [String: Any]) {
        guard
            let type = raw["type"] as? String,
            let sdpString = raw["sdp"] as? String
        else { return }

        let description = RTCSessionDescription(type: Self.sdpType(from: type), sdp: sdpString)
        let round = raw["rid"] as? String

        switch description.type {
        case .offer:
            // 记下这轮的号，本端生成的 answer 要原样回带（对端靠它配对）。
            remoteOfferRound = round
            handleRemoteOffer(description)
        case .answer:
            handleRemoteAnswer(description, round: round)
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
        offerSentAt = nil
        offerRetryTask?.cancel()
        offerRetryTask = nil
        offerRetryCount = 0
        pendingOfferRound = nil
        remoteOfferRound = nil
        ignoreOffer = false
        isNegotiating = false
        isRestartingIce = false
        needsRestartAfterStable = false
        needsNegotiateAfterStable = false
        isAcceptingRemoteOffer = false
        pendingRemoteCandidates.removeAll()
        // 只放引用，不 stop 轨道：同一条麦克风轨还要给别的 peer 用。
        localAudio = nil
        localVideo = nil
        localScreen = nil

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
            /* 我们自己的 offer 还在等 answer，这条远端 offer 不要。
               轨道仍然要挂上——它们会进我们那一轮 offer 的 SDP，
               白等一轮只会让共享晚几秒可用。 */
            ensureLocalSenders()
            return
        }

        /* 先占住"正在应答"，再挂本地轨。
           `addTrack` 会异步触发 negotiationneeded；如果此刻没占位，
           它会立刻发一个 offer，把马上要落地的远端 offer 顶成 wrong-state。
           占位后这次变化会被 `needsNegotiateAfterStable` 接住，
           等 answer 落地再补——answer 本身**不能新增 m-line**。 */
        isAcceptingRemoteOffer = true
        isNegotiating = true
        /* 本地轨必须在 setRemoteDescription 之前挂上：
           顺序反过来，answer 里 audio 就是 recvonly——本端从此只收不发。 */
        ensureLocalSenders()

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

    private func acceptRemoteOffer(_ description: RTCSessionDescription, narrowed: Bool = true) {
        /* 把对端 offer 的视频编码收窄到 H.264。
           浏览器默认把 VP8 排在最前，answer 只能按 offer 顺序选，
           协商结果就是 VP8——而 iOS 没有 VP8 硬编码器，880×1920 的屏幕内容
           软编跑不动：帧率 7fps、每帧 3KB、画面糊成块。详见 SDPCodecFilter。 */
        var target = description
        if narrowed {
            let filtered = SDPCodecFilter.preferH264Only(description.sdp)
            if filtered != description.sdp {
                target = RTCSessionDescription(type: .offer, sdp: filtered)
            }
        }
        peerConnection.setRemoteDescription(target) { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                if error != nil {
                    /* 收窄后的 SDP 被拒（对端结构特殊）：用原始描述再试一次。
                       宁可回到 VP8，也不能因为一次 munging 把整条连接判死。 */
                    if target.sdp != description.sdp {
                        self.acceptRemoteOffer(description, narrowed: false)
                        return
                    }
                    self.isNegotiating = false
                    self.isAcceptingRemoteOffer = false
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
                            self.isAcceptingRemoteOffer = false
                            self.delegate?.peerSessionNeedsRebuild(self)
                            return
                        }
                        self.applyLocalDescriptionAndSignal(answer, restart: false) { [weak self] in
                            Task { @MainActor in
                                guard let self = self else { return }
                                /* answer 真正落地之后才解除占位。
                                   提前解除的话，这段时间里排队的 negotiate()
                                   会插进来发 offer，把会话顶成 haveLocalOffer。 */
                                self.isAcceptingRemoteOffer = false
                                // answer 期间又挂上了新轨（answer 不能新增 m-line）：
                                // 补一轮 offer，否则那条轨永远没有 mid。
                                if self.needsNegotiateAfterStable {
                                    self.needsNegotiateAfterStable = false
                                    self.negotiate()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleRemoteAnswer(_ description: RTCSessionDescription, round: String?) {
        lastAnswerRound = round

        guard peerConnection.signalingState == .haveLocalOffer else {
            // 过期 answer（对方在 glare 中让路的残留），直接丢弃。
            return
        }

        /* 轮次校验：这是止住「240ms 重建死循环」的那道闸。
           号对不上＝这条 answer 属于上一轮已经作废的 offer，
           拿它去配当前 offer 只会失败，而失败又会触发重建。
           直接丢掉，等当前这轮的 answer 到。 */
        if let round = round {
            /* 带号就必须等于当前这一轮。pendingOfferRound 为 nil 时同样拒绝：
               那表示本端此刻并没有待应答的 offer（刚重建、offer 还没发出去），
               这条 answer 无论属于谁都是错配。 */
            guard round == pendingOfferRound else {
                droppedAnswerCount += 1
                return
            }
        }

        peerConnection.setRemoteDescription(description) { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                if let error = error {
                    /* 把原文留下来。以前这里只判 nil 就重建，等于把唯一的
                       现场证据扔了；诊断里只能看到"等answer"，看不出为什么。 */
                    self.lastRemoteSetError = error.localizedDescription
                    self.answerSetFailureCount += 1

                    /* 不要立刻重建。
                       旧逻辑失败即 rebuild，而 rebuild 是同步的：close → 新建
                       → 立刻再发 offer，200~300ms 就转一圈。对端刚生成的
                       answer 又是一条"配不上"的，于是无限循环，编码器一次
                       都没机会启动。
                       先原样重投当前 offer（同一轮次号），让对端重答一次；
                       只有连续两次都失败，才认定这条连接真的不可救。 */
                    if self.answerSetFailureCount < 2, let local = self.peerConnection.localDescription {
                        self.delegate?.peerSession(
                            self, needsSignalSDP: local, restart: false,
                            round: self.pendingOfferRound
                        )
                        return
                    }
                    self.answerSetFailureCount = 0
                    self.delegate?.peerSessionNeedsRebuild(self)
                    return
                }
                self.lastRemoteSetError = nil
                self.answerSetFailureCount = 0
                self.pendingOfferRound = nil
                self.offerSentAt = nil
                self.offerRetryTask?.cancel()
                self.offerRetryTask = nil
                self.offerRetryCount = 0
                self.flushPendingRemoteCandidates()
            }
        }
    }

    /// setLocalDescription 完成后读取 pc.localDescription 发送（Web 端同款：
    /// setLocalDescription 可能对 SDP 做补全/改写）。
    private func applyLocalDescriptionAndSignal(
        _ description: RTCSessionDescription,
        restart: Bool,
        onDone: (() -> Void)? = nil,
        narrowed: Bool = true
    ) {
        var target = description
        /* offer 和 answer 都要过一遍。
           answer 的 fmtp 是 libwebrtc 按收到的 offer 生成的：只要 offer 的 level
           已经抬到 4.0，answer 也会是 4.0。但 iOS 自己发 offer 时 answer 由浏览器给，
           那边还是 `42001f`，回程同样要抬——否则屏幕上看到的是"共享那条是 3.1"，
           编码器照样丢帧。`preferH264Only` 幂等，跑两遍不会改坏。 */
        if narrowed, description.type == .offer || description.type == .answer {
            var filtered = SDPCodecFilter.preferH264Only(description.sdp)
            /* 再给这份本地描述写起始码率。
               libwebrtc 对每条新的视频 send stream 固定从 300kbps 起步，
               跟 encodings 的 maxBitrate 无关；共享这种整屏内容在 300k 下
               不是"糊"而是编码器直接丢帧，浏览器看到的就是冻住。
               LiveKit 四端（swift / js / rust / android）都用这一招：
               取目标码率的 90% 写进 `x-google-start-bitrate`。

               **兜底值是关键。** 我们的共享 m-line 是入会首轮就预建的，
               那时 `applyScreenEncodingBudget` 还没跑，sender 上没有
               maxBitrateBps（读回 0）。如果只在"有上限"时才写，
               入会那次协商就永远拿不到起始码率——而这正是唯一一次
               会被 libwebrtc 读走的协商（共享开始时 m-line 已经在了，
               不会重新协商）。所以这里退回配置档位的码率。 */
            let targetBps = max(screenTargetBps, Self.fallbackVideoBitrateBps)
            if targetBps > 0 {
                let kbps = Int((Double(targetBps) / 1000.0 * 0.9).rounded())
                filtered = SDPCodecFilter.injectStartBitrate(filtered, kbps: kbps)
            }
            if filtered != description.sdp {
                target = RTCSessionDescription(type: description.type, sdp: filtered)
            }
        }
        peerConnection.setLocalDescription(target) { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                defer { onDone?() }
                if error == nil {
                    let toSend = self.peerConnection.localDescription ?? target
                    /* 轮次号在这里生成：
                       · offer：进程内自增，跨 session 也不重复（重建后从 1 开始
                         会与旧 session 的 1 撞号，旧 answer 就会被误收）；
                       · answer：原样回带远端 offer 的号，对端据此配对。 */
                    let round: String?
                    if description.type == .offer {
                        Self.roundSeq += 1
                        round = "\(self.peerID)-\(Self.roundSeq)"
                        self.pendingOfferRound = round
                        self.offerSentAt = Date()
                    } else {
                        round = self.remoteOfferRound
                        self.offerSentAt = nil
                    }
                    self.delegate?.peerSession(
                        self, needsSignalSDP: toSend, restart: restart, round: round
                    )
                    if description.type == .offer {
                        self.offerRetryCount = 0
                        self.scheduleOfferRetry()
                    } else {
                        self.offerRetryTask?.cancel()
                        self.offerRetryTask = nil
                    }
                } else {
                    /* 收窄编码导致 setLocalDescription 被拒：退回原始 offer 重来。
                       这一步只发生一次，不会递归。 */
                    if target.sdp != description.sdp {
                        self.applyLocalDescriptionAndSignal(
                            description, restart: restart, onDone: onDone, narrowed: false
                        )
                        return
                    }
                    self.offerSentAt = nil
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

    /// 触发协商：由 `peerConnectionShouldNegotiate` 调用。
    /// 双方都可能发 offer，glare 由 polite 方回滚（见 handleRemoteOffer）。
    private func negotiate() {
        guard !isClosed else { return }
        guard !isAcceptingRemoteOffer else {
            /* 正在应答对端的 offer。这一轮的 m-line 由 answer 承载，
               但 answer **不能新增 m-line**：共享轨如果是在这段时间
               addTrack 进来的，它没有 mid，也永远不会进 SDP。
               必须记下来，等 answer 落地回到 stable 再补一次 offer——
               1.7.0~1.7.2 的"共享轨挂了、编码 0 帧"有一半就死在这里：
               addTrack 的 negotiationneeded 正好落进这个窗口，被静默吞掉。 */
            needsNegotiateAfterStable = true
            return
        }
        guard !makingOffer, !isNegotiating else {
            // 协商正在进行。直接 return 会让这次 addTrack 永远没有对应的 offer，
            // 记下来，等回到 stable 再补——这是"本地轨挂上了却一个包都不发"的根因之一。
            needsNegotiateAfterStable = true
            return
        }
        guard peerConnection.signalingState == .stable else {
            needsNegotiateAfterStable = true
            return
        }

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

    /// offer 发出去 4 秒还没回到 stable，就原样再发一次（最多 3 次）。
    ///
    /// **不重建连接、不重新 createOffer**：同一份 SDP 重复投递是幂等的，
    /// 浏览器只是把它当成一次迟到的 setRemoteDescription。之前遇到丢 offer
    /// 只能等看门狗拆连接，结果把"重发一次就能好"的问题变成了"整场会话没了"。
    private func scheduleOfferRetry() {
        offerRetryTask?.cancel()
        guard offerRetryCount < 3 else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                guard self.peerConnection.signalingState == .haveLocalOffer,
                      let description = self.peerConnection.localDescription else { return }
                self.offerRetryCount += 1
                self.offerSentAt = Date()
                /* 重发必须带**同一份**轮次号：它就是同一轮 offer 的重投，
                   换号等于告诉对端"这是新的一轮"，对端会把刚生成的 answer
                   作废。 */
                self.delegate?.peerSession(
                    self, needsSignalSDP: description, restart: false,
                    round: self.pendingOfferRound
                )
                self.scheduleOfferRetry()
            }
        }
        offerRetryTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension PeerSession: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Task { @MainActor in
            guard !self.isClosed else { return }
            if stateChanged != .haveLocalOffer {
                // 已经离开"等 answer"的状态，计时作废。
                self.offerSentAt = nil
            }
            if stateChanged == .stable {
                self.flushPendingRemoteCandidates()
                if self.needsRestartAfterStable {
                    self.needsRestartAfterStable = false
                    self.performIceRestart()
                } else if self.needsNegotiateAfterStable {
                    // 协商回到稳定态：把之前被吞掉的那次轨道变更补上。
                    self.needsNegotiateAfterStable = false
                    self.negotiate()
                }
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // Unified Plan 下走 didAddReceiver 回调，这里不处理。
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    /// WebRTC 认为"需要重新协商"时（addTrack / replaceTrack / 方向变化）的回调。
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
                    self.delegate?.peerSession(self, didReceiveRemoteAudio: audio)
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
