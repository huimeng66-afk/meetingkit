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
import QuartzCore
import WebRTC

/// 远端轨的"最近一帧"时钟。
///
/// 回调来自 WebRTC 的视频线程，必须自己加锁；读侧在主线程。
/// 放在文件作用域而不是 PeerSession 内部：避免嵌套类型被主 actor 隔离，
/// 那样会无法满足 `RTCVideoRenderer` 的非隔离协议要求。
private final class RemoteFrameClock: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var last: CFTimeInterval = 0

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        lock.lock()
        last = CACurrentMediaTime()
        lock.unlock()
    }

    var lastFrameAt: CFTimeInterval {
        lock.lock(); defer { lock.unlock() }
        return last
    }

    /// 距上一帧多久；从没出过帧返回无穷大。
    var age: CFTimeInterval {
        let at = lastFrameAt
        return at <= 0 ? .greatestFiniteMagnitude : CACurrentMediaTime() - at
    }

    func reset() {
        lock.lock(); last = 0; lock.unlock()
    }
}

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
    private var remoteCameraTrack: RTCVideoTrack?
    private var remoteScreenTrack: RTCVideoTrack?
    private var remoteScreenSharing = false

    /// 最近一次真正在「出帧」的远端轨时钟。
    ///
    /// 为什么不能只信 `screen:state`：服务端共享位有 12 秒 TTL，重连、
    /// 误纠正、非共享者的 off 都会让这条信令抖一下。以前一收到 off 就把
    /// 渲染器绑回摄像头轨——摄像头是关的，画面立刻全黑，而屏幕轨其实
    /// 还在出帧。判据必须回到画面本身：谁在出帧，谁就该被显示。
    private let cameraClock = RemoteFrameClock()
    private let screenClock = RemoteFrameClock()
    private weak var clockedCameraTrack: RTCVideoTrack?
    private weak var clockedScreenTrack: RTCVideoTrack?

    /// 屏幕状态刚变成"在共享"后的保护窗口：这期间即使屏幕轨还没出帧，
    /// 也优先选它。否则摄像头还开着时会先闪一段摄像头画面。
    private var screenLatchUntil: CFTimeInterval = 0
    private var pendingScreenOffWork: DispatchWorkItem?

    /// 独立 screen m-line 与 replaceTrack 两种协议都支持；状态改变时重新绑定。
    ///
    /// off 做 4 秒防抖：TTL / 重连 / 误纠正造成的瞬时 off 不该把画面切走。
    /// 真正的停止会在 4 秒后生效；这期间屏幕轨没有新帧，切换时也不会显示旧画面。
    func setRemoteScreenSharing(_ sharing: Bool) {
        pendingScreenOffWork?.cancel()
        pendingScreenOffWork = nil
        if sharing {
            remoteScreenSharing = true
            screenLatchUntil = CACurrentMediaTime() + 8
            selectRemoteVideoTrack()
            return
        }
        guard remoteScreenSharing else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.remoteScreenSharing = false
                self.selectRemoteVideoTrack()
                /* 刚停共享的一两秒里屏幕轨可能还在吐最后几帧，上一次选轨
                   会故意留住画面。5 秒后再核一次，把它真正交还给摄像头。 */
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    Task { @MainActor in
                        guard let self, !self.remoteScreenSharing else { return }
                        self.selectRemoteVideoTrack()
                    }
                }
            }
        }
        pendingScreenOffWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// 把渲染器时钟挂到轨道上。每条轨只挂一次，换轨时从旧轨摘掉。
    private func attachFrameClock(to track: RTCVideoTrack, isScreen: Bool) {
        let clock = isScreen ? screenClock : cameraClock
        if isScreen {
            if clockedScreenTrack === track { return }
            if let old = clockedScreenTrack { old.remove(clock) }
            clockedScreenTrack = track
            screenClock.reset()
        } else {
            if clockedCameraTrack === track { return }
            if let old = clockedCameraTrack { old.remove(clock) }
            clockedCameraTrack = track
            cameraClock.reset()
        }
        track.add(clock)
    }

    private func selectRemoteVideoTrack() {
        let now = CACurrentMediaTime()
        let screen = remoteScreenTrack
        let camera = remoteCameraTrack
        let selected: RTCVideoTrack?

        if remoteScreenSharing {
            let screenFresh = screen != nil && screenClock.age < 3
            let inLatch = now < screenLatchUntil
            let cameraFresh = camera != nil && cameraClock.age < 3
            if screen != nil, screenFresh || inLatch {
                /* 正常共享：屏幕轨在出帧，或者刚开共享还在第一帧的路上。 */
                selected = screen
            } else if screen != nil, !cameraFresh {
                /* 屏幕轨暂时没帧、摄像头也没帧（大概率根本没开）：
                   宁可停在屏幕轨上等，也不要切到一条永远黑的摄像头轨。 */
                selected = screen
            } else if screen == nil {
                /* 对端走的是 replaceTrack 协议：只有一条视频轨。 */
                selected = camera
            } else {
                /* 屏幕轨确实死了、摄像头活着：显示摄像头，至少不是黑屏。 */
                selected = camera
            }
        } else {
            /* 共享结束：屏幕轨若还在出帧（对端刚发完 off、帧还在路上），
               先留住画面，等它自然停；否则回到摄像头。 */
            if let screen, screenClock.age < 1.5 {
                selected = screen
            } else if let camera {
                selected = camera
            } else {
                selected = screen
            }
        }

        if remoteVideoTrack !== selected {
            remoteVideoTrack = selected
            bindRemoteVideoRenderer()
        }
    }

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

    /* 屏幕共享：复用摄像头那条 sendrecv m-line（1.9.11）。
     *
     * 曾经的做法是给共享单开一条 sendonly m-line。它在真机上有一个死结：
     * `addTransceiver` 只能在 stable 状态新增 m-line，而新增必然触发一轮协商；
     * 这轮协商一旦被 glare、丢包或 "answer 与 offer 轮次错配" 吞掉，就会停在
     * haveLocalOffer，m-line 拿不到 encoding。此时本端所有自检都成立
     * （sender 在、轨是开的、SDP 里方向也写着 sendonly），编码器却一帧都不收
     * ——1.9.10 的现场正是「扩展出帧 172 / 已推 RTC 169 / 发送 0 包 / 编码 0 帧」。
     *
     * 复用 camera sender 的路子安卓早就跑通了（`videoSender.setTrack(screen, true)`），
     * 而且不需要任何新增 m-line：camera 那条 mid 在入会首轮就谈好，整个会话方向
     * 都是 sendrecv，replace 轨道不产生协商，编码器立刻按新轨出帧。
     *
     * 代价是共享期间远端收到的是同一条视频轨（内容从摄像头变成屏幕），
     * 由 `screen:state` 决定远端是把它放舞台还是放宫格——三端渲染层都已按这个
     * 前提写过兜底（安卓 `liveScreenTrack` 在无独立屏轨时回退 camera 轨，
     * 网页 `screenStreamFor` 在无 `screen-` 前缀时回退最后一条视频轨）。
     */
    private var screenSender: RTCRtpSender? { videoSender }
    private var screenTransceiver: RTCRtpTransceiver? { videoTransceiver }
    /// 当前是否处在"共享模式"：sender 上挂的是屏幕轨而不是摄像头轨。
    /// 所有"该不该动 sender.track"的判断都以它为准，避免共享被摄像头的
    /// 预算、重绑、重建路径覆盖掉。
    private var isSendingScreen = false
    /// 当前挂在共享通道上的轨道 id，仅用于诊断与去重。
    private var screenTrackId: String?

    /// 共享 m-line 是否已经以 `screen-` 流名真正落进过 SDP。
    ///
    /// 只有第一次共享需要新建 m-line（为了让对端收到 onAddTrack）；
    /// 之后同一条连接内的反复开关一律走 replaceTrack，避免每共享一次
    /// 就多堆一条 video m-line。PeerSession 重建时随实例归零，正是我们要的。
    private var screenSdpBound = false

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
    /// 本轮协商开始时刻。`makingOffer` 卡死时用它判超时（见 negotiate()）。
    private var negotiateStartedAt: Date?
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
    /// 全程只有一条 video m-line：`video` 是它的默认内容（摄像头），
    /// 共享开始时 `screenTrack` 会 **replace** 到同一个 sender 上，
    /// 停止时换回摄像头。不新增 m-line，也不在中途 removeTrack——
    /// 重新协商一旦被 glare 或丢包卡住，本端所有自检都会成立，
    /// 而编码器一个包都发不出去。
    /// - Parameter screenSharing: 当前是否正在共享。重建 / 新加入的连接
    ///   必须知道这件事，否则新连接上挂的是摄像头轨，而本端还在往屏幕
    ///   轨推帧——表现就是"共享中，新进来的人只看到我的脸"。
    func attachLocalTracks(
        audio: RTCAudioTrack?,
        video: RTCVideoTrack?,
        screenTrack: RTCVideoTrack? = nil,
        screenSharing: Bool = false
    ) {
        // 记住轨道本身：PeerConnection 重建换的是连接，不是麦克风。
        // 没有这两个引用，重建后的新连接就只能空着——人还在，声音没了。
        if let audio = audio { localAudio = audio }
        if let video = video { localVideo = video }
        if let screenTrack = screenTrack { localScreen = screenTrack }
        isSendingScreen = screenSharing

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
    func ensureLocalSenders() {
        let streamID = "tq-\(peerID)"
        if let audio = localAudio { ensureSender(for: audio, streamID: streamID) }
        if let video = localVideo { ensureSender(for: video, streamID: streamID) }
        if isSendingScreen, let screen = localScreen { ensureScreenSender(screen) }
    }

    /// 把屏幕轨 replace 到摄像头那条 sender 上（等价 replaceTrack，不产生协商）。
    ///
    /// 正常路径**不会新增 m-line**：camera mid 在入会首轮就谈好，
    /// 这里只换 sender 上挂的轨。
    ///
    /// 唯一的例外是本端根本没有 video m-line（摄像头权限被拒、设备被占用、
    /// 以"只投屏"方式入会）。这种情况下连 replace 的落点都没有，
    /// 只能补一条。补的时候刻意用 `addTransceiver(with:init:)` 而不是
    /// `addTransceiverOfType:init:`——后者的 Swift 导入名在不同 WebRTC 版本里
    /// 不一致（`of:` / `for:` 都出现过），而前者在本项目 1.7.x 就一直在用。
    private func ensureScreenSender(_ track: RTCVideoTrack) {
        localScreen = track
        isSendingScreen = true

        /* 首次共享必须真的**新建一条 m-line**，不能只 replaceTrack。
         *
         * replaceTrack 不产生 SDP 变更 —— 这是「iOS 在共享、浏览器看得见、
         * 安卓全黑」的根因。接收端拿远端轨只有 `onAddTrack` 一个入口，
         * 而它只在新 msid 出现在 SDP 里时触发。replaceTrack 之后 SDP 一字未变，
         * 对端手里就永远没有那条 VideoTrack：RTP 照样收、RTCP 零丢包、
         * 解码器照样工作，但没有任何东西 addSink 到渲染器 —— 纯黑。
         *
         * 这里先摘掉旧 sender，再用 `screen-` 流名新建一条：
         * SDP 里会出现全新的 `a=msid:screen-<peer> <trackId>`，
         * 对端必定收到 onAddTrack，而且 msid 前缀能被直接认成共享位
         * （安卓的 isScreenTrack 就是按这个前缀判的，不用再猜）。
         *
         * 代价是多一条 video m-line（旧那条退化成 recvonly，不占上行）。
         * 只在本次 PeerSession 的第一次共享发生一次，之后回到 replaceTrack。 */
        if !screenSdpBound {
            screenSdpBound = true
            let previous = videoSender
            if let sender = previous {
                peerConnection.removeTrack(sender)
                videoSender = nil
                videoTransceiver = nil
            }
            let configuration = RTCRtpTransceiverInit()
            configuration.direction = .sendRecv
            configuration.streamIds = ["screen-\(peerID)"]
            if let transceiver = peerConnection.addTransceiver(with: track, init: configuration) {
                videoTransceiver = transceiver
                videoSender = transceiver.sender
                screenTrackId = track.trackId
                ScreenShareRuntime.note("共享：已新建 screen m-line（让对端能收到 onAddTrack）")
                negotiate()
                return
            }
            /* 新建失败：退回 replaceTrack 路径，至少别把画面彻底断掉。 */
            ScreenShareRuntime.note("共享：新建 screen m-line 失败，退回 replaceTrack")
            videoSender = previous
        }

        if videoSender == nil {
            let configuration = RTCRtpTransceiverInit()
            configuration.direction = .sendRecv
            configuration.streamIds = ["tq-\(peerID)"]
            if let transceiver = peerConnection.addTransceiver(with: track, init: configuration) {
                videoTransceiver = transceiver
                videoSender = transceiver.sender
                ScreenShareRuntime.note("本端没有摄像头通道，已为共享补建一条")
            }
        }
        guard let sender = videoSender else {
            ScreenShareRuntime.note("共享：本条连接没有 video sender，无法挂载")
            return
        }
        sender.track = track
        screenTrackId = track.trackId
        /* 远端若是 sendonly（只发不收），这条 m-line 在我们这侧就是 recvonly，
           换轨也发不出去。拨回 sendRecv；方向没变时 WebRTC 不会触发协商。 */
        _ = videoTransceiver?.setDirection(.sendRecv, error: nil)
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

    /// 唤醒已经挂着的音频 sender（不产生 SDP 变更）。
    ///
    /// 只把 `track.isEnabled` 置 true，对**在我关着麦时新加入**的对端不生效：
    /// 它建连接那一刻拿到的是一条 disabled 的轨，audio send stream 从建立起
    /// 就停在"不发送"，之后再改 isEnabled 不会让 ADM 重新喂数据。
    /// `replaceTrack(nil)` → `replaceTrack(track)` 会重建这条 send stream，
    /// 不进协商、不改 mid，中断约 60ms，用户听不出来。
    func pulseAudioTrack(_ track: RTCAudioTrack) {
        guard !isClosed, let sender = audioSender else { return }
        sender.track = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self, weak sender] in
            Task { @MainActor in
                guard let self, let sender, !self.isClosed else { return }
                sender.track = track
            }
        }
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

        /* 先启用再 replace：上一轮停止共享时这条轨被置了 disabled，
           若先 replace 后启用，编码器会先收到一次"轨禁用"，
           在极短窗口里把刚建起来的 VideoSendStream 又拆掉。 */
        track.isEnabled = true
        ensureScreenSender(track)

        /* 复用已协商的 camera mid：正常路径这里**一次协商都不该发生**。
           只有两种例外会把帧卡死，必须补一轮：
             · mid 还空着（远端先发 offer 时 answer 里没这条 m-line）；
             · 方向谈成了不能发（m-line 被拒、或远端是 sendonly）。
           把判据收窄到这两条，是为了不再重演旧版的协商风暴：
           以前只要 msid 没带 `screen-` 前缀就判"没进 SDP"，每挂一次轨
           补一轮 offer，撞上 glare 就永远停在 haveLocalOffer。 */
        let mid = videoTransceiver?.mid
        let canSend = Self.screenMLineAcceptsSend(peerConnection.localDescription?.sdp, mid: mid)
            && Self.videoDirectionAllowsReceive(peerConnection.remoteDescription?.sdp, mid: mid)
        if !canSend {
            negotiate()
        }
    }

    /// 只换 sender 上的轨，不协商、不动 m-line。
    ///
    /// 用在"回环接收器明明有帧、编码器却 0 帧"的自愈里：这条 m-line 是好的，
    /// 坏的只是 sender 指向了另一条轨对象。
    func rebindScreenTrack(_ track: RTCVideoTrack) {
        guard !isClosed, isSendingScreen, let sender = screenSender else { return }
        sender.track = track
        screenTrackId = track.trackId
        localScreen = track
        track.isEnabled = true
    }

    /// 核对并纠正 sender 上真实挂着的轨。
    ///
    /// 用在两处：每次上行采样前（2 秒一次）和 attachScreenTrack 里。
    /// 返回 true 表示这次真的换过轨。
    ///
    /// 为什么要以"真实读数"为准：`screenTrackId` 只是本端的记账。
    /// 一旦 sender 上留的是重建前的旧轨，记账值照样是对的——
    /// 面板会显示"共享轨已挂"，编码器却是 0x0 零帧，这正是 1.9.0 的现场。
    @discardableResult
    func ensureScreenBinding(_ track: RTCVideoTrack) -> Bool {
        guard !isClosed, isSendingScreen, let sender = screenSender else { return false }
        guard sender.track?.trackId != track.trackId else { return false }
        sender.track = track
        screenTrackId = track.trackId
        localScreen = track
        track.isEnabled = true
        return true
    }

    /// 停止共享：把摄像头轨换回同一条 sender，**不拆 m-line**。
    ///
    /// 拆掉 m-line（`sender.track = nil` 等价 removeTrack）会让这条 m-line
    /// 的方向被重新谈成 recvonly，下一轮共享再 replace 回去也发不出，
    /// 必须重新协商——而重新协商正是历史上所有"0 包 0 帧"的入口。
    /// 所以没有摄像头时宁可在 sender 上留一条 disabled 的屏幕轨：
    /// 不出帧就没有 RTP，代价为零，但通道始终可发。
    func detachScreenTrack(renotify: Bool = true) {
        guard !isClosed else { return }
        isSendingScreen = false
        if let camera = localVideo {
            videoSender?.track = camera
        }
        screenTrackId = nil
        localScreen?.isEnabled = false
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

    /// 实际挂着的视频发送器数量（0 或 1）。
    var videoSenderCount: Int {
        videoSender == nil ? 0 : 1
    }

    /// 信令状态的人话。诊断必须打这一项：
    /// `localDescription` 有 `a=ssrc`、`outbound` 在涨、对端却一个包都收不到，
    /// 唯一能同时成立的解释就是**这轮 offer 从来没被对端应用过**——
    /// 本端停在 `haveLocalOffer`，包按新 SSRC 发出去，对端还按旧 SSRC 收，
    /// 于是全部静默丢弃。以前诊断里没有这一栏，只能靠猜。
    var signalingStateText: String {
        /* 注意：`RTCSignalingState` 里**没有** `.new`（`.new` 属于
           RTCIceGatheringState）。写 `case .new` 会直接编译失败——
           1.9.17 就是死在这一行，CI 43 秒退出，四个版本都没出包。
           "还没建起来"这个语义只能从远端描述是否为空来判断。 */
        let state = peerConnection.signalingState
        if state == .stable, peerConnection.remoteDescription == nil {
            return "new/无远端描述⚠️"
        }
        switch state {
        case .stable: return "stable"
        case .haveLocalOffer: return "有本地offer⚠️"
        case .haveRemoteOffer: return "有远端offer"
        case .haveLocalPrAnswer: return "本地临时应答⚠️"
        case .haveRemotePrAnswer: return "远端临时应答"
        case .closed: return "closed"
        @unknown default: return "未知"
        }
    }

    /// 共享开始时**主动重谈一轮**。
    ///
    /// 为什么不能只靠 replaceTrack：换轨不产生 SDP 变更，对端的接收器仍然
    /// 停在入会那一轮协商的结果上。只要那一轮的 offer/answer 有任何一环
    /// 没落地（信令重投、轮次错配、answer 被判重丢弃），对端手里就没有
    /// 当前这条 sender 的 SSRC，包发得再多也会被当成"未知 SSRC"丢掉。
    /// 现场特征正是：本端 `编码 3098 帧 / 发送 13204 包`，对端一片黑，
    /// 而同一条连接上的音频双向正常（音频 SSRC 从入会起就没变过）。
    ///
    /// 只在共享开始时打一次，且 `negotiate()` 内部有 glare / 卡死自愈，
    /// 不会重演 1.9.10 的协商风暴。
    func renegotiateForScreenShare() {
        guard !isClosed else { return }
        needsNegotiateAfterStable = true
        negotiate()
    }

    /// 逼编码器立刻吐一个 IDR。
    ///
    /// H.264 的接收端在拿到关键帧之前**一帧都解不出来**，而 libwebrtc 的
    /// H.264 编码器没有固定 GOP，全靠对端发 PLI。对端一旦漏掉开局那一个
    /// IDR（解码器还没建好、包还在路上），后面收到的全是 P 帧，
    /// 表现就是"包在涨、永远黑屏"，而且不会自愈。
    ///
    /// `replaceTrack(nil)` → `replaceTrack(track)` 会让 libwebrtc 重建
    /// VideoSendStream，新编码器的第一帧必然是 IDR。整个过程不触发协商
    /// （SDP 不变），中断约 80ms，用户看不到。
    func forceVideoKeyFrame() {
        guard !isClosed, let sender = videoSender, sender.track != nil else { return }
        sender.track = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak sender] in
            Task { @MainActor in
                guard let self, let sender, !self.isClosed else { return }
                // 期间用户可能已经停止共享或换了轨，别把旧轨塞回去。
                guard self.isSendingScreen, let current = self.localScreen else { return }
                sender.track = current
            }
        }
    }

    /// 视频通道对账：**SDP 声明的通道** 对 **sender 实际在用的 mid/ssrc**。
    ///
    /// 为什么必须打这一行：连续几个版本都出现同一组自相矛盾的数字——
    /// iOS 侧 `发视频 512 包 / 编码 80 帧`（outbound 明明在跑），
    /// 而安卓和浏览器的 `收视频` 都是 **0KB**（连一个字节都没关联上）。
    /// outbound 有数、inbound 为 0，只有一种解释：包发出去，但对端按 SDP
    /// 里的 mid/ssrc 关联不到这条 m-line，被静默丢弃——丢弃发生在统计之前，
    /// 所以对端的 inbound 连计数都不涨。
    /// 成因通常是 sender 重建（replaceTrack / 补建 transceiver）之后 SSRC
    /// 漂移，而 SDP 没有重新协商，仍写着旧值。
    ///
    /// 这一行把"声明"和"实际"并排放，`ssrc✓/✗` 一眼定生死：
    ///   · 全部 ✓ → 不是漂移，问题在对端的解码/渲染（去查它那边的 inFrames）；
    ///   · 出现 ✗ 或"无ssrc" → 就是漂移，必须重谈一次让 SDP 追上 sender。
    var videoChannelAudit: String {
        guard let sdp = peerConnection.localDescription?.sdp, !sdp.isEmpty else { return "无本地SDP" }
        let bundle = sdp.split(whereSeparator: { $0.isNewline })
            .first { $0.hasPrefix("a=group:BUNDLE") }
            .map { String($0.dropFirst("a=group:BUNDLE".count)).trimmingCharacters(in: .whitespaces) }
            ?? "无BUNDLE⚠️"

        struct Section {
            var mid = "-"
            var port = "?"
            var dir = "sendrecv"
            var ssrc: [String] = []
            /// `a=msid:<stream> <track>`。**这是对端能不能拿到轨的唯一凭据。**
            /// 缺了它，接收端的 onAddTrack 不会触发，RTP 收得再齐也画不出来。
            var msid = ""
        }
        var sections: [Section] = []
        var current: Section?
        var inVideo = false

        for raw in sdp.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            if line.hasPrefix("m=") {
                if let c = current { sections.append(c) }
                current = nil
                inVideo = line.hasPrefix("m=video")
                if inVideo {
                    let fields = line.split(separator: " ")
                    var s = Section()
                    s.port = fields.count > 1 ? String(fields[1]) : "?"
                    current = s
                }
                continue
            }
            guard inVideo, var c = current else { continue }
            if line.hasPrefix("a=mid:") {
                c.mid = String(line.dropFirst("a=mid:".count))
            } else if line.hasPrefix("a=ssrc:") {
                let value = line.dropFirst("a=ssrc:".count)
                    .split(separator: " ").first.map(String.init) ?? ""
                if !value.isEmpty, !c.ssrc.contains(value) { c.ssrc.append(value) }
            } else if line.hasPrefix("a=msid:") {
                c.msid = String(line.dropFirst("a=msid:".count)).trimmingCharacters(in: .whitespaces)
            } else if ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains(line) {
                c.dir = String(line.dropFirst(2))
            }
            current = c
        }
        if let c = current { sections.append(c) }

        let senderSsrc = videoSender?.parameters.encodings.first?.ssrc?.stringValue ?? "无"
        let senderMid = videoTransceiver?.mid ?? "无"
        let items = sections.map { s -> String in
            let ssrcText: String
            if s.ssrc.isEmpty {
                ssrcText = "无ssrc"
            } else if senderSsrc == "无" {
                ssrcText = "ssrc✗"
            } else {
                ssrcText = s.ssrc.contains(senderSsrc) ? "ssrc✓" : "ssrc✗"
            }
            /* msid 单独一个字段，因为它是"对端有没有轨"的直接判据。
               以前这行只打 ssrc，于是出现了一个解释不了的现场：
               本端 14233 包零丢包、对端 RTCP 也在回，可对方的 onAddTrack
               就是不触发 —— 因为 SDP 里这条 m-line 根本没有 a=msid。
               打出来就没什么可猜的了：
                 · `ms`      → 有 msid，对端该拿到轨；
                 · `ms✗`     → 没有，对端必定拿不到，就是黑屏的根。 */
            let msidText = s.msid.isEmpty ? "ms✗" : "ms"
            return "mid\(s.mid)/\(s.dir)/p\(s.port)/\(ssrcText)/\(msidText)"
        }
        let mismatch = senderSsrc == "无" || sections.contains { !$0.ssrc.isEmpty && !$0.ssrc.contains(senderSsrc) }
        let noMsid = sections.contains { !$0.msid.isEmpty == false && $0.ssrc.isEmpty == false }
        return "BUNDLE[\(bundle)] · 发送端 mid\(senderMid)/ssrc\(senderSsrc)"
            + " · \(items.isEmpty ? "无video段⚠️" : items.joined(separator: " · "))"
            + (mismatch ? " ⚠️漂移" : "")
            + (noMsid ? " ⚠️无msid" : "")
    }

    /// 本地 SDP 里所有 video 段声明过的 SSRC。
    private static func declaredVideoSsrcs(_ sdp: String?) -> [String] {
        guard let sdp, !sdp.isEmpty else { return [] }
        var result: [String] = []
        var inVideo = false
        for raw in sdp.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            if line.hasPrefix("m=") {
                inVideo = line.hasPrefix("m=video")
                continue
            }
            guard inVideo, line.hasPrefix("a=ssrc:") else { continue }
            let value = line.dropFirst("a=ssrc:".count)
                .split(separator: " ").first.map(String.init) ?? ""
            if !value.isEmpty, !result.contains(value) { result.append(value) }
        }
        return result
    }

    /// 视频通道自愈：把"本端在发、对端一个字节都收不到"这一类结构性问题
    /// 在一次重新协商里修掉。
    ///
    /// 三个触发条件，都会造成同一个现场（outbound 涨、对端 inbound 恒 0）：
    ///   1. sender 没有 ssrc —— encoding 没建起来，包根本组不出来；
    ///   2. SDP 声明的 ssrc 里没有 sender 正在用的那个 —— 典型是 replaceTrack
    ///      / 补建 transceiver 之后 sender 重建、SSRC 换了而 SDP 还是旧的，
    ///      对端按旧 SSRC 关联不上，静默丢弃（丢弃在统计之前，所以对端
    ///      连 bytesReceived 都不涨，"收视频 0KB"就是这么来的）；
    ///   3. transceiver 方向被谈成 recvonly/inactive —— 本端没有发送权。
    ///
    /// 只做一次，且只在 stable 时做：协商进行中再插一脚只会制造 glare。
    @discardableResult
    func healVideoChannelIfDrifted() -> Bool {
        guard !isClosed, peerConnection.signalingState == .stable else { return false }

        /* 最严重的一种：墙还没砌起来。
           现场出现过"对方已进会、我这边的这条 PC 长期停在
           signalingState=.new / 远端描述为空"——perfect negotiation 里
           polite 方等对方先开口，impolite 方本该主动，但只要两端算出
           同一个 polite 结论，就同时沉默，连接永远建不起来（浏览器那条
           一直是"新建 / ICE 新建 / 远端 无描述"）。
           没有 SDP 就无从谈 ssrc，所以这一条必须排在对账之前。 */
        if peerConnection.remoteDescription == nil {
            ScreenShareRuntime.note("视频通道自愈：远端描述为空，主动发一轮 offer")
            negotiate()
            return true
        }

        let ssrc = videoSender?.parameters.encodings.first?.ssrc?.stringValue
        let declared = Self.declaredVideoSsrcs(peerConnection.localDescription?.sdp)
        let direction = videoTransceiver?.direction
        let cannotSend = direction == .recvOnly || direction == .inactive

        let drifted: Bool
        if ssrc == nil {
            drifted = true
        } else if declared.isEmpty {
            drifted = true
        } else {
            drifted = !declared.contains(ssrc!)
        }

        guard drifted || cannotSend else { return false }

        if cannotSend {
            _ = videoTransceiver?.setDirection(.sendRecv, error: nil)
        }
        ScreenShareRuntime.note(
            "视频通道自愈：ssrc=\(ssrc ?? "无")/声明\(declared.count)条/方向\(direction.map { String($0.rawValue) } ?? "?") → 重新协商"
        )
        negotiate()
        return true
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
        let screenInSDP = Self.screenMLineAcceptsSend(localSDP, mid: screenTransceiver?.mid)
            && !midValue.isEmpty
        let remote = Self.videoDirectionAllowsReceive(peerConnection.remoteDescription?.sdp, mid: screenTransceiver?.mid) ? "可收" : "不可收 ⚠️"
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
           "m-line 在、ssrc 在、编码器在"都能成立而帧进不去，
           剩下的唯一解释就是 sender 连着另一条轨。 */
        let bound = isSendingScreen
            && screenSender?.track?.trackId == (localScreen?.trackId ?? "")
        return "SDP video \(videoMLines) · 共享\(screenSDPText) · 通道camera-replace"
            + " · sender \(screenSenderText)"
            + " · mid=\(mid)/enc=\(encodings.count)/ssrc=\(ssrc)"
            + " · \(codec)/\(level)/上限\(capText)"
            + " · 远端\(remote) · 信令 \(signaling) · ICE \(ice)"
            + " · 挂轨\(bound ? "一致" : "不一致 ⚠️")"
            + " · \(negotiationTrace)"
    }

    /// 本地 SDP 里有几条 video m-line。
    /// 1.9.11 起正常只有一条（摄像头与共享共用）。出现两条说明有旧会话
    /// 残留的僵尸通道，或者远端额外开了 recvonly 轨。
    private static func videoMLineCount(_ sdp: String?) -> Int {
        guard let sdp, !sdp.isEmpty else { return 0 }
        return sdp.split(whereSeparator: { $0.isNewline })
            .filter { $0.hasPrefix("m=video") }
            .count
    }

    /// 本地 SDP 里**共享所用的那条** video m-line 是否允许本端发送。
    ///
    /// 1.7.6 及以前判的是"最后一条 video 是否 sendonly"。这个前提只在
    /// m-line 顺序固定时成立。真机上一次 `SDP video 3` 就把判断带偏。
    /// 1.9.11 起共享复用 camera mid，判据收敛成两条：mid 命中 + 方向可发。
    /// **不再看 msid 前缀**——那时它已经不代表"这是屏幕流"，只代表
    /// "这条轨的 stream id 叫什么"，拿它做发送判定会造成假阴性，
    /// 每挂一次轨补一轮协商，撞上 glare 就永远停在 haveLocalOffer。
    private static func screenMLineAcceptsSend(_ sdp: String?, mid: String?) -> Bool {
        guard let mid, !mid.isEmpty else { return false }
        return videoSections(sdp).contains {
            $0.mid == mid && !$0.rejected
                && ($0.direction == "sendonly" || $0.direction == "sendrecv")
        }
    }

    private struct VideoSection {
        var mid = ""
        var rejected = false
        var direction = "sendrecv"
    }

    /// SDP session direction is inherited unless a media section overrides it.
    /// A rejected (port zero) section cannot send or receive, regardless of msid.
    private static func videoSections(_ sdp: String?) -> [VideoSection] {
        guard let sdp else { return [] }
        var sections: [VideoSection] = []
        var current: VideoSection?
        var sessionDirection = "sendrecv"
        var inSession = true
        for raw in sdp.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            if line.hasPrefix("m=") {
                if let current { sections.append(current) }
                inSession = false
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                if fields.first == "m=video" {
                    current = VideoSection()
                    current?.direction = sessionDirection
                    current?.rejected = fields.count < 2 || fields[1].split(separator: "/").first == "0"
                } else {
                    current = nil
                }
            } else if ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains(line) {
                let direction = String(line.dropFirst(2))
                if inSession { sessionDirection = direction }
                else { current?.direction = direction }
            } else if line.hasPrefix("a=mid:") {
                current?.mid = String(line.dropFirst(6))
            }
        }
        if let current { sections.append(current) }
        return sections
    }

    private static func videoDirectionAllowsReceive(_ sdp: String?, mid: String?) -> Bool {
        guard let mid, !mid.isEmpty else { return false }
        return videoSections(sdp).contains {
            $0.mid == mid && !$0.rejected
                && ($0.direction == "recvonly" || $0.direction == "sendrecv")
        }
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
        guard let track = localScreen else { return summary }
        summary.trackExists = true
        summary.trackEnabled = track.isEnabled
        /* 这里必须读 sender 上**真实**挂着的轨，不能读 screenTrackId。
           那个只是本端的记账值：记账写对了、sender 上却仍是旧轨时，
           记账会给出一个"已挂"的假绿，正好把 0x0 零帧掩盖掉。
           共享通道就是 camera mid，所以还要确认当前确实处于共享模式，
           否则停止共享后会把挂着的摄像头误报成"共享轨已挂"。 */
        summary.attached = isSendingScreen && screenSender?.track?.trackId == track.trackId
        // 复用 camera mid：共享能不能发，看的就是这条 m-line 的方向与拒绝状态。
        let localSDP = peerConnection.localDescription?.sdp
        summary.screenInSDP = Self.screenMLineAcceptsSend(localSDP, mid: screenTransceiver?.mid)
            && !(screenTransceiver?.mid ?? "").isEmpty
        summary.sendsUpstream = summary.screenInSDP
            && Self.videoDirectionAllowsReceive(peerConnection.remoteDescription?.sdp, mid: screenTransceiver?.mid)
        summary.senderCount = peerConnection.senders.filter { $0.track?.kind == "video" }.count
        return summary
    }

    /// 共享 sender 的编码器事实，供 RealRTCClient 写进自愈流水。
    var screenSenderFacts: String {
        let midText = screenTransceiver?.mid ?? ""
        let mid = midText.isEmpty ? "-" : midText
        let encodings = screenSender?.parameters.encodings ?? []
        let ssrc = encodings.first?.ssrc == nil ? "无" : "有"
        let bound = screenSender?.track?.trackId == localScreen?.trackId
        return "route=camera-replace 共享\(isSendingScreen ? "中" : "停")"
            + " 挂轨\(bound ? "一致" : "不一致") mid=\(mid) enc=\(encodings.count) ssrc=\(ssrc)"
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
        /* 共享与摄像头现在共用同一条 sender。
           如果不挡住"模式不匹配"的调用，两条预算会互相覆盖：
           共享中摄像头 duck 把 8Mbps/30fps 改成 250kbps/10fps，
           画面立刻糊成一片；反过来，非共享时套上共享预算，
           摄像头会被抬到 8Mbps 白吃带宽。 */
        guard forScreen == isSendingScreen else { return }
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
            } else if !forScreen {
                /* 共享时给过 35% 的产出下限，停止共享后必须清掉：
                   否则摄像头会带着"不许低于 2.8Mbps"的约束去和
                   新一场共享抢带宽。 */
                encoding.minBitrateBps = nil
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
            if isVideo {
                /* 摄像头轨被重建（切换前后摄、权限重新授予）时，
                   sender 上还连着旧轨的话，画面上会一直是上一颗镜头的残影。
                   共享期间**不能**换——那会把我自己推的屏幕换成摄像头。 */
                videoTrackId = track.trackId
                if !isSendingScreen { videoSender?.track = track }
            }
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
        guard !isClosed, !ignoreOffer else { return }
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
        negotiateStartedAt = Date()
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
                        self.negotiateStartedAt = nil
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
        bindRemoteVideoRenderer()
        return view
    }

    /// 当前绑在预览视图上的那条轨。重复 add/remove 会让 MTL 渲染器
    /// 重建纹理，屏幕共享期间每次 screen:state 抖一下就是一次黑闪。
    private weak var boundRemoteTrack: RTCVideoTrack?

    /// 把远端 track 绑到渲染视图。
    func bindRemoteVideoRenderer() {
        guard let track = remoteVideoTrack, let view = remoteVideoView else { return }
        if boundRemoteTrack === track { return }
        boundRemoteTrack?.remove(view)
        track.add(view)
        boundRemoteTrack = track
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
        boundRemoteTrack = nil
        pendingScreenOffWork?.cancel()
        pendingScreenOffWork = nil
        if let track = clockedCameraTrack { track.remove(cameraClock) }
        if let track = clockedScreenTrack { track.remove(screenClock) }
        clockedCameraTrack = nil
        clockedScreenTrack = nil
        cameraClock.reset()
        screenClock.reset()
        remoteVideoView = nil
        remoteVideoTrack = nil
        remoteCameraTrack = nil
        remoteScreenTrack = nil
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
        // 远端 SDP 是对方真实能力，必须保持原文。
        let target = description
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
                self.ignoreOffer = false
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
        // 仅筛选本地 offer；answer 保留 WebRTC 的真实协商结果。
        if narrowed, description.type == .offer {
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
        /* 这里**不能**改 `profile-level-id`，1.9.9 已经踩过一次。
           它不是"告诉对端我能编多大"，而是本端编码器的构造参数：
           `setLocalDescription` 会把这份 SDP 解析进 VideoChannel，
           `send_codecs_` 的 fmtp 直接喂给 `RTCVideoEncoderH264`，
           后者原样映射成 `kVTCompressionPropertyKey_ProfileLevel`。
           把 42001f 抬成 420028（Baseline 4.0）之后，VideoToolbox 在
           一部分 iPhone 上直接拒绝建 session，`VTCompressionSessionCreate`
           返回失败 —— 现象就是"扩展出帧 172、已推 RTC 169、发送 0 包、
           编码 0 帧、共享轨已挂"，四个绿灯加一个零。
           同一台机器在 1.9.7（没有这行）上是 687 帧，时间关联非常干净。
           带宽/分辨率的上限走 encodings 与 adaptOutputFormat，不走 SDP 伪造。 */
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
                       这一步只发生一次，不会递归。
                       必须带 `narrowed`：level 修正在退回后仍然生效，若不加这个
                       条件，任何一次失败都会被判成"还能再退"，同一条描述反复重投
                       直到栈溢出（协商状态变化导致的失败尤其容易踩到）。 */
                    if narrowed, target.sdp != description.sdp {
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
        /* 协商卡死自愈。
           `makingOffer` 只在 offer 回调与 setLocalDescription 的
           completion 里复位。真机上偶发其中一条永远不来，这个标志就
           永久 true，之后每次 negotiate() 都只记一笔
           `needsNegotiateAfterStable` 就返回，而那个标志只有"回到
           stable"才会被消费 —— 永远等不到。现场表现正是
           "轨挂着、帧在推、编码 0 帧、发送 0 包"。
           超过 6 秒还在"协商中"，就当上一轮已经死掉，重开一轮。

           注意这里是 if/else 而不是 guard：复位分支必须**继续往下走**
           去发 offer，用 guard 会要求 else 块一定退出作用域。 */
        if makingOffer || isNegotiating {
            if let at = negotiateStartedAt,
               Date().timeIntervalSince(at) > 6,
               peerConnection.signalingState == .stable {
                makingOffer = false
                isNegotiating = false
                negotiateStartedAt = nil
                ScreenShareRuntime.note("协商超过 6 秒未完成，已复位标志重试")
            } else {
                // 协商正在进行。直接 return 会让这次 addTrack 永远没有对应的 offer，
                // 记下来，等回到 stable 再补——这是"本地轨挂上了却一个包都不发"的根因之一。
                needsNegotiateAfterStable = true
                return
            }
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
        /* 以前只重发 3 次。现场「远端 无描述 + 有本地offer」的卡死经常拖到
           第 3 次之后才恢复——对端刚进会、它的信令还在重连、answer 排在队列
           后面，前三次全部落空，这条连接就永久停在 haveLocalOffer：
           对方那边一片黑，而本端所有计数器都是正常的。
           重发一份 SDP 的成本只是一条信令消息，没必要设这么死的上限。 */
        guard offerRetryCount < 20 else { return }
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
        let streamIDs = mediaStreams.map { $0.streamId }
        let receiverID = rtpReceiver.receiverId
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
                    // streamless Unified Plan 也从对应 mid 的远端 SDP 读取 msid。
                    let mid = self.peerConnection.transceivers.first {
                        $0.receiver.receiverId == receiverID
                    }?.mid
                    let sections = (self.peerConnection.remoteDescription?.sdp ?? "")
                        .components(separatedBy: "\nm=")
                    let section = mid.flatMap { value in
                        sections.first { section in
                            section.components(separatedBy: "\n").contains {
                                $0.trimmingCharacters(in: .whitespacesAndNewlines) == "a=mid:\(value)"
                            }
                        }
                    } ?? ""
                    let isScreen = streamIDs.contains { $0.hasPrefix("screen-") }
                        || section.contains("a=msid:screen-")
                    if isScreen {
                        self.remoteScreenTrack = video
                    } else {
                        self.remoteCameraTrack = video
                    }
                    self.attachFrameClock(to: video, isScreen: isScreen)
                    self.selectRemoteVideoTrack()
                    self.delegate?.peerSession(self, didReceiveRemoteVideo: video)
                }
            default:
                break
            }
        }
    }
}
