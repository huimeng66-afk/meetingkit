//
//  RealRTCClient.swift
//  MeetingKit
//
//  对接天穹服务端的真实 RTC 实现。替换 MockRTCClient 成为默认客户端。
//
//  链路：REST(/rtc/ice) 取 STUN/TURN → 本地采集（摄像头 720p / 麦克风 48k）
//  → Socket.IO room:join → 每个远端一条 PeerConnection（P2P Mesh）
//  → Perfect Negotiation + ICE restart + 断线自动重连。
//
//  屏幕共享与 Web 端同一策略：共享帧替换 video sender（replaceTrack），
//  远端靠服务端 screen:state 事件区分"这是共享画面"。
//  iOS 侧共享帧来源：Broadcast 扩展写入 App Group 的 JPEG（SharedFrameStore），
//  主 App 解码后 push 进 RTCVideoSource，再 replaceTrack 到每个 peer。
//
//  线程模型：
//    · 本类标注 @MainActor，所有状态与 delegate 回调都在主线程；
//    · WebRTC 回调（RTC 内部队列）通过 Task { @MainActor } 汇流；
//    · JPEG 解码与帧构造在专用后台队列，不阻塞主线程。
//

import Foundation
import UIKit
import QuartzCore
import WebRTC

@MainActor
final class RealRTCClient: NSObject, RTCClient {

    // MARK: - RTCClient

    weak var delegate: RTCClientDelegate?

    // MARK: - 状态（仅主线程）

    private(set) var isJoined = false
    private(set) var connectionState: ConnectionState = .disconnected

    private var options: JoinOptions?
    private var selfPeerID: String = ""
    private var selfUserID: Int?
    private var isSelfHost = false
    private var selfName: String = ""
    private var selfAvatarColor: String = ""
    private var localHandRaised = false
    private var meetingInfo: [String: Any] = [:]
    /// 屏幕共享推流中（Broadcast 扩展确认后置 true）。
    private var isScreenSharing = false
    /// 当前摄像头设备（RTCCameraVideoCapturer 不暴露当前设备，需要自己记录）。
    private var currentCameraDevice: AVCaptureDevice?

    /// 远端参会者：peerId → 信息 + 会话。
    private final class RemotePeer {
        let peerID: String
        var name: String
        var role: String
        var audio: Bool
        var video: Bool
        var screen: Bool
        var hand: Bool
        var userId: Int?
        var avatarColor: String
        var session: PeerSession

        init(peerID: String, name: String, role: String, audio: Bool, video: Bool, screen: Bool, hand: Bool, userId: Int?, avatarColor: String, session: PeerSession) {
            self.peerID = peerID
            self.name = name
            self.role = role
            self.audio = audio
            self.video = video
            self.screen = screen
            self.hand = hand
            self.userId = userId
            self.avatarColor = avatarColor
            self.session = session
        }
    }

    private var remotePeers: [String: RemotePeer] = [:]

    /// 收到 `screen:state(on)` 时对应 peer 还没建出来（信令事件先于 peer:joined
    /// 到达的竞态）。先记下，等 peer 建好立刻补一次屏幕态，否则这条共享
    /// 会永远停在"服务端说在共享、客户端没有舞台"的状态。
    private var pendingScreenPeerID: String?

    /// 已消费的聊天消息 id（重连恢复快照时去重）。
    private var consumedMessageIDs: Set<String> = []

    // MARK: - 组件

    private var signaling: TianqiongSignaling?
    private var factory: RTCPeerConnectionFactory?
    private var iceServers: [RTCIceServer] = []

    /// 进程内唯一的 PeerConnectionFactory。
    ///
    /// 旧实现每次 join 都 new 一个：factory 内部持有 AudioDeviceModule、
    /// 编解码器和线程池，重复创建会让音频设备在"上一场会的旧实例"和
    /// "这一场的新实例"之间来回切，真机上表现为第一场正常、第二场没声。
    /// Jitsi 也是全局单例（`RTCPeerConnectionFactory` 只初始化一次）。
    private static let sharedFactory = RTCPeerConnectionFactory()

    private var localAudioTrack: RTCAudioTrack?
    /// 首次收到远端音频的标志：只做一次路由修正。
    private var didHandleFirstRemoteAudio = false
    private var localVideoTrack: RTCVideoTrack?
    private var localVideoSource: RTCVideoSource?
    private var localScreenTrack: RTCVideoTrack?
    private var localScreenSource: RTCVideoSource?
    /// iOS 27 的 ScreenCaptureKit 需要直接往这个 source 推帧。
    /// 广播扩展那条路是"扩展写 JPEG → 主 App 解码 → 推 source"，
    /// SCK 没有中间文件，帧从 SCStream 直接进来。
    var screenVideoSource: RTCVideoSource? { localScreenSource }
    private var videoCapturer: RTCCameraVideoCapturer?
    /// 摄像头是否正在采集。与 `localVideoTrack.isEnabled` 分开：
    /// 轨可以一直是开的，但采集停了（关摄像头时 stopCapture 会熄灯）。
    private var isCameraCapturing = false
    /// 本地音频电平轮询。WebRTC 没有公开的"当前麦克风电平"API，
    /// 只能从 getStats 的 media-source 统计里取 audioLevel。
    private var audioLevelTimer: Timer?

    // 单人会议时的本地电平来源：**不存在。**
    //
    // 这是 1.5.0 最重要的一处删除。
    //
    // 1.4.6 用 loopback 探针（和主连接共用同一条麦克风轨）导致"收得到、发不出"；
    // 1.4.9 换成 AVAudioRecorder 后问题换了个形态：录音器和 WebRTC 的
    // VoiceProcessingIO 抢同一个设备，且 `stop()` 里的 `setActive(false)`
    // 会把 WebRTC 刚启动的 AudioUnit 一起按停。线上表现就是
    // "一个人开会正常，有人一进来麦克风就死了"——因为 peerJoined
    // 正好触发了录音器的停止。
    //
    // 单人会议没有 RTP 通道，本来就不存在"发送电平"这个东西。
    // 界面如实显示"麦克风已就绪"，不做假波形，比演一个会动的环更可信。

    /// 上行音频健康度：连续多轮统计里 packetsSent 不增长，说明
    /// AudioDeviceModule 已经停采（而不是 sender 没挂上）。
    private var lastOutboundAudioTotal: Int = -1
    private var lastOutboundAudioCheckAt: Date = .distantPast
    private var stagnantOutboundChecks = 0
    /// 设备级重启的冷却时间：重启一次要断 200ms 左右，不能连环触发。
    private var lastAudioPipelineRestartAt: Date = .distantPast

    /// 一次 RTP 音频的能量快照。
    ///
    /// 为什么要自己算电平：`audioLevel` 这个统计字段在 iOS 的 WebRTC 里
    /// 只有对端开了 RTP 头扩展（ssrc-audio-level）才会被填。线上两台 iOS
    /// 或者网页端没协商该扩展时，`audioLevel` 恒为 0——诊断面板和"谁在说话"
    /// 的脉冲就永远是死的。`totalAudioEnergy / totalSamplesDuration` 是
    /// 累计量，不依赖头扩展，做差分就能还原出真实 RMS。
    private struct AudioEnergySample {
        var energy: Double
        var duration: Double
    }

    private var lastRemoteEnergy: [String: AudioEnergySample] = [:]
    private var lastLocalEnergy: AudioEnergySample?
    /// 最近一次算出的电平，诊断面板直接复用，避免再对同一份数据算一遍。
    private var latestLocalLevel: Float = 0
    private var latestRemoteLevel: [String: Float] = [:]

    /// 共享视频上行看门狗：起播 4 秒后仍有 peer 一个视频包没发出去，
    /// 说明 sender 方向或 track 挂载有问题，强制重挂一次。
    private var videoUplinkWatchdog: DispatchWorkItem?

    /// 上行音频看门狗（peerID → 待执行的探测）。
    private var outboundAudioWatchdogs: [String: DispatchWorkItem] = [:]
    private var outboundAudioProbeCounts: [String: Int] = [:]
    private var previewView: RTCCameraPreviewView?

    private var screenPusher: ScreenFramePusher?

    /// 扬声器偏好。路由看守要按它判断，否则用户手动切到听筒后
    /// 会被每 2 秒一次的看守强行顶回扬声器。
    private var speakerOn = true

    /// 共享期间的音频路由看守（ReplayKit 会在起播时重配一次 AVAudioSession）。
    private var routeGuardTimer: DispatchSourceTimer?

    /// 音频会话恢复失败后的重试节流。失败时（例如正在通话中）每 0.6 秒
    /// 重试一次会白白耗电，2 秒一次足够。
    private var lastAudioRecoveryAt = Date.distantPast

    /// join 是否已经走完（防止重复 join）。
    private var hasCompletedJoin = false

    // MARK: - 生命周期

    /// nonisolated deinit 不能访问隔离属性；清理对象统一放盒子里，
    /// 与 MeetingTeardownBox 同款模式（leave() 是主清理路径，deinit 只兜底）。
    private nonisolated let teardown = RealRTCTeardownBox()

    deinit {
        teardown.invalidate()
    }

    // MARK: - join

    func join(roomID: String, me: MeetingUser, options: JoinOptions) async throws {
        // 幂等：重复 join 直接返回。
        guard !isJoined, !hasCompletedJoin else { return }
        hasCompletedJoin = true
        self.options = options

        updateConnectionState(.connecting)

        // 1. ICE 服务器（STUN/TURN 临时凭证，访客可用）。
        let servers: [RTCIceServer]
        do {
            let configs = try await Self.fetchIceServersAsync()
            servers = configs.map(Self.makeIceServer)
        } catch {
            // ICE 拉取失败不致命：继续用空列表，直连仍然可能成功。
            // 但把原因记下来，方便排障。
            print("[rtc] ice servers fetch failed, fallback to host candidates")
            servers = []
        }
        self.iceServers = servers

        // 2. 本地媒体（权限弹窗在此刻出现：用户在入会页点下"加入会议"之后）。
        do {
            try await setupLocalMedia(
                audioOn: options.audioOn,
                videoOn: options.videoOn,
                cameraOn: options.videoOn
            )
        } catch {
            hasCompletedJoin = false
            teardownLocalMedia()
            updateConnectionState(.disconnected)
            throw RTCJoinError(message: error.localizedDescription, code: "MEDIA_DENIED")
        }

        // 3. 信令连接 + room:join。
        let signaling = TianqiongSignaling(token: options.token)
        signaling.delegate = self
        self.signaling = signaling

        // 等待 socket 连上（无限重试策略下，第一次连不上会一直重试；
        // 这里给首连一个窗口，超时直接报错，避免用户无限等待）。
        do {
            try await connectSignaling(signaling, timeout: 12)
        } catch {
            hasCompletedJoin = false
            signaling.disconnect()
            self.signaling = nil
            teardownLocalMedia()
            updateConnectionState(.disconnected)
            throw RTCJoinError(message: "无法连接会议服务器，请检查网络", code: "SOCKET_FAILED")
        }

        // 4. room:join（带 ack）。失败抛服务端错误码。
        do {
            let snapshot = try await joinRoom(signaling, options: options)
            // 先置入会态再应用快照：publishParticipants 依赖 isJoined。
            isJoined = true
            applyJoinSnapshot(snapshot)
        } catch let failure as JoinFailure {
            hasCompletedJoin = false
            signaling.disconnect()
            self.signaling = nil
            teardownLocalMedia()
            updateConnectionState(.disconnected)
            throw RTCJoinError(message: failure.message, code: failure.code)
        } catch {
            hasCompletedJoin = false
            signaling.disconnect()
            self.signaling = nil
            teardownLocalMedia()
            updateConnectionState(.disconnected)
            throw RTCJoinError(message: "入会失败，请重试", code: "JOIN_FAILED")
        }

        updateConnectionState(.connected)
        updateNetworkQuality(.good)
        /* 建连过程中 WebRTC 的 audio unit 才真正启动；此时再抢一次 session，
           保证首帧音频和麦克风采集都落在 playAndRecord 路由上。 */
        reactivateAudioSession()
        syncTeardownBox()
        startAudioLevelPolling()
        startLifecycleObservers()
    }

    // MARK: - 前后台与音频恢复

    /// 后台任务句柄。进入后台时申请一次，回到前台立刻归还。
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// 生命周期观察者。只在入会期间有效：出会必须精确摘掉，
    /// 否则回调会打到已经释放的 audio track 上。
    private var lifecycleTokens: [NSObjectProtocol] = []

    private func startLifecycleObservers() {
        guard lifecycleTokens.isEmpty else { return }
        let center = NotificationCenter.default
        let main: OperationQueue = .main

        lifecycleTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnterBackground() }
        })

        lifecycleTokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnterForeground() }
        })

        /* 来电、闹钟、控制中心、开始录屏广播都可能打断音频会话。
           结束后系统不会替我们把 WebRTC 的 audio unit 抢回来，
           表现就是"能看见人、就是没声音"。 */
        lifecycleTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: main
        ) { [weak self] note in
            // 只把 Sendable 的标量带进 actor，Notification 本身不跨线程传。
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.handleAudioInterruptionEnded(rawType: raw) }
        })

        lifecycleTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: main
        ) { [weak self] _ in
            Task { @MainActor in self?.reactivateAudioSession() }
        })
    }

    private func stopLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleTokens.forEach { center.removeObserver($0) }
        lifecycleTokens.removeAll()
        endBackgroundTask()
    }

    private func handleEnterBackground() {
        // 本 App 声明了 audio 后台模式：只要音频单元还在跑，进程就不会被冻住，
        // Socket.IO 的心跳也就能继续发。这一步是"后台保活"的地基。
        reactivateAudioSession()

        // 再叠一层 30 秒续命：即使音频被系统掐掉，也足够覆盖
        // "切出去看一眼网页端再切回来"这种最常见的操作。
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "meeting.keepalive") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func handleEnterForeground() {
        endBackgroundTask()
        reactivateAudioSession()

        // 不等 Socket.IO 的指数退避（最多 10 秒一次）：回来立刻拉一次。
        signaling?.reconnectIfNeeded()

        // 断线期间服务端可能已经清掉了 screenPeerId，回来补一次声明。
        if isScreenSharing {
            signaling?.sendMediaState(audio: nil, video: nil, screen: true)
        }
    }

    private func handleAudioInterruptionEnded(rawType: UInt?) {
        guard
            let raw = rawType,
            let type = AVAudioSession.InterruptionType(rawValue: raw),
            type == .ended
        else { return }
        // 不检查 shouldResume：共享广播、部分机型来电结束后系统不给这个标记，
        // 但用户在会议里，声音必须回来。
        reactivateAudioSession()
    }

    /// 重新把音频会话抢回 playAndRecord + voiceChat + active。
    /// 幂等：只在 category / mode / active 真的不对时才碰系统。
    ///
    /// 为什么不能每次都无脑 setCategory：会议进行中改 category 会触发一次
    /// 路由重配，正在播放的远端声音会断一拍。旧实现每次开麦、每次远端音频
    /// 到达都要重设一遍，长会里能听到规律的"咔哒"。
    ///
    /// 对照 Jitsi 的 `RTCAudioSessionConfiguration`：category / mode / options
    /// 必须一次性写全。只 setCategory 不设 mode，系统可能沿用上一次的
    /// `AVAudioSessionModeVideoRecording`（共享广播扩展留下的），
    /// 那种模式下采集增益极低，对方听到的就是"有电流声、听不清人声"。
    private func reactivateAudioSession(force: Bool = false) {
        let av = AVAudioSession.sharedInstance()
        let session = RTCAudioSession.sharedInstance()

        /* 不能只比对 category 和 mode：
           ReplayKit 起播时会用同一个 .playAndRecord 重设一次，但把
           .defaultToSpeaker 抹掉——category/mode 看起来全对，声音却从听筒出来。
           所以说话人选项也要参与判断（两个方向都要查：用户选了听筒，
           ReplayKit 也可能反过来把 defaultToSpeaker 加回来）。 */
        let speakerOptionMismatch = speakerOn
            ? !av.categoryOptions.contains(.defaultToSpeaker)
            : av.categoryOptions.contains(.defaultToSpeaker)
        let needsRoute = force
            || av.category != .playAndRecord
            || av.mode != .voiceChat
            || speakerOptionMismatch

        session.lockForConfiguration()
        do {
            if needsRoute {
                let options: AVAudioSession.CategoryOptions = speakerOn
                    ? [.allowBluetooth, .defaultToSpeaker]
                    : [.allowBluetooth]
                try session.setCategory(.playAndRecord, with: options)
                try session.setMode(.voiceChat)
            }
            if force || !session.isActive {
                try session.setActive(true)
            }
            /* 强制恢复时把输出口也钉到用户选的设备上。
               接着耳机/蓝牙时不动——override 会把人家的路由抢走。 */
            if force, !hasExternalAudioRoute(av) {
                try session.overrideOutputAudioPort(speakerOn ? .speaker : .none)
            }
            /* 自动音频模式下 WebRTC 会自行 start/stop audio unit；
               这里只需确认它没被上一次中断留在 stop 状态。 */
            if !session.isAudioEnabled {
                session.isAudioEnabled = true
            }
        } catch {
            print("[rtc] audio session activate failed: \(error.localizedDescription)")
            // 一次失败多半是设备被别的进程占着：稍后再试一次，
            // 不把错误抛给用户——真正的兜底是上行看门狗。
            let now = Date()
            if now.timeIntervalSince(lastAudioRecoveryAt) > 2 {
                lastAudioRecoveryAt = now
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, self.isJoined else { return }
                    self.reactivateAudioSession(force: true)
                }
            }
        }
        session.unlockForConfiguration()
    }

    /// 当前是否接着耳机 / 蓝牙 / AirPlay / USB 声卡。
    private func hasExternalAudioRoute(_ session: AVAudioSession) -> Bool {
        let external: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
            .airPlay, .usbAudio
        ]
        return session.currentRoute.outputs.contains(where: { external.contains($0.portType) })
    }

    // MARK: - 共享期间的音频路由看守

    /// 共享期间每 2 秒核对一次音频会话。
    ///
    /// ReplayKit 在广播真正起播时（用户点完"开始直播"后 200~800ms）会重配一次
    /// AVAudioSession：不发 routeChange 通知，也不保证保留 .defaultToSpeaker。
    /// 结果就是主 App 的 audio unit 被顺手掐掉——共享画面起来了，声音却躺下了。
    ///
    /// 为什么不能只在 beginScreenFramePush 里同步抢一次：那个时间点常常
    /// 早于 ReplayKit 的第二次重配，抢了等于没抢。
    private func startRouteGuard() {
        guard routeGuardTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.tianqiong.meetingkit.routeguard", qos: .utility)
        )
        timer.schedule(deadline: .now() + 0.3, repeating: 2.0, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.checkAudioRoute() }
        }
        routeGuardTimer = timer
        timer.resume()
    }

    private func stopRouteGuard() {
        routeGuardTimer?.cancel()
        routeGuardTimer = nil
    }

    private func checkAudioRoute() {
        guard isJoined, isScreenSharing else { return }
        let av = AVAudioSession.sharedInstance()
        let speakerOptionMismatch = speakerOn
            ? !av.categoryOptions.contains(.defaultToSpeaker)
            : av.categoryOptions.contains(.defaultToSpeaker)
        let fellBackToEarpiece = speakerOn
            && !hasExternalAudioRoute(av)
            && av.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver })
        let wrongRoute = av.category != .playAndRecord
            || av.mode != .voiceChat
            || speakerOptionMismatch
            || fellBackToEarpiece
        guard wrongRoute else { return }

        print("[rtc] route guard: category=\(av.category.rawValue) mode=\(av.mode.rawValue) → 抢回")
        reactivateAudioSession(force: true)
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func leave() {
        guard isJoined || signaling != nil else {
            hasCompletedJoin = false
            return
        }
        isJoined = false
        stopAudioLevelPolling()
        hasCompletedJoin = false
        options = nil
        // 先告诉服务端"主动离开"（释放位置，不等断线宽限），
        // 给 room:leave 一个发送窗口再断开，避免包还没出网就被 disconnect 掐掉。
        let sig = signaling
        sig?.leaveRoom()
        signaling = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Task { @MainActor in
                sig?.disconnect()
            }
        }

        // 关掉所有 peer 连接与远端视图。
        for peer in remotePeers.values {
            peer.session.close()
            delegate?.rtcDidLoseRemoteMedia(for: peer.peerID)
        }
        remotePeers.removeAll()
        clearAllAudioLevelState()
        resetOutboundAudioTracking()
        didHandleFirstRemoteAudio = false
        consumedMessageIDs.removeAll()
        selfPeerID = ""
        selfUserID = nil
        isSelfHost = false
        localHandRaised = false
        meetingInfo = [:]

        // 停共享推流 + 释放本地设备。
        teardownLocalMedia()

        updateNetworkQuality(.unknown)
        updateConnectionState(.disconnected)
        syncTeardownBox()
    }

    /// 释放本地采集与音频会话（入会失败 / 主动离开共用）。
    private func teardownLocalMedia() {
        stopLifecycleObservers()
        stopVideoUplinkWatchdog()
        stopRouteGuard()
        screenPusher?.stop()
        screenPusher = nil
        isScreenSharing = false
        videoCapturer?.stopCapture()
        videoCapturer = nil
        currentCameraDevice = nil
        previewView?.captureSession = nil
        previewView = nil
        localAudioTrack = nil
        localVideoTrack = nil
        localScreenTrack = nil
        localScreenSource = nil
        resetOutboundAudioTracking()
        // 释放后音视频设备指示灯应立即熄灭。isActive 是只读属性，关闭要走 setActive。
        try? RTCAudioSession.sharedInstance().setActive(false)
    }

    /// 把当前需要清理的对象同步给 nonisolated 盒子，供 deinit 兜底。
    private func syncTeardownBox() {
        teardown.update(
            signaling: signaling,
            sessions: remotePeers.values.map { $0.session },
            pusher: screenPusher
        )
    }

    // MARK: - 设备控制

    func setMicEnabled(_ enabled: Bool) {
        guard let track = localAudioTrack else {
            /* 轨不存在（权限刚放开 / 入会时被拒 / 上一轮会话重建）：
               不能静默 return，否则用户点开麦只会看到图标亮着、实际没轨。 */
            if enabled {
                ensureMicEnabled(true, completion: nil)
            }
            return
        }
        if enabled {
            /* 只把 track.isEnabled 置 true 不够：用户在系统设置里刚打开权限、
               或音频会话被来电/共享广播打断过时，RTCAudioSession 可能已经
               inactive。不重新抢回 session，表现就是"图标亮了、对方没声音"。 */
            reactivateAudioSession()
        }
        track.isEnabled = enabled
        publishLocalMediaState()
        publishParticipants()
    }

    /// 开麦自愈：轨不存在 / 已失效时重建，并接回所有 peer 的音频 sender。
    ///
    /// 对应 Jitsi 的 `setTrackMuted` + `IGUMPendingState.PENDING_UNMUTE`：
    /// 调用方在 completion 返回前应把按钮置为"开启中"，返回后按结果落定或回滚。
    func ensureMicEnabled(_ enabled: Bool, completion: ((Bool, String?) -> Void)? = nil) {
        guard enabled else {
            setMicEnabled(false)
            completion?(true, nil)
            return
        }
        if let track = localAudioTrack, track.readyState == .live {
            setMicEnabled(true)
            completion?(true, nil)
            return
        }

        Task { @MainActor in
            let granted = await Self.requestMicPermission()
            guard granted else {
                completion?(false, "麦克风权限未开启，请到系统设置里允许后重试")
                return
            }
            guard let track = self.rebuildAudioTrack() else {
                completion?(false, "麦克风启动失败，请重试")
                return
            }
            track.isEnabled = true
            for peer in self.remotePeers.values {
                peer.session.replaceAudioTrack(with: track)
            }
            self.setMicEnabled(true)
            completion?(true, nil)
        }
    }

    /// 重建本地音频轨。只换音频，不动摄像头、不重建 PeerConnection——
    /// 重建连接会把整场会议的音视频都断一次，代价远大于换一条轨。
    @discardableResult
    private func rebuildAudioTrack() -> RTCAudioTrack? {
        guard let factory = factory else { return nil }
        reactivateAudioSession()
        let source = factory.audioSource(
            with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        )
        let track = factory.audioTrack(with: source, trackId: "audio-\(UUID().uuidString)")
        localAudioTrack = track
        return track
    }

    func setCameraEnabled(_ enabled: Bool) {
        guard let track = localVideoTrack else { return }

        guard enabled else {
            track.isEnabled = false
            videoCapturer?.stopCapture()
            isCameraCapturing = false
            publishLocalMediaState()
            publishParticipants()
            return
        }

        // 先把轨与界面状态打开：采集启动是异步的，等它完成再改 UI 会有一段黑屏。
        track.isEnabled = true
        publishLocalMediaState()
        publishParticipants()

        // 已经在采集（入会时摄像头就是开的）：只打开轨即可，不必再碰硬件。
        guard !isCameraCapturing else { return }

        // 首次开启才请求权限：入会时关着摄像头的人，不应该一进来就被弹窗拦住。
        Task { [weak self] in
            guard let self = self else { return }

            let granted = await Self.requestCameraPermission()
            guard granted,
                  let device = Self.preferredCameraDevice(),
                  let format = Self.bestFormat(for: device) else {
                // 开不起来就退回关闭状态，并明确告诉界面——
                // 否则图标显示"已开"，画面永远是黑的。
                self.localVideoTrack?.isEnabled = false
                self.isCameraCapturing = false
                self.publishLocalMediaState()
                self.publishParticipants()
                self.delegate?.rtcDidUpdateLocalCamera(false)
                return
            }

            self.currentCameraDevice = device
            self.videoCapturer?.startCapture(with: device, format: format, fps: Self.cameraFPS) { error in
                if let error = error {
                    print("[rtc] camera resume failed: \(error.localizedDescription)")
                }
            }
            self.isCameraCapturing = true
        }
    }

    func switchCamera() {
        guard let capturer = videoCapturer, let current = currentCameraDevice else { return }

        let devices = RTCCameraVideoCapturer.captureDevices()
        guard
            let currentIndex = devices.firstIndex(of: current),
            let next = devices.dropFirst(currentIndex + 1).first ?? devices.first,
            next != current
        else { return }

        guard let format = Self.bestFormat(for: next) else { return }
        currentCameraDevice = next
        capturer.startCapture(with: next, format: format, fps: Self.cameraFPS) { [weak self] error in
            if error != nil {
                print("[rtc] camera switch failed")
            }
        }
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        // 先记偏好：路由看守下一次检查就会按新值判断，
        // 不会把用户刚切好的听筒又顶回扬声器。
        speakerOn = enabled
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            if enabled {
                try session.setCategory(.playAndRecord, with: [.allowBluetooth, .defaultToSpeaker])
                try session.setMode(.voiceChat)
                try session.overrideOutputAudioPort(.speaker)
            } else {
                // 听筒模式：去掉 defaultToSpeaker 让系统按接近传感器路由。
                try session.setCategory(.playAndRecord, with: [.allowBluetooth])
                try session.setMode(.voiceChat)
                try session.overrideOutputAudioPort(.none)
            }
            try session.setActive(true)
        } catch {
            print("[rtc] speaker toggle failed: \(error.localizedDescription)")
        }
    }

    func localPreviewView() -> UIView? {
        guard let capturer = videoCapturer else { return nil }
        if let existing = previewView {
            return existing
        }
        let view = RTCCameraPreviewView(frame: .zero)
        view.captureSession = capturer.captureSession
        // 注意：M140 的 RTCCameraPreviewView 没有 videoContentMode 属性，
        // 预览比例由外层容器决定；这里只把底色压黑，保证比例不符时露出的底是黑的。
        view.backgroundColor = .black
        view.clipsToBounds = true
        previewView = view
        return view
    }

    // MARK: - 屏幕共享

    func startScreenShare() {
        // 真正开始共享由 ScreenShareBridge 判定（Broadcast 扩展状态）。
        // 这里只做：启动帧推送 + 广播 screen:state。
        // 调用时机由 MeetingViewModel 在 bridge 确认"正在共享"后触发。
        guard isJoined else { return }
        signaling?.sendMediaState(audio: nil, video: nil, screen: true)
    }

    func stopScreenShare() {
        guard isJoined else { return }
        signaling?.sendMediaState(audio: nil, video: nil, screen: false)
    }

    /// Broadcast 扩展确认在共享后调用：把共享帧推上所有 peer 的 video sender。
    func beginScreenFramePush() {
        guard let source = localScreenSource, let track = localScreenTrack else { return }
        guard screenPusher == nil else { return }

        isScreenSharing = true

        let profile = Self.screenEncodingProfile
        // 帧新鲜度下界：早于本次会话请求时刻的 JPEG 属于上一场，不推。
        let floor = ScreenShareStore.sessionFloor ?? Date().addingTimeInterval(-2)
        let pusher = ScreenFramePusher(source: source, notBefore: floor)
        screenPusher = pusher
        /* 格式切换必须和 tick() 的解码走同一个串行队列：
           RTCVideoSource.adaptOutputFormat 内部会重建 video adapter，
           主线程和 decodeQueue 同时调，偶发崩在 AdaptedVideoTrackSource::OnFrame。
           而且这一步必须赶在 start() 之前，否则前几帧会按旧画布推。 */
        pusher.applyOutputFormat(width: profile.width, height: profile.height, fps: profile.fps)

        // 用共享轨替换每条连接的 video sender（Web 端同款 replaceTrack）。
        for peer in remotePeers.values {
            peer.session.replaceVideoTrack(with: track)
        }
        applyScreenEncodingBudget()

        pusher.start()
        /* ReplayKit 真正起播会晚于这里 200~800ms，并重配一次音频会话。
           先强制抢一次，再由 routeGuard 每 2 秒兜底——
           只靠这一次同步调用，经常正好打在 ReplayKit 改配置之前。 */
        reactivateAudioSession(force: true)
        startRouteGuard()
        scheduleVideoUplinkWatchdog()
        syncTeardownBox()
    }

    /// iOS 27 起：帧由 ScreenCaptureKit 直接推进 `localScreenSource`，
    /// 这里只负责把共享轨挂到每条连接上。
    ///
    /// 与 `beginScreenFramePush` 的唯一区别是**不启动 ScreenFramePusher**：
    /// 那个是轮询 App Group 里 JPEG 的，SCK 路径下容器里什么都没有。
    func beginNativeScreenPush() {
        guard let track = localScreenTrack, localScreenSource != nil else { return }
        guard !isScreenSharing else { return }

        isScreenSharing = true

        /* 这里刻意不再调 adaptOutputFormat：
           它在 M140 内部会重建 video adapter，与 SCK 的帧回调并发会崩在
           AdaptedVideoTrackSource::OnFrame。输出画布在 setupLocalMedia
           创建 source 时已经设成 screenEncodingProfile，够用。
           内容比例由 SCStreamConfiguration 的 width/height 控制，
           竖屏内容会被 WebRTC 按比例居中，不会压扁。 */

        // 用共享轨替换每条连接的 video sender（Web 端同款 replaceTrack）。
        for peer in remotePeers.values {
            peer.session.replaceVideoTrack(with: track)
        }
        applyScreenEncodingBudget()

        /* 系统共享同样会切一次音频路由（ReplayKit / SCK 都会把
           AVAudioSession 的 mode 拨到录制侧）。不抢回来，
           用户会遇到"开始共享后听不见人说话"。 */
        reactivateAudioSession(force: true)
        startRouteGuard()
        scheduleVideoUplinkWatchdog()
        syncTeardownBox()
    }

    /// 共享起播后核对"视频包到底发出去了没有"。
    ///
    /// 真机反馈：共享诊断显示"已推 RTC 358 帧"，浏览器却一直停在
    /// "正在接收共享画面…"。帧推给了 video source，但 sender 所在
    /// transceiver 可能还是 recvonly，编码器一个包都不发。
    ///
    /// 1.5.4 起看门狗做三件事：
    ///   1. 读 packetsSent **和 framesEncoded**：前者证明包出了网卡，
    ///      后者证明编码器真的在消费共享帧。两个都为 0 才是换轨问题。
    ///   2. 把结果写进 ScreenShareRuntime，诊断面板直接展示。
    ///   3. 0 包时最多补救两轮（4 秒、+5 秒），第二轮仍无效就停手，
    ///      避免每 5 秒重复协商把连接拖垮。
    private func scheduleVideoUplinkWatchdog(attempt: Int = 0) {
        videoUplinkWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isScreenSharing else { return }
                guard !self.remotePeers.isEmpty else { return }

                let totals = VideoUplinkTotals()
                let group = DispatchGroup()

                for peer in self.remotePeers.values {
                    if !peer.session.isVideoTrackAttached {
                        totals.markDetached()
                    }
                    group.enter()
                    peer.session.peerConnection.statistics { report in
                        var peerPackets = 0
                        var peerEncoded = 0
                        for (_, stat) in report.statistics where stat.type == "outbound-rtp" {
                            guard (stat.values["kind"] as? String) == "video" else { continue }
                            peerPackets += (stat.values["packetsSent"] as? NSNumber)?.intValue ?? 0
                            peerEncoded += (stat.values["framesEncoded"] as? NSNumber)?.intValue ?? 0
                        }
                        totals.merge(packets: peerPackets, encoded: peerEncoded)
                        group.leave()
                    }
                }

                group.notify(queue: .main) {
                    guard self.isScreenSharing else { return }
                    let snapshot = totals.snapshot()
                    ScreenShareRuntime.noteVideoStats(
                        packetsSent: snapshot.packets,
                        framesEncoded: snapshot.encoded,
                        screenAttached: snapshot.attached
                    )

                    guard snapshot.packets == 0, attempt < 2 else { return }
                    for peer in self.remotePeers.values {
                        guard let track = self.localScreenTrack else { return }
                        peer.session.forceReattachVideo(track)
                    }
                    // 第二轮间隔拉长到 5 秒：给 ICE 与编码器足够的重启时间。
                    self.scheduleVideoUplinkWatchdog(attempt: attempt + 1)
                }
            }
        }
        videoUplinkWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 4 : 5), execute: item)
    }

    private func stopVideoUplinkWatchdog() {
        videoUplinkWatchdog?.cancel()
        videoUplinkWatchdog = nil
    }

    /// 按当前人数重新分配共享上行码率。
    ///
    /// Mesh 下每条连接都是独立编码：不按人数分，3 个人共享 1080p
    /// 就是 3×8Mbps 上行，家庭宽带和 4G 都扛不住。
    private func applyScreenEncodingBudget() {
        guard isScreenSharing, !remotePeers.isEmpty else { return }
        let profile = Self.screenEncodingProfile
        let perPeer = UplinkBudget.shared.perPeer(
            preferred: profile.bitrate,
            peers: remotePeers.count
        )
        for peer in remotePeers.values {
            peer.session.setVideoEncoding(
                maxBitrateBps: perPeer,
                maxFramerate: Int(profile.fps),
                // 低于 1.5Mbps 还硬保 1080p，编码器只能狂丢帧或加大 QP；
                // 让 WebRTC 降到 720p，滚动文字反而更顺。
                keepResolution: perPeer >= 1_500_000
            )
        }
    }

    /// 共享结束/中断后把摄像头档位恢复回来（同样按人数分摊）。
    private func applyCameraEncodingBudget() {
        guard !remotePeers.isEmpty else { return }
        let perPeer = UplinkBudget.shared.perPeer(preferred: 2_500_000, peers: remotePeers.count)
        for peer in remotePeers.values {
            peer.session.setVideoEncoding(maxBitrateBps: perPeer, maxFramerate: 30)
        }
    }

    /// Broadcast 扩展确认停止共享后调用：恢复摄像头轨。
    func endScreenFramePush() {
        stopVideoUplinkWatchdog()
        stopRouteGuard()
        screenPusher?.stop()
        screenPusher = nil
        isScreenSharing = false
        let back = localVideoTrack
        for peer in remotePeers.values {
            peer.session.replaceVideoTrack(with: back)
        }
        applyCameraEncodingBudget()
        /* 广播结束同样会切一次路由：不抢回来，用户会遇到
           "共享停了以后反而听不见人说话"。 */
        reactivateAudioSession(force: true)
        syncTeardownBox()
    }

    /// 服务端拒绝共享（screen:busy / screen:denied）：停本地推流并通知上层。
    private func abortScreenShare(reason: String) {
        guard isScreenSharing else {
            delegate?.rtcDidScreenShareRejected(reason: reason)
            return
        }
        stopVideoUplinkWatchdog()
        stopRouteGuard()
        isScreenSharing = false
        screenPusher?.stop()
        screenPusher = nil
        let back = localVideoTrack
        for peer in remotePeers.values {
            peer.session.replaceVideoTrack(with: back)
        }
        applyCameraEncodingBudget()
        signaling?.sendMediaState(audio: nil, video: nil, screen: false)
        delegate?.rtcDidScreenShareRejected(reason: reason)
        syncTeardownBox()
    }

    // MARK: - 消息与举手

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isJoined else { return }
        signaling?.sendChat(content: trimmed) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let id):
                // 自己发的消息：服务端会广播 chat:new，本地不用重复上屏。
                self.consumedMessageIDs.insert(String(id))
            case .failure(let failure):
                self.delegate?.rtcDidReceiveMessage(
                    ChatMessage(
                        id: "send-fail-\(UUID().uuidString)",
                        senderID: self.selfPeerID,
                        senderName: "我",
                        text: failure.message,
                        kind: .system
                    )
                )
            }
        }
    }

    func setHandRaised(_ raised: Bool) {
        guard isJoined else { return }
        localHandRaised = raised
        signaling?.sendHand(raised: raised)
        publishParticipants()
    }

    // MARK: - 主持人操作

    func mutePeer(_ userID: String) {
        signaling?.mutePeer(userID)
    }

    func muteAllPeers() {
        signaling?.muteAll()
    }

    func removePeer(_ userID: String) {
        signaling?.kickPeer(userID)
    }

    func transferHost(to userID: String) {
        signaling?.transferHost(to: userID)
    }

    func setRoomLocked(_ locked: Bool) {
        signaling?.setLocked(locked)
    }

    func endMeeting() {
        signaling?.endMeeting()
    }

    // MARK: - 内部：连接

    private static func fetchIceServersAsync() async throws -> [IceServerConfig] {
        try await withCheckedThrowingContinuation { continuation in
            APIClient.fetchIceServers { result in
                switch result {
                case .success(let servers):
                    continuation.resume(returning: servers)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 服务端下发的 ICE 配置 → WebRTC 的 RTCIceServer。
    /// 有 username/credential 才是 TURN，只给 urls 的是 STUN。
    private static func makeIceServer(_ config: IceServerConfig) -> RTCIceServer {
        if let username = config.username, let credential = config.credential {
            return RTCIceServer(urlStrings: config.urls, username: username, credential: credential)
        }
        return RTCIceServer(urlStrings: config.urls)
    }

    private func connectSignaling(_ signaling: TianqiongSignaling, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var settled = false
            let settle: (Result<Void, Error>) -> Void = { result in
                guard !settled else { return }
                settled = true
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            // TianqiongSignaling 整体隔离在 @MainActor：连接动作与 isConnected 的读取
            // 都必须回到主线程，否则会报 "main actor-isolated property can not be
            // referenced from a nonisolated context"。
            Task { @MainActor in
                signaling.connect()
                let deadline = Date().addingTimeInterval(timeout)
                while !signaling.isConnected {
                    if Date() > deadline {
                        settle(.failure(RTCJoinError(message: "连接超时", code: "SOCKET_TIMEOUT")))
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                settle(.success(()))
            }
        }
    }

    private func joinRoom(
        _ signaling: TianqiongSignaling,
        options: JoinOptions
    ) async throws -> JoinSnapshot {
        /* 入会声明必须反映"真实可用的媒体"，而不是入会页上的开关。
           麦克风被系统拒绝时 track.isEnabled 已经是 false，如果这里仍按
           options.audioOn 上报 true，服务端和所有对端都会以为这个人在说话：
           成员列表亮着麦克风、实际一个采样都没有——这是用户反馈"开了麦没声音"
           里最容易被误判成网络问题的一类。摄像头同理。 */
        let audioNow = localAudioTrack?.isEnabled ?? options.audioOn
        let videoNow = localVideoTrack?.isEnabled ?? options.videoOn

        return try await withCheckedThrowingContinuation { continuation in
            signaling.join(
                no: options.no,
                name: options.name,
                password: options.password,
                audio: audioNow,
                video: videoNow,
                /* 冷启动时广播扩展可能已经在跑：把共享状态一并带进首包，
                   否则服务端不知道本端在共享，对端永远等不到 screen:state。 */
                screen: isScreenSharing,
                timeout: 12
            ) { result in
                switch result {
                case .success(let snapshot):
                    continuation.resume(returning: snapshot)
                case .failure(let failure):
                    continuation.resume(throwing: failure)
                }
            }
        }
    }

    // MARK: - 内部：本地媒体

    private func setupLocalMedia(audioOn: Bool, videoOn: Bool, cameraOn: Bool) async throws {
        let factory = Self.sharedFactory
        self.factory = factory

        // 麦克风权限必须在**入会时**要，不能等到用户点开麦。
        //
        // 之前全项目没有一处请求过录音权限：WebRTC 第一次激活音频会话时系统才弹窗，
        // 而那一刻通常发生在会议进行中——用户点"开麦"，对方看到的是这个人静音了几秒，
        // 自己看到的是一句"需要麦克风权限"。授权这件事应该发生在门外，不是会议里。
        //
        // 被拒绝不阻断入会：可以只听不说，会中再点开麦时系统会引导去设置。
        let micGranted = await Self.requestMicPermission()

        // 麦克风（48kHz 由 WebRTC 内部音频单元保证）。
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio-\(UUID().uuidString)")
        // 权限被拒就不能让轨道保持 enabled：那会让界面显示"麦克风已开"、
        // 对方却完全听不到，是比"开麦失败"更难自查的一种状态。
        audioTrack.isEnabled = audioOn && micGranted
        localAudioTrack = audioTrack
        if audioOn && !micGranted {
            delegate?.rtcDidUpdateLocalMic(false)
        }

        // 摄像头（前置，720p@30）。
        //
        // 视频源与视频轨**始终创建**，即使本次入会是关着摄像头的。
        // 原因：PeerConnection 里有没有 video sender，取决于入会时有没有 addTrack。
        // 入会时没建轨，会中再点"开摄像头"就只能走 addTrack + 重新协商，
        // 而自定义信令里没有实现这条路径——用户看到的就是"点了没反应"。
        //
        // 创建 source/track 不触碰摄像头，也不会亮指示灯；只有 startCapture 才会。
        let videoSource = factory.videoSource()
        localVideoSource = videoSource
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        videoCapturer = capturer

        let track = factory.videoTrack(with: videoSource, trackId: "video-\(UUID().uuidString)")
        localVideoTrack = track

        if videoOn || cameraOn {
            let granted = await Self.requestCameraPermission()

            // 权限被拒 / 无可用设备：降级为纯音频入会，不再 throw。
            // 之前这里直接抛错，用户只是想开个会，却被一个摄像头授权挡在门外，
            // 连"关掉摄像头再进"的提示都没有。
            if granted,
               let device = Self.preferredCameraDevice(),
               let format = Self.bestFormat(for: device) {
                currentCameraDevice = device
                capturer.startCapture(with: device, format: format, fps: Self.cameraFPS) { error in
                    if let error = error {
                        print("[rtc] camera start failed: \(error.localizedDescription)")
                    }
                }
                isCameraCapturing = true
                track.isEnabled = videoOn
            } else {
                track.isEnabled = false
                delegate?.rtcDidUpdateLocalCamera(false)
            }
        } else {
            track.isEnabled = false
        }

        // 共享源（帧由 SharedFrameStore 推送）。
        let screenSource = factory.videoSource()
        let screenProfile = Self.screenEncodingProfile
        screenSource.adaptOutputFormat(
            toWidth: screenProfile.width,
            height: screenProfile.height,
            fps: screenProfile.fps
        )
        let screenTrack = factory.videoTrack(with: screenSource, trackId: "screen-\(UUID().uuidString)")
        screenTrack.isEnabled = true
        localScreenSource = screenSource
        localScreenTrack = screenTrack

        /* 激活音频会话。走统一的 reactivateAudioSession：
           原来这里只 setCategory + setActive，漏了 setMode(.voiceChat)。
           共享广播扩展会把系统 mode 留在 videoRecording，入会时如果沿用，
           采集增益低到对方几乎听不见，而本地一切显示正常——
           正是"麦克风开了、对方就是没声"的另一条成因。 */
        reactivateAudioSession()
    }

    static func requestCameraPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                continuation.resume(returning: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            default:
                continuation.resume(returning: false)
            }
        }
    }

    private static let cameraFPS = 30

    /// 请求麦克风（录音）权限。
    ///
    /// iOS 17 起 `AVAudioSession.requestRecordPermission` 被废弃，
    /// 新入口是 `AVAudioApplication.requestRecordPermission`；
    /// 部署目标是 15.0，所以两条路都要留。
    static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// 当前录音授权状态（只读，不触发弹窗）。
    nonisolated static var micPermissionGranted: Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    // MARK: - 本地音频电平

    /// 每 180ms 取一次本地麦克风电平。
    ///
    /// 为什么走 getStats 而不是 AVAudioEngine：麦克风被 WebRTC 的
    /// voice-processing audio unit 独占着，再挂一个 AVAudioEngine 的 tap
    /// 会和它抢设备（表现为对方听到断续）。getStats 是只读的，
    /// `media-source` 那组统计里带 `audioLevel`（0...1）。
    ///
    /// 180ms 是"看得出说话"和"不浪费 CPU"之间的折中：一次 getStats
    /// 的代价约 1~2ms，按 20 次/秒算还不到 4% 的单核。
    private func startAudioLevelPolling() {
        audioLevelTimer?.invalidate()

        let timer = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.pollLocalAudioLevel()
        }
        // .common：面板/抽屉滚动时 runloop 会切到 tracking 模式，
        // 用 .default 注册的 timer 在那段时间会停，脉冲就会"卡住"。
        RunLoop.main.add(timer, forMode: .common)
        audioLevelTimer = timer
    }

    private func stopAudioLevelPolling() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
        delegate?.rtcDidUpdateLocalAudioLevel(0)
    }

    private func pollLocalAudioLevel() {
        let peers = Array(remotePeers.values)

        /* 单人：没有任何连接，也就没有任何 RTP 统计可读。
           这里既不起 AVAudioRecorder，也不挂 loopback 探针——
           两者都会和 WebRTC 抢音频设备，是 1.4.6 ~ 1.4.9 全部
           "有人进会后麦克风就哑了"的根源。界面如实显示"已就绪"。 */
        guard !peers.isEmpty else {
            latestLocalLevel = 0
            latestRemoteLevel.removeAll()
            lastLocalEnergy = nil
            lastRemoteEnergy.removeAll()
            delegate?.rtcDidUpdateLocalAudioLevel(0)
            delegate?.rtcDidChangeActiveSpeaker(nil)
            return
        }

        /* 多人：一条 report 里同时有本地（media-source）和远端（inbound-rtp）
           两种电平。远端逐条比大小，最大的那个就是当前发言人——
           服务端并不下发音量，iOS 端的"谁在说话"只能从这里来。 */
        var loudestID: String?
        var loudestLevel: Float = 0
        var localPeak: Float = 0
        var outboundTotal = 0
        var remoteEnergy: [String: AudioEnergySample] = [:]
        var remoteLevels: [String: Float] = [:]
        var localSample: AudioEnergySample?
        let lock = NSLock()
        let group = DispatchGroup()

        for (index, peer) in peers.enumerated() {
            /* 上一次的累计量必须在**发起统计之前**快照：
               statistics 的回调在 WebRTC 的串行队列上，回调里再读主线程
               字典就是数据竞争。 */
            let previousRemote = lastRemoteEnergy[peer.peerID]
            let previousLocal = index == 0 ? lastLocalEnergy : nil

            group.enter()
            peer.session.peerConnection.statistics { report in
                var remote: Float = 0
                var remoteSample: AudioEnergySample?
                var local: Float = 0
                var localSampled: AudioEnergySample?
                var sent = 0

                for (_, stat) in report.statistics {
                    if stat.type == "inbound-rtp",
                       (stat.values["kind"] as? String) == "audio" {
                        let (level, sample) = Self.audioLevel(stat: stat, previous: previousRemote)
                        if level > remote { remote = level }
                        if let sample { remoteSample = sample }
                    }
                    if stat.type == "outbound-rtp",
                       (stat.values["kind"] as? String) == "audio" {
                        sent = (stat.values["packetsSent"] as? NSNumber)?.intValue ?? 0
                    }
                    if index == 0, stat.type == "media-source" {
                        let (level, sample) = Self.audioLevel(stat: stat, previous: previousLocal)
                        if level > local { local = level }
                        if let sample { localSampled = sample }
                    }
                }

                lock.lock()
                if index == 0 {
                    localPeak = local
                    localSample = localSampled
                }
                outboundTotal += sent
                if let remoteSample { remoteEnergy[peer.peerID] = remoteSample }
                if remote > 0 { remoteLevels[peer.peerID] = remote }
                if remote > loudestLevel {
                    loudestLevel = remote
                    loudestID = peer.peerID
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if let localSample { self.lastLocalEnergy = localSample }
            for (id, sample) in remoteEnergy { self.lastRemoteEnergy[id] = sample }
            self.latestLocalLevel = localPeak
            self.latestRemoteLevel = remoteLevels
            self.delegate?.rtcDidUpdateLocalAudioLevel(localPeak)
            // 0.02 是底噪水位：低于它的都是空调/键盘，
            // 不设门限会出现"没人说话但一直有人亮着"。
            self.delegate?.rtcDidChangeActiveSpeaker(loudestLevel > 0.02 ? loudestID : nil)
            self.evaluateOutboundAudioHealth(total: outboundTotal)
        }
    }

    /// 从一条统计里还原电平。
    ///
    /// 优先用累计能量做差分：`audioLevel` 依赖 RTP 头扩展
    /// （urn:ietf:params:rtp-hdrext:ssrc-audio-level），对方没协商该扩展时
    /// 这个字段恒为 0——线上"说话时脉冲不动、诊断永远 0.00"就是这么来的。
    /// `totalAudioEnergy` / `totalSamplesDuration` 是端点自己累计的，
    /// 不依赖任何协商，差分后开方就是这段时间的真实 RMS 幅度。
    private static func audioLevel(
        stat: RTCStatistics,
        previous: AudioEnergySample?
    ) -> (Float, AudioEnergySample?) {
        let direct = (stat.values["audioLevel"] as? NSNumber)?.floatValue ?? 0

        guard let energy = (stat.values["totalAudioEnergy"] as? NSNumber)?.doubleValue,
              let duration = (stat.values["totalSamplesDuration"] as? NSNumber)?.doubleValue,
              duration > 0 else {
            // 老版本 SDK 或该统计不支持能量字段：至少别把已有的 audioLevel 丢掉。
            return (direct, nil)
        }

        let sample = AudioEnergySample(energy: energy, duration: duration)
        guard let previous else { return (direct, sample) }

        let deltaEnergy = energy - previous.energy
        let deltaDuration = duration - previous.duration
        // 两次统计间隔太短时差值是噪声，沿用 direct，等下一轮再算。
        guard deltaEnergy > 0, deltaDuration > 0.002 else { return (direct, sample) }

        let rms = sqrt(deltaEnergy / deltaDuration)
        // 正常说话的 RMS 约 0.02~0.15；×4 让普通音量就能点亮脉冲，
        // 又不至于空调声一直满格。
        let level = Float(min(1, rms * 4))
        return (max(direct, level), sample)
    }

    /// 清掉某个 peer 的能量基线：人走了还留着上一场的累计量，
    /// 下次同 ID 再进来算出的差值会是一个巨大的负数，电平直接归零。
    private func clearAudioLevelState(for peerID: String) {
        lastRemoteEnergy.removeValue(forKey: peerID)
        latestRemoteLevel.removeValue(forKey: peerID)
    }

    private func clearAllAudioLevelState() {
        lastRemoteEnergy.removeAll()
        latestRemoteLevel.removeAll()
        lastLocalEnergy = nil
        latestLocalLevel = 0
    }

    /// 上行音频健康度。每 5 秒对一次总包数：
    /// 有人、麦克风开着、总包数却不动 → AudioDeviceModule 已停采。
    ///
    /// 这不是"重挂 sender"能修的问题：sender 挂着、轨道 live、SDP 也是
    /// sendrecv，但音频设备不出帧，所以一个包都发不出去。必须把整条
    /// 音频设备链路重启（停会话 → 重配 → 重建轨 → 全部重挂）。
    private func evaluateOutboundAudioHealth(total: Int) {
        guard localAudioTrack?.isEnabled == true, !remotePeers.isEmpty else {
            resetOutboundAudioTracking()
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastOutboundAudioCheckAt) >= 5 else { return }
        lastOutboundAudioCheckAt = now

        defer { lastOutboundAudioTotal = total }

        // 第一次只建立基线：刚连上时包数本来就是 0。
        guard lastOutboundAudioTotal >= 0 else { return }

        if total > lastOutboundAudioTotal {
            stagnantOutboundChecks = 0
            return
        }

        stagnantOutboundChecks += 1
        guard stagnantOutboundChecks >= 2 else { return }
        stagnantOutboundChecks = 0
        restartAudioPipeline(reason: "上行音频 10 秒无增长（累计 \(total) 包）")
    }

    private func resetOutboundAudioTracking() {
        lastOutboundAudioTotal = -1
        lastOutboundAudioCheckAt = .distantPast
        stagnantOutboundChecks = 0
    }

    /// 把音频设备整条重启一次。
    ///
    /// 顺序必须是"先停会话、再重建轨、最后挂回去"：
    /// 只 replaceTrack 不会让已经停采的 ADM 重新出帧。
    private func restartAudioPipeline(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastAudioPipelineRestartAt) > 8 else { return }
        lastAudioPipelineRestartAt = now
        print("[rtc] audio pipeline restart: \(reason)")

        resetOutboundAudioTracking()

        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        session.isAudioEnabled = false
        try? session.setActive(false)
        try? session.setCategory(.playAndRecord, with: [.allowBluetooth, .defaultToSpeaker])
        try? session.setMode(.voiceChat)
        try? session.setActive(true)
        session.isAudioEnabled = true
        session.unlockForConfiguration()

        guard let track = rebuildAudioTrack() else { return }
        track.isEnabled = true
        for peer in remotePeers.values {
            peer.session.forceReattachAudio(track)
        }
        publishLocalMediaState()
        publishParticipants()
    }

    // MARK: - 诊断

    /// 一份能一眼看出"卡在哪一段"的音视频诊断。
    ///
    /// 排查顺序：连接状态 → 收发 RTP 计数 → 音频会话/路由。
    /// 连接 failed = 打洞没过；connected 但 packetsReceived 为 0 = 对端没发；
    /// 收包在涨却没声音 = 播放或路由问题。
    func collectDiagnostics(completion: @escaping (String) -> Void) {
        var lines: [String] = []
        lines.append("本端 \(selfPeerID.isEmpty ? "未入会" : String(selfPeerID.prefix(8))) · 在线 \(remotePeers.count + 1) 人")

        let trackState = localAudioTrack.map { track -> String in
            let ready = track.readyState == .live ? "live" : "ended"
            return "\(track.isEnabled ? "开启" : "静音")/\(ready)"
        } ?? "无轨道"
        lines.append("本地麦克风 \(trackState) · 权限 \(Self.micPermissionGranted ? "已授权" : "未授权")")

        let session = RTCAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        lines.append("音频会话 active=\(session.isActive) enabled=\(session.isAudioEnabled)")
        lines.append("模式 \(session.mode) · 输出 \(outputs.isEmpty ? "无" : outputs)")
        lines.append("")

        guard !remotePeers.isEmpty else {
            lines.append("没有远端连接：单人会议不产生 RTP 统计。")
            completion(lines.joined(separator: "\n"))
            return
        }

        let group = DispatchGroup()
        var perPeer: [String] = []
        let lock = NSLock()
        /* 电平直接取轮询缓存：同一份 statistics 在这里再算一遍差值，
           既要重复两套逻辑，也会因为采样间隔不同得出不同的数。 */
        let localLevelSnapshot = latestLocalLevel
        let remoteLevelSnapshot = latestRemoteLevel

        for (id, peer) in remotePeers {
            group.enter()
            let name = peer.name.isEmpty ? String(id.prefix(6)) : peer.name
            let conn = Self.connectionText(peer.session.peerConnection.connectionState)
            let ice = Self.iceText(peer.session.peerConnection.iceConnectionState)
            let localDir = Self.mediaDirection(in: peer.session.peerConnection.localDescription?.sdp, kind: "audio")
            let remoteDir = Self.mediaDirection(in: peer.session.peerConnection.remoteDescription?.sdp, kind: "audio")
            let localVideoDir = Self.mediaDirection(in: peer.session.peerConnection.localDescription?.sdp, kind: "video")
            let senderCount = peer.session.audioSenderCount

            peer.session.peerConnection.statistics { report in
                var inPackets = 0, outPackets = 0, inKB = 0, outKB = 0
                var outVideo = 0
                var level: Double = 0
                var outLevel: Double = 0
                var frameKB = 0
                for (_, st) in report.statistics {
                    if st.type == "inbound-rtp", (st.values["kind"] as? String) == "audio" {
                        inPackets = (st.values["packetsReceived"] as? NSNumber)?.intValue ?? 0
                        inKB = ((st.values["bytesReceived"] as? NSNumber)?.intValue ?? 0) / 1024
                        level = Double(remoteLevelSnapshot[id] ?? 0)
                    }
                    if st.type == "outbound-rtp", (st.values["kind"] as? String) == "audio" {
                        outPackets = (st.values["packetsSent"] as? NSNumber)?.intValue ?? 0
                        outKB = ((st.values["bytesSent"] as? NSNumber)?.intValue ?? 0) / 1024
                        outLevel = Double(localLevelSnapshot)
                    }
                    if st.type == "outbound-rtp", (st.values["kind"] as? String) == "video" {
                        outVideo = (st.values["packetsSent"] as? NSNumber)?.intValue ?? 0
                    }
                    if st.type == "inbound-rtp", (st.values["kind"] as? String) == "video" {
                        frameKB = ((st.values["bytesReceived"] as? NSNumber)?.intValue ?? 0) / 1024
                    }
                }
                let line = """
                \(name)：\(conn) / ICE \(ice)
                  SDP 音频 本端 \(localDir) · 远端 \(remoteDir)
                  SDP 视频 本端 \(localVideoDir) · 音频发送器 \(senderCount)
                  收音频 \(inPackets) 包 · \(inKB)KB · 电平 \(String(format: "%.2f", level))
                  发音频 \(outPackets) 包 · \(outKB)KB · 电平 \(String(format: "%.2f", outLevel)) · 发视频 \(outVideo) 包 · 收视频 \(frameKB)KB
                """
                lock.lock(); perPeer.append(line); lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            lines.append(contentsOf: perPeer.sorted())
            completion(lines.joined(separator: "\n"))
        }
    }

    /// 诊断里的人话状态。`String(describing:)` 会输出
    /// `RTCPeerConnectionState(rawValue: 2)`，用户在电话里根本没法复述。
    private static func connectionText(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new: return "新建"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .disconnected: return "已断开"
        case .failed: return "失败"
        case .closed: return "已关闭"
        @unknown default: return "未知"
        }
    }

    private static func iceText(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: return "新建"
        case .checking: return "检测中"
        case .connected: return "已连接"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .disconnected: return "已断开"
        case .closed: return "已关闭"
        case .count: return "计数"
        @unknown default: return "未知"
        }
    }

    /// 从 SDP 里读音频 m-line 的方向。
    ///
    /// 这是判断"本端到底有没有在发"的唯一静态证据：
    /// 本端方向是 recvonly，就说明 answer 生成时本地没有 audio sender，
    /// 之后不管轨道多正常，都不会有一个包出去。
    ///
    /// RFC 4566 规定方向属性缺省即 sendrecv，libwebrtc 在部分路径下
    /// 会省略这一行——旧实现把它显示成"未声明"，看起来像没协商成功，
    /// 实际是正常的。这里按协议把它还原成 sendrecv(默认)。
    private static func mediaDirection(in sdp: String?, kind: String) -> String {
        guard let sdp = sdp, !sdp.isEmpty else { return "无描述" }
        var inAudio = false
        var sawAudioLine = false
        /* 用 isNewline 而不是逐个比较 "\r" / "\n"：
           Swift 的 String 按 Character 遍历，"遇到换行时 CRLF 会被合并成
           一个 Character——它既不等于 "\r" 也不等于 "\n"。旧写法等于
           完全没有切分，整段 SDP 变成"一行"，hasPrefix("m=audio") 永远
           不成立，诊断里就永远是"无音频行"。 */
        for rawLine in sdp.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            if line.hasPrefix("m=\(kind)") {
                inAudio = true
                sawAudioLine = true
                continue
            }
            if line.hasPrefix("m=") {
                inAudio = false
                continue
            }
            guard inAudio else { continue }
            if line.hasPrefix("a=sendrecv") { return "sendrecv" }
            if line.hasPrefix("a=sendonly") { return "sendonly" }
            if line.hasPrefix("a=recvonly") { return "recvonly" }
            if line.hasPrefix("a=inactive") { return "inactive" }
        }
        if sawAudioLine { return "sendrecv(默认)" }
        return "无\(kind)行"
    }

    /// 屏幕共享的编码档位。
    ///
    /// 设置页的两个选项必须落到真实参数上，否则"清晰/流畅"只是一个会弹 Toast 的开关：
    ///   · 清晰：1080p / 20fps / 4Mbps，与 Web 端 screen 档对齐；
    ///   · 流畅：720p / 15fps / 1.6Mbps，弱网下优先保帧率。
    ///
    /// fps 用 `Int32`：`adaptOutputFormat` 的入参就是 `Int32`，
    /// 这里跟着它的类型走，调用点不必到处写 `Int32(...)`。
    static var screenEncodingProfile: (width: Int32, height: Int32, fps: Int32, bitrate: Int) {
        switch AppSettings.shareQualitySnapshot {
        case .sharp:
            // 4Mbps 对 1080p 的文档画面是不够的：滚动/翻页时整屏都在变，
            // 编码器只能保帧率丢细节，落到远端就是"字糊成一片"。
            // 8Mbps 配 maintainResolution，文字边缘才立得住；网络跟不上时
            // WebRTC 的带宽估计会自动降码率，不会把连接压死。
            return (1920, 1080, 24, 8_000_000)
        case .balanced:
            return (1280, 720, 18, 3_000_000)
        }
    }

    /// 前置优先；没有前置（少见的 iPad 外接场景）就退回第一个可用设备。
    /// 入会建流与会中开摄像头共用这一处选择逻辑，避免两边挑到不同的摄像头。
    static func preferredCameraDevice() -> AVCaptureDevice? {
        let devices = RTCCameraVideoCapturer.captureDevices()
        return devices.first(where: { $0.position == .front }) ?? devices.first
    }

    /// 选 720p 档位里最合适的格式：优先 1280x720@30，否则最接近 720p 且不超采。
    /// 设备无任何可用格式时返回 nil。
    static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard !formats.isEmpty else { return nil }
        let preferred = formats.first { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == 1280 && dims.height == 720
        }
        if let preferred = preferred {
            return preferred
        }
        // 没有 720p：找分辨率不超过 1280 的最大格式。
        return formats
            .filter {
                let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return dims.width <= 1280 && dims.height <= 1280
            }
            .max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return (da.width * da.height) < (db.width * db.height)
            } ?? formats.first
    }

    // MARK: - 内部：快照应用

    /// 把服务端下发的品牌字段翻成 UI 可直接用的模型。
    /// 企业会议室才会带 enterpriseName，普通会议保持默认值（界面不显示标识）。
    private func publishBrand(from meeting: [String: Any]) {
        let brand = MeetingBrand(
            isEnterprise: (meeting["kind"] as? String) == "enterprise",
            enterpriseName: meeting["enterpriseName"] as? String ?? "",
            roomMode: meeting["roomMode"] as? String ?? "fixed"
        )
        delegate?.rtcDidUpdateMeetingBrand(brand)
    }

    private func applyJoinSnapshot(_ snapshot: JoinSnapshot) {
        selfPeerID = snapshot.selfPeerID
        selfUserID = snapshot.selfInfo["userId"] as? Int
        isSelfHost = snapshot.selfRole == "host"
        selfName = DisplayName.clean(snapshot.selfInfo["name"] as? String)
        selfAvatarColor = snapshot.selfInfo["avatarColor"] as? String ?? ""
        meetingInfo = snapshot.meeting
        publishBrand(from: snapshot.meeting)

        // 远端 peer：为每个建立 PeerSession。
        var newPeers: [String: RemotePeer] = [:]
        for raw in snapshot.peers {
            guard let peerID = raw["peerId"] as? String else { continue }
            guard let session = makePeerSession(peerID: peerID) else { continue }
            let peer = RemotePeer(
                peerID: peerID,
                name: DisplayName.clean(raw["name"] as? String),
                role: raw["role"] as? String ?? "attendee",
                audio: raw["audio"] as? Bool ?? false,
                video: raw["video"] as? Bool ?? false,
                screen: raw["screen"] as? Bool ?? false,
                hand: raw["hand"] as? Bool ?? false,
                userId: raw["userId"] as? Int,
                avatarColor: raw["avatarColor"] as? String ?? "",
                session: session
            )
            newPeers[peerID] = peer
            session.attachLocalTracks(audio: localAudioTrack, video: isScreenSharing ? localScreenTrack : localVideoTrack)
        }
        remotePeers = newPeers

        // 聊天历史（倒序恢复，天然去重）。
        for raw in snapshot.messages {
            consumeChatMessage(raw)
        }

        // 已恢复的共享者。
        if let screenPeerID = snapshot.screenPeerID {
            if let peer = remotePeers[screenPeerID] {
                peer.screen = true
                delegate?.rtcDidReceiveRemoteScreen(peer.session.makeRemoteVideoView(), for: screenPeerID)
            }
        }

        delegate?.rtcDidRoomLockChange(locked: snapshot.locked)
        publishParticipants()
        syncTeardownBox()
    }

    private func makePeerSession(peerID: String) -> PeerSession? {
        guard let factory = factory else {
            print("[rtc] factory 未初始化，跳过 peer \(peerID)")
            return nil
        }
        // polite 方 = peerId 小者（与 Web 端同一规则，保证两端对同一连接判断一致）。
        let polite = selfPeerID < peerID
        guard let session = PeerSession(
            factory: factory,
            peerID: peerID,
            iceServers: iceServers,
            polite: polite
        ) else {
            print("[rtc] PeerSession 创建失败，跳过 peer \(peerID)")
            return nil
        }
        session.delegate = self
        return session
    }

    // MARK: - 内部：远端同步（重连后）

    private func reconcileWithSnapshot(_ snapshot: JoinSnapshot) {
        // 重连后 socket.id 已变化：服务端下发的 selfPeerID 是新的。
        // polite 规则依赖两端 peerId 比较，本端 peerId 变了就必须全部重建
        // （与 Web 端重连 closeAllPeers 再重建的策略一致）。
        selfPeerID = snapshot.selfPeerID
        selfUserID = snapshot.selfInfo["userId"] as? Int
        isSelfHost = snapshot.selfRole == "host"
        let snapshotName = DisplayName.clean(snapshot.selfInfo["name"] as? String)
        if !snapshotName.isEmpty { selfName = snapshotName }
        selfAvatarColor = snapshot.selfInfo["avatarColor"] as? String ?? selfAvatarColor
        meetingInfo = snapshot.meeting
        publishBrand(from: snapshot.meeting)

        // 全部关闭重建。
        for (peerID, peer) in remotePeers {
            peer.session.close()
            delegate?.rtcDidLoseRemoteMedia(for: peerID)
        }
        remotePeers.removeAll()
        clearAllAudioLevelState()

        for raw in snapshot.peers {
            guard let peerID = raw["peerId"] as? String else { continue }
            guard let session = makePeerSession(peerID: peerID) else { continue }
            let peer = RemotePeer(
                peerID: peerID,
                name: DisplayName.clean(raw["name"] as? String),
                role: raw["role"] as? String ?? "attendee",
                audio: raw["audio"] as? Bool ?? false,
                video: raw["video"] as? Bool ?? false,
                screen: raw["screen"] as? Bool ?? false,
                hand: raw["hand"] as? Bool ?? false,
                userId: raw["userId"] as? Int,
                avatarColor: raw["avatarColor"] as? String ?? "",
                session: session
            )
            remotePeers[peerID] = peer
            session.attachLocalTracks(audio: localAudioTrack, video: isScreenSharing ? localScreenTrack : localVideoTrack)
        }

        // 断线期间错过的消息（consumeChatMessage 按 id 去重）。
        for raw in snapshot.messages {
            consumeChatMessage(raw)
        }

        // 共享恢复：远端共享者 / 本端共享中（断线后服务端清空了 screenPeerId，
        // 本端重新声明并重推屏幕轨）。
        pendingScreenPeerID = nil
        if let screenPeerID = snapshot.screenPeerID, let peer = remotePeers[screenPeerID] {
            peer.screen = true
            delegate?.rtcDidReceiveRemoteScreen(peer.session.makeRemoteVideoView(), for: screenPeerID)
        }
        if isScreenSharing {
            // 断线超过宽限期时服务端已经把 screenPeerId 清掉：重连后必须由本端重新声明，
            // 否则对端只看到"人回来了"，共享舞台永远不出现——这就是用户说的
            // "关掉再开就不行"里最典型的一种。
            signaling?.sendMediaState(audio: nil, video: nil, screen: true)
            // 上一轮收尾可能把推帧器停了：这里重新拉起来（begin 内部幂等）。
            if screenPusher == nil { beginScreenFramePush() }
            // 0.8 秒补一次：对端处理 peer:joined 有延迟，第一次 screen:state 到达时
            // 手里可能还没有这条 peer，绑不上 video。补发一次让它有机会重挂。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, self.isScreenSharing else { return }
                self.signaling?.sendMediaState(audio: nil, video: nil, screen: true)
            }
        }

        delegate?.rtcDidRoomLockChange(locked: snapshot.locked)
        publishParticipants()
        syncTeardownBox()
    }

    // MARK: - 内部：事件 → 快照

    private func publishParticipants() {
        guard isJoined else { return }
        let locals = buildLocalUser()
        let remotes = remotePeers.values.sorted { $0.peerID < $1.peerID }.map(mapRemoteUser)
        delegate?.rtcDidUpdateParticipants([locals] + remotes)
    }

    private func buildLocalUser() -> MeetingUser {
        // 不用 `options!`：同一表达式里的短路求值虽然安全，但读的人得先算一遍
        // 才敢确认它不会崩。取出来判空更直接。
        let joinedName = options?.name ?? ""
        return MeetingUser(
            id: selfPeerID,
            name: selfName.isEmpty ? (joinedName.isEmpty ? "访客" : joinedName) : selfName,
            role: isSelfHost ? .host : .participant,
            isMicOn: localAudioTrack?.isEnabled ?? true,
            isCameraOn: localVideoTrack?.isEnabled ?? false,
            isHandRaised: localHandRaised,
            isSpeaking: false,
            isLocal: true,
            avatarColorIndex: Self.avatarColorIndex(for: selfAvatarColor)
        )
    }

    private func mapRemoteUser(_ peer: RemotePeer) -> MeetingUser {
        MeetingUser(
            id: peer.peerID,
            name: peer.name,
            role: peer.role == "host" ? .host : .participant,
            isMicOn: peer.audio,
            isCameraOn: peer.video,
            isHandRaised: peer.hand,
            isSpeaking: false,
            isLocal: false,
            avatarColorIndex: Self.avatarColorIndex(for: peer.avatarColor)
        )
    }

    /// 服务端下发的头像色（'#3370ff' 等）→ 本地调色板索引，保证两端颜色一致。
    /// 与 server/util.js AVATAR_COLORS 顺序一致。
    private static let serverAvatarColors = [
        "#3370ff", "#7f3bf5", "#d4380d", "#08979c", "#c41d7f", "#2f9e44", "#d48806", "#1d39c4",
    ]

    private static func avatarColorIndex(for hex: String) -> Int {
        let normalized = hex.trimmingCharacters(in: .whitespaces).lowercased()
        guard let index = serverAvatarColors.firstIndex(of: normalized) else {
            return 0
        }
        return index
    }

    private func consumeChatMessage(_ raw: [String: Any]) {
        guard let idValue = raw["id"] else { return }
        let id = String(describing: idValue)
        guard !consumedMessageIDs.contains(id) else { return }
        consumedMessageIDs.insert(id)

        let content = raw["content"] as? String ?? ""
        let type = raw["type"] as? String ?? "text"
        let name = raw["name"] as? String ?? ""
        let userId = raw["userId"] as? Int

        // senderID 统一成 peerId（自己发的用 selfPeerID，系统的用空串）。
        var senderID = ""
        if type != "system" {
            if let userId = userId, userId == selfUserID {
                senderID = selfPeerID
            } else if let matched = remotePeers.values.first(where: { $0.userId == userId }) {
                senderID = matched.peerID
            } else {
                senderID = "u\(userId ?? 0)"
            }
        }

        let message = ChatMessage(
            id: id,
            senderID: senderID,
            senderName: name,
            text: content,
            date: Self.parseServerDate(raw["createdAt"]),
            kind: type == "system" ? .system : .text
        )
        delegate?.rtcDidReceiveMessage(message)
    }

    private static func parseServerDate(_ raw: Any?) -> Date {
        guard let string = raw as? String else { return Date() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
            ?? ISO8601DateFormatter().date(from: string)
            ?? Date()
    }

    private func publishLocalMediaState() {
        signaling?.sendMediaState(
            audio: localAudioTrack?.isEnabled,
            video: localVideoTrack?.isEnabled,
            screen: nil
        )
    }

    // MARK: - 状态回调

    private func updateConnectionState(_ state: ConnectionState) {
        connectionState = state
        delegate?.rtcDidChangeConnectionState(state)
    }

    private func updateNetworkQuality(_ quality: NetworkQuality) {
        delegate?.rtcDidChangeNetworkQuality(quality)
    }
}

// MARK: - TianqiongSignalingDelegate

extension RealRTCClient: TianqiongSignalingDelegate {

    func signalingDidConnect(_ signaling: TianqiongSignaling) {
        guard isJoined else { return }

        // 重连成功：重新 room:join（幂等，服务端返回当前快照），
        // 然后同步人员并对每条连接做 ICE restart。
        guard let options = options else { return }
        let hadPeers = !remotePeers.isEmpty
        updateConnectionState(.reconnecting)

        // TURN 的临时凭证只有 2 小时。长会里断一次网，如果继续拿入会那一刻的
        // 旧凭证去重建 PeerConnection，ICE 会一直停在 checking——用户看到的
        // 就是"一直在重连、始终连不上"。这里先换新凭证再入会。
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if let configs = try? await Self.fetchIceServersAsync() {
                self.iceServers = configs.map(Self.makeIceServer)
            }
            self.rejoinAfterReconnect(signaling, options: options, hadPeers: hadPeers)
        }
    }

    private func rejoinAfterReconnect(
        _ signaling: TianqiongSignaling,
        options: JoinOptions,
        hadPeers: Bool
    ) {
        signaling.join(
            no: options.no,
            name: options.name,
            password: options.password,
            audio: localAudioTrack?.isEnabled ?? options.audioOn,
            video: localVideoTrack?.isEnabled ?? options.videoOn,
            /* 把共享状态一起带上：一次 join 就把"人和共享"都恢复好，
               不用等服务端再回头问一遍，也不会出现"人回来了、共享没了"的空窗。 */
            screen: isScreenSharing,
            timeout: 12
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let snapshot):
                self.reconcileWithSnapshot(snapshot)
                self.updateConnectionState(.connected)
                self.updateNetworkQuality(hadPeers ? .fair : .good)
            case .failure(let failure):
                // 终态错误（会议结束/被移出/已锁定）直接结束；
                // 其余（网络抖动、FULL 等）保持重连态，Socket.IO 断开后会再次触发。
                let fatal = ["ENDED", "CANCELED", "KICKED", "LOCKED", "NOT_FOUND", "BAD_NO", "EXPIRED"].contains(failure.code)
                if fatal {
                    self.delegate?.rtcDidRejoinFail(message: failure.message)
                } else {
                    self.updateConnectionState(.reconnecting)
                }
            }
        }
    }

    func signalingDidDisconnect(_ signaling: TianqiongSignaling, reason: String) {
        guard isJoined else { return }
        updateConnectionState(.reconnecting)
        updateNetworkQuality(.poor)
    }

    func signalingDidFailToConnect(_ signaling: TianqiongSignaling, reason: String) {
        guard isJoined else { return }
        updateConnectionState(.reconnecting)
    }

    func signaling(
        _ signaling: TianqiongSignaling,
        didReceiveSignalFrom peerID: String,
        sdp: [String: Any]?,
        candidate: [String: Any]?,
        restart: Bool
    ) {
        guard let peer = remotePeers[peerID] else { return }
        if let sdp = sdp {
            peer.session.handleRemoteSDP(sdp)
        } else if let candidate = candidate {
            peer.session.handleRemoteCandidate(candidate)
        }
    }

    func signaling(
        _ signaling: TianqiongSignaling,
        didJoin selfInfo: [String: Any],
        peers: [[String: Any]],
        messages: [[String: Any]],
        meeting: [String: Any],
        locked: Bool,
        screenPeerID: String?
    ) {
        // 正常路径下快照在 join 的 ack 里处理；此回调仅用于防御。
    }

    func signaling(_ signaling: TianqiongSignaling, peerJoined peer: [String: Any]) {
        guard isJoined, let peerID = peer["peerId"] as? String else { return }
        guard remotePeers[peerID] == nil else { return }

        /* 有人进来之前，本端可能一直在等（单人没有 RTP 通道）。
           这一刻先确认音频会话是活的，再建连接挂轨道——WebRTC 的 ADM
           会在第一条音频发送流建立时启动采集，会话必须是 active 的。 */
        reactivateAudioSession()

        guard let session = makePeerSession(peerID: peerID) else { return }
        session.attachLocalTracks(audio: localAudioTrack, video: isScreenSharing ? localScreenTrack : localVideoTrack)
        /* 两路来源都要认：入会快照里带的 screen 标记，以及先于本事件到达、
           被 pendingScreenPeerID 暂存的 screen:state。 */
        let screenOn = (peer["screen"] as? Bool ?? false) || pendingScreenPeerID == peerID
        let remote = RemotePeer(
            peerID: peerID,
            name: DisplayName.clean(peer["name"] as? String),
            role: peer["role"] as? String ?? "attendee",
            audio: peer["audio"] as? Bool ?? false,
            video: peer["video"] as? Bool ?? false,
            screen: screenOn,
            hand: peer["hand"] as? Bool ?? false,
            userId: peer["userId"] as? Int,
            avatarColor: peer["avatarColor"] as? String ?? "",
            session: session
        )
        remotePeers[peerID] = remote
        if pendingScreenPeerID == peerID { pendingScreenPeerID = nil }

        /* 人数变了，共享码率要重新分摊：3 人共享和 2 人共享，
           每路能分到的上行预算不是一回事。 */
        if isScreenSharing { applyScreenEncodingBudget() }

        /* peer 建好之前到达的共享态必须在这一次补上，否则屏幕舞台永远不会出现。 */
        if screenOn {
            delegate?.rtcDidReceiveRemoteScreen(session.makeRemoteVideoView(), for: peerID)
        }

        publishParticipants()
        syncTeardownBox()
    }

    func signaling(_ signaling: TianqiongSignaling, peerLeft peerID: String, name: String, reason: String) {
        if pendingScreenPeerID == peerID { pendingScreenPeerID = nil }
        guard let peer = remotePeers.removeValue(forKey: peerID) else { return }
        peer.session.close()
        clearAudioLevelState(for: peerID)
        delegate?.rtcDidLoseRemoteMedia(for: peerID)
        // 少一个人，剩下的人可以分到更多上行。
        if isScreenSharing { applyScreenEncodingBudget() }
        publishParticipants()
        syncTeardownBox()
    }

    func signaling(_ signaling: TianqiongSignaling, peerMedia peerID: String, audio: Bool?, video: Bool?, screen: Bool?) {
        if peerID == selfPeerID { return }
        guard let peer = remotePeers[peerID] else { return }
        if let audio = audio { peer.audio = audio }
        if let video = video { peer.video = video }
        if let screen = screen {
            peer.screen = screen
            if screen {
                delegate?.rtcDidReceiveRemoteScreen(peer.session.makeRemoteVideoView(), for: peerID)
            } else {
                delegate?.rtcDidReceiveRemoteVideo(peer.session.makeRemoteVideoView(), for: peerID)
            }
        }
        publishParticipants()
    }

    func signaling(_ signaling: TianqiongSignaling, peerHand peerID: String, name: String, raised: Bool) {
        if peerID == selfPeerID { return }
        guard let peer = remotePeers[peerID] else { return }
        peer.hand = raised
        publishParticipants()
    }

    func signaling(_ signaling: TianqiongSignaling, chatMessage message: [String: Any]) {
        guard isJoined else { return }
        consumeChatMessage(message)
    }

    func signaling(_ signaling: TianqiongSignaling, reaction peerID: String, name: String, emoji: String) {
        // 服务端的反应事件：暂不接 UI，保留协议位。
    }

    func signaling(_ signaling: TianqiongSignaling, screenState peerID: String, on: Bool, resumed: Bool) {
        if peerID == selfPeerID { return }

        /* 竞态：新成员加入的瞬间，服务端的 screen:state 可能先于 peer:joined
           到达。之前这里直接 return，屏幕共享就永远不出现；先挂起，等
           peerJoined 建好连接再补。 */
        guard let peer = remotePeers[peerID] else {
            if on {
                pendingScreenPeerID = peerID
            } else if pendingScreenPeerID == peerID {
                pendingScreenPeerID = nil
            }
            return
        }

        peer.screen = on
        let view = peer.session.makeRemoteVideoView()
        if on {
            delegate?.rtcDidReceiveRemoteScreen(view, for: peerID)
        } else {
            delegate?.rtcDidReceiveRemoteVideo(view, for: peerID)
        }
        publishParticipants()
    }

    func signaling(_ signaling: TianqiongSignaling, screenBusy peerID: String) {
        // 别的参会者正在共享：停掉本地共享推流，提示由 VM 层转 toast。
        abortScreenShare(reason: "已有参会者正在共享屏幕，请稍后再试")
    }

    func signaling(_ signaling: TianqiongSignaling, screenDenied: ()) {
        abortScreenShare(reason: "主持人已关闭屏幕共享权限")
    }

    func signaling(_ signaling: TianqiongSignaling, mutedByHost: ()) {
        localAudioTrack?.isEnabled = false
        publishParticipants()
        delegate?.rtcDidGetMutedByHost()
    }

    func signaling(_ signaling: TianqiongSignaling, kickedBy hostName: String) {
        delegate?.rtcDidGetKicked(by: hostName)
    }

    func signaling(_ signaling: TianqiongSignaling, hostChanged hostPeerID: String, hostUserID: Int, hostName: String) {
        // 先把所有远端主持人降级，再设置新主持人，避免两个"主持人"并存。
        for peer in remotePeers.values {
            peer.role = "attendee"
        }
        if hostPeerID == selfPeerID {
            isSelfHost = true
        } else {
            isSelfHost = false
            if let peer = remotePeers[hostPeerID] {
                peer.role = "host"
            }
        }
        publishParticipants()
        delegate?.rtcDidHostChange(hostPeerID: hostPeerID, isSelfNowHost: isSelfHost)
    }

    func signaling(_ signaling: TianqiongSignaling, hostAway name: String, graceSeconds: Int) {
        delegate?.rtcDidReceiveMessage(
            ChatMessage(
                id: "host-away-\(Date().timeIntervalSince1970)",
                senderID: "",
                senderName: "系统",
                text: "主持人暂时离开，\(graceSeconds) 秒后会议将自动结束",
                kind: .system
            )
        )
    }

    func signaling(_ signaling: TianqiongSignaling, roomLocked locked: Bool) {
        delegate?.rtcDidRoomLockChange(locked: locked)
    }

    func signaling(_ signaling: TianqiongSignaling, meetingEnded by: String, reason: String) {
        delegate?.rtcDidMeetingEnd(reason: reason)
    }

    func signaling(_ signaling: TianqiongSignaling, meetingStarted no: String) {
        // 主持人提前进入预约会议：其他等待者收到后 UI 可刷新。
    }

    func signalingSessionReplaced(_ signaling: TianqiongSignaling) {
        delegate?.rtcDidSessionReplaced()
    }

    func signalingSessionRevoked(_ signaling: TianqiongSignaling) {
        delegate?.rtcDidSessionRevoked()
    }
}

// MARK: - PeerSessionDelegate

extension RealRTCClient: PeerSessionDelegate {

    func peerSession(_ session: PeerSession, needsSignalSDP sdp: RTCSessionDescription, restart: Bool) {
        let raw: [String: Any] = [
            "type": Self.sdpTypeString(sdp.type),
            "sdp": sdp.sdp,
        ]
        signaling?.sendSignal(to: session.peerID, sdp: raw, candidate: nil, restart: restart)
    }

    func peerSession(_ session: PeerSession, needsSignalCandidate candidate: RTCIceCandidate) {
        let raw: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? "",
            "sdpMLineIndex": candidate.sdpMLineIndex,
        ]
        signaling?.sendSignal(to: session.peerID, sdp: nil, candidate: raw)
    }

    func peerSession(_ session: PeerSession, didChangeConnectionState state: RTCPeerConnectionState) {
        switch state {
        case .connected:
            // 连接通了 ≠ 麦克风在发。真机诊断出现过"收 451 包、发 0 包"：
            // 界面一切正常，对方完全听不见。连接建立后核一次上行音频。
            scheduleOutboundAudioWatchdog(for: session)
        case .failed:
            // 交给 PeerSession 自己的 ICE restart / 重建逻辑。
            break
        default:
            break
        }
    }

    // MARK: - 上行音频看门狗

    /// 连接建立后核对 `outbound-rtp.packetsSent`。
    ///
    /// 三级处置：
    ///  1. 0 包 → 先判断是"设备不出帧"还是"sender 没挂上"：
    ///     设备级问题（音频会话被按停、AudioUnit 停摆）重挂 sender 是没用的，
    ///     必须整条音频链路重启；
    ///  2. 仍有轨道但 0 包 → 直接重挂当前轨道，再协商一次；
    ///  3. 两轮都失败 → 重建整条 PeerConnection。
    ///
    /// 之所以必须在运行时查：SDP 协商结果、音频会话状态、track 生命周期
    /// 这三件事在真机上都会漂移，任何一次判断失误都必须能自愈，
    /// 而不是让用户带着一个"哑巴麦克风"开完会。
    private func scheduleOutboundAudioWatchdog(for session: PeerSession, delay: TimeInterval = 3) {
        let peerID = session.peerID
        outboundAudioWatchdogs[peerID]?.cancel()

        let item = DispatchWorkItem { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session else { return }
                guard session === self.remotePeers[peerID]?.session else { return }

                session.peerConnection.statistics { report in
                    var sent = 0
                    for (_, stat) in report.statistics where stat.type == "outbound-rtp" {
                        if (stat.values["kind"] as? String) == "audio" {
                            sent = (stat.values["packetsSent"] as? NSNumber)?.intValue ?? 0
                        }
                    }
                    Task { @MainActor in
                        self.handleOutboundAudioProbe(
                            peerID: peerID,
                            session: session,
                            packetsSent: sent
                        )
                    }
                }
            }
        }
        outboundAudioWatchdogs[peerID] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func handleOutboundAudioProbe(peerID: String, session: PeerSession, packetsSent: Int) {
        guard session === remotePeers[peerID]?.session else { return }
        guard packetsSent == 0 else {
            outboundAudioProbeCounts.removeValue(forKey: peerID)
            return
        }
        // 用户自己静音着：0 包是正确状态，不是故障。
        guard localAudioTrack?.isEnabled == true else { return }

        let attempt = (outboundAudioProbeCounts[peerID] ?? 0) + 1
        outboundAudioProbeCounts[peerID] = attempt

        // 最多两轮补救：再往下就是无限重建，对用户没有任何好处。
        guard attempt <= 2 else { return }

        if attempt == 1 {
            /* 关键判断：如果有 audio sender、SDP 是 sendrecv、轨道也 live，
               那 0 包就不是"挂错了"，而是音频设备根本没在出帧。
               这时先把设备整条重启；重启函数内部会重建轨并重挂所有 peer，
               不需要再单独 forceReattach。 */
            let trackLive = localAudioTrack?.readyState == .live
            if trackLive {
                restartAudioPipeline(reason: "peer \(peerID) 连接 3 秒 0 包")
            } else {
                let track = rebuildAudioTrack()
                track?.isEnabled = true
                if let track = track {
                    session.forceReattachAudio(track)
                } else {
                    session.ensureLocalSenders()
                }
            }
            scheduleOutboundAudioWatchdog(for: session, delay: 4)
            return
        }

        // 第二轮仍 0 包：这条连接上的音频通道已经不可信，换一条。
        outboundAudioProbeCounts.removeValue(forKey: peerID)
        peerSessionNeedsRebuild(session)
    }

    func peerSession(_ session: PeerSession, didReceiveRemoteVideo track: RTCVideoTrack) {
        guard let peer = remotePeers[session.peerID] else { return }
        let view = session.makeRemoteVideoView()
        session.bindRemoteVideoRenderer()
        if peer.screen {
            delegate?.rtcDidReceiveRemoteScreen(view, for: session.peerID)
        } else {
            delegate?.rtcDidReceiveRemoteVideo(view, for: session.peerID)
        }
    }

    /// 远端音频轨到达（含共享扩展退出、音频会话重建后的重挂）。
    ///
    /// 这里必须**每次**都确认播放链路，而不只是第一次：
    /// 真机诊断里出现过"收 451 包、电平恒 0.00、听不见"——包在进、播放没启动。
    /// WebRTC 的 `inbound-rtp.audioLevel` 由播放线程更新，播放没启动电平就永远是 0，
    /// 于是"谁在说话"也不会亮。
    func peerSession(_ session: PeerSession, didReceiveRemoteAudio track: RTCAudioTrack) {
        track.isEnabled = true
        ensureAudioSessionActive()

        guard !didHandleFirstRemoteAudio else { return }
        didHandleFirstRemoteAudio = true

        // 首次：把输出抢回扬声器。用户已经插了耳机 / 连了蓝牙时不要覆盖——
        // 那会把声音从用户预期的设备里抢走。
        let route = RTCAudioSession.sharedInstance().currentRoute
        let hasExternal = route.outputs.contains {
            [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay].contains($0.portType)
        }
        if !hasExternal {
            try? RTCAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        }
    }

    /// 轻量确认：只在会话确实掉了的时候才重配，避免每次收包都碰系统。
    private func ensureAudioSessionActive() {
        let session = RTCAudioSession.sharedInstance()
        if !session.isActive || !session.isAudioEnabled {
            reactivateAudioSession()
            if !session.isAudioEnabled {
                session.isAudioEnabled = true
            }
        }
    }

    func peerSessionNeedsRebuild(_ session: PeerSession) {
        // 身份校验：只处理"当前仍挂在该 peer 名下"的会话，
        // 旧会话迟到的失败回调不会误杀重建后的新会话。
        guard let peer = remotePeers[session.peerID], peer.session === session else { return }
        session.close()

        guard let newSession = makePeerSession(peerID: session.peerID) else {
            // 重建失败：把该 peer 移出（等 peer:joined/重连快照再恢复）。
            remotePeers.removeValue(forKey: session.peerID)
            clearAudioLevelState(for: session.peerID)
            delegate?.rtcDidLoseRemoteMedia(for: session.peerID)
            publishParticipants()
            syncTeardownBox()
            return
        }
        // attachLocalTracks 会触发 negotiationneeded → negotiate()，无需手动 restart。
        newSession.attachLocalTracks(audio: localAudioTrack, video: isScreenSharing ? localScreenTrack : localVideoTrack)
        peer.session = newSession
        publishParticipants()
        syncTeardownBox()
    }

    private static func sdpTypeString(_ type: RTCSdpType) -> String {
        switch type {
        case .offer:
            return "offer"
        case .prAnswer:
            return "pranswer"
        case .answer:
            return "answer"
        @unknown default:
            return "answer"
        }
    }
}

// MARK: - 销毁清理盒

/// `@MainActor` 类的 deinit 是 nonisolated 的，不能访问隔离属性。
/// 这个盒子用 `nonisolated let` 持有、内部加锁，为 deinit 提供兜底清理：
/// 断开信令、关闭所有 peer 连接、停掉共享帧推送。
/// 正常路径由 leave() 完成清理，这里只兜"对象被直接释放"的场景。
final class RealRTCTeardownBox: @unchecked Sendable {

    private let lock = NSLock()
    private var signaling: TianqiongSignaling?
    private var sessions: [PeerSession] = []
    private var pusher: ScreenFramePusher?

    func update(
        signaling: TianqiongSignaling?,
        sessions: [PeerSession],
        pusher: ScreenFramePusher?
    ) {
        lock.lock()
        self.signaling = signaling
        self.sessions = sessions
        self.pusher = pusher
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        let signalingToStop = signaling
        let sessionsToClose = sessions
        let pusherToStop = pusher
        signaling = nil
        sessions = []
        pusher = nil
        lock.unlock()

        // 先取快照再放锁，避免持锁执行外部代码。
        // TianqiongSignaling 隔离到 @MainActor，这里用 Task 跳回主线程清理
        // （快照捕获的是具体对象，不捕获 self，不会与释放中的客户端形成环）。
        Task { @MainActor in
            pusherToStop?.stop()
            signalingToStop?.disconnect()
            sessionsToClose.forEach { $0.close() }
        }
    }
}

// MARK: - 屏幕帧推送

/// 共享看门狗的多 peer 统计累加器。
///
/// WebRTC 的 `statistics` 回调在库内部线程，多个 peer 并发回调；
/// 用一个小盒子加锁累加，避免在 `@Sendable` 闭包里捕获可变的局部变量。
private final class VideoUplinkTotals: @unchecked Sendable {

    private let lock = NSLock()
    private var packets = 0
    private var encoded = 0
    private var attached = true

    func merge(packets: Int, encoded: Int) {
        lock.lock()
        self.packets = max(self.packets, packets)
        self.encoded = max(self.encoded, encoded)
        lock.unlock()
    }

    func markDetached() {
        lock.lock()
        attached = false
        lock.unlock()
    }

    func snapshot() -> (packets: Int, encoded: Int, attached: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (packets, encoded, attached)
    }
}

/// 把 Broadcast 扩展写入 App Group 的 JPEG 帧推给 WebRTC screen source。
/// 20fps / 1080p 的共享帧率下，解码在专用后台队列，绝不碰主线程。
final class ScreenFramePusher {

    private let source: RTCVideoSource
    /// 本次会话的帧新鲜度下界。早于它的 JPEG 属于上一场，直接跳过。
    private let notBefore: Date
    private var timer: DispatchSourceTimer?
    private var lastFrameDate: Date?
    /// isRunning 主线程写、decodeQueue 读：用锁保护，避免 stop 后仍在解码的帧再推一帧。
    private let stateLock = NSLock()
    private var running = false
    /// 一帧正在解码。用来丢弃"来不赢处理"的采样，避免串行队列无限堆积。
    private var decoding = false
    /// 当前输出画布方向：true = 横屏 1920x1080，false = 竖屏 1080x1920。
    /// 只在 decodeQueue 上读写。
    private var canvasLandscape = true

    /// 与扩展侧的 24fps 对齐：轮询比生产慢就会积压旧帧，比生产快则空转。
    private static let pollInterval: TimeInterval = 1.0 / 24.0
    private static let decodeQueue = DispatchQueue(
        label: "com.tianqiong.meetingkit.screenpush",
        qos: .userInitiated
    )

    /// 轮询队列。与 decodeQueue 分开：轮询只读文件头判断新旧，
    /// 解码更重；共用一个队列会让「读文件」排在一次 1080p 解码后面，
    /// 帧率被自己的解码拖累。
    private static let pollQueue = DispatchQueue(
        label: "com.tianqiong.meetingkit.screenpoll",
        qos: .userInitiated
    )

    /// RTCVideoSource.capturer(_:didCapture:) 的第一个参数是非空的 RTCVideoCapturer，
    /// 这里挂一个只用于转发的采集器实例（真正推帧走 didCapture，不经过它的采集回调）。
    private let frameCapturer: RTCVideoCapturer

    init(source: RTCVideoSource, notBefore: Date) {
        self.source = source
        self.notBefore = notBefore
        self.frameCapturer = RTCVideoCapturer(delegate: source)
    }

    /// 切换输出画布。必须在 decodeQueue 上执行。
    ///
    /// `RTCVideoSource.adaptOutputFormat` 不是线程安全的：内部会重建
    /// video adapter，和 didCapture 并发就会崩在 OnFrame。beginScreenFramePush
    /// 过去是从主线程直接调的，而 tick() 在横竖屏切换时也会从 decodeQueue 调。
    func applyOutputFormat(width: Int32, height: Int32, fps: Int32) {
        Self.decodeQueue.sync {
            self.source.adaptOutputFormat(toWidth: width, height: height, fps: fps)
            self.canvasLandscape = width >= height
        }
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    func start() {
        guard !isRunning else { return }
        stateLock.lock()
        running = true
        stateLock.unlock()
        lastFrameDate = nil
        canvasLandscape = true

        // 必须挂在自己的串行队列，不能挂主队列。
        //
        // 屏幕共享的典型用法就是「共享后切到别的 App 去演示」——此时主 App 在后台，
        // 主队列会被系统降频甚至冻结，帧循环一停，对端画面就定住不动。
        // 挂到后台队列后，只要进程还活着（会议中有 audio 后台模式保活），帧就继续推。
        let timer = DispatchSource.makeTimerSource(queue: Self.pollQueue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
        timer?.cancel()
        timer = nil
        lastFrameDate = nil
    }

    private func tick() {
        guard isRunning else { return }

        // 关键：上一帧还没解码完就丢掉这一拍。
        //
        // 之前是每 1/24 秒无条件排一个 decode 任务进串行队列。单帧
        // （1080p JPEG → 1080p BGRA + CGContext 绘制）在主线程之外大约 30~60ms，
        // 也就是说生产速度永远快于消费速度，队列会**无限堆积**：
        // 内存一路涨、画面延迟一路涨，几分钟后就是"很卡、越用越卡"，
        // 严重时直接被 jetsam 杀掉（表现为共享突然中断）。
        //
        // 共享画面要的是"近实时"，不是"每帧都不丢"。宁可丢帧，
        // 也不能让队列里躺着几百毫秒前的旧画面。
        guard !isDecoding else { return }

        // readIfNewer 在文件级判断，轻量，可以主线程做；
        // 解码与帧构造丢到后台队列。
        // notBefore 把上一场残留的 JPEG 挡在门外——否则 push 会从旧帧开始，
        // 诊断计数看着在涨，实际上推的是几分钟前的画面。
        guard let jpeg = SharedFrameStore.readIfNewer(than: &lastFrameDate, notBefore: notBefore) else { return }

        beginDecoding()
        Self.decodeQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.endDecoding() }
            guard self.isRunning else { return }
            // 按图片宽高比选择画布方向：竖屏共享用 1080x1920，
            // 避免把竖屏画面硬塞进 1920x1080 留出大面积黑边（远端看不清文字）。
            guard let result = Self.jpegToPixelBuffer(jpeg) else { return }
            let landscape = result.width >= result.height
            if landscape != self.canvasLandscape {
                self.canvasLandscape = landscape
                let w = landscape ? 1920 : 1080
                let h = landscape ? 1080 : 1920
                self.source.adaptOutputFormat(
                    toWidth: Int32(w),
                    height: Int32(h),
                    fps: RealRTCClient.screenEncodingProfile.fps
                )
            }
            // 单调时钟（系统校时/休眠不影响帧时间戳连续性）。
            let timestamp = Int64(CACurrentMediaTime() * 1_000_000_000)
            let buffer = RTCCVPixelBuffer(pixelBuffer: result.buffer)
            let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timestamp)
            // 解码完成后再确认一次运行态，杜绝 stop 后最后一帧串台。
            guard self.isRunning else { return }
            self.source.capturer(self.frameCapturer, didCapture: frame)
            ScreenShareRuntime.noteFramePushed()
        }
    }

    private var isDecoding: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return decoding
    }

    private func beginDecoding() {
        stateLock.lock()
        decoding = true
        stateLock.unlock()
    }

    private func endDecoding() {
        stateLock.lock()
        decoding = false
        stateLock.unlock()
    }

    /// JPEG → BGRA CVPixelBuffer（等比缩放，留黑边）。画布方向按图片宽高比选择。
    static func jpegToPixelBuffer(_ data: Data) -> (buffer: CVPixelBuffer, width: Int32, height: Int32)? {
        guard
            let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return nil }

        let landscape = image.width >= image.height
        let width = landscape ? 1920 : 1080
        let height = landscape ? 1080 : 1920

        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // 等比缩放（Aspect Fit）。
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let scale = min(CGFloat(width) / imageWidth, CGFloat(height) / imageHeight)
        let drawWidth = imageWidth * scale
        let drawHeight = imageHeight * scale
        let drawRect = CGRect(
            x: (CGFloat(width) - drawWidth) / 2,
            y: (CGFloat(height) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: drawRect)

        return (buffer, Int32(width), Int32(height))
    }
}
