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

    /// 已消费的聊天消息 id（重连恢复快照时去重）。
    private var consumedMessageIDs: Set<String> = []

    // MARK: - 组件

    private var signaling: TianqiongSignaling?
    private var factory: RTCPeerConnectionFactory?
    private var iceServers: [RTCIceServer] = []

    private var localAudioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    private var localVideoSource: RTCVideoSource?
    private var localScreenTrack: RTCVideoTrack?
    private var localScreenSource: RTCVideoSource?
    private var videoCapturer: RTCCameraVideoCapturer?
    /// 摄像头是否正在采集。与 `localVideoTrack.isEnabled` 分开：
    /// 轨可以一直是开的，但采集停了（关摄像头时 stopCapture 会熄灯）。
    private var isCameraCapturing = false
    /// 本地音频电平轮询。WebRTC 没有公开的"当前麦克风电平"API，
    /// 只能从 getStats 的 media-source 统计里取 audioLevel。
    private var audioLevelTimer: Timer?
    private var previewView: RTCCameraPreviewView?

    private var screenPusher: ScreenFramePusher?

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

    /// 重新把音频会话抢回 playAndRecord + active。
    /// 幂等：已经在跑的时候调用只是多一次系统查询。
    private func reactivateAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try? session.setCategory(.playAndRecord, with: [.allowBluetooth, .defaultToSpeaker])
        try? session.setActive(true)
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
        guard let track = localAudioTrack else { return }
        track.isEnabled = enabled
        publishLocalMediaState()
        publishParticipants()
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
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            if enabled {
                try session.setCategory(.playAndRecord, with: [.allowBluetooth, .defaultToSpeaker])
                try session.overrideOutputAudioPort(.speaker)
            } else {
                // 听筒模式：去掉 defaultToSpeaker 让系统按接近传感器路由。
                try session.setCategory(.playAndRecord, with: [.allowBluetooth])
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
        // 画质档位必须在这里落到采集格式上：只改 setVideoEncoding 的码率，
        // 源仍是 1080p/20，弱网下"流畅"档并不会真的更流畅。
        source.adaptOutputFormat(toWidth: profile.width, height: profile.height, fps: profile.fps)

        // 用共享轨替换每条连接的 video sender（Web 端同款 replaceTrack）。
        for peer in remotePeers.values {
            peer.session.replaceVideoTrack(with: track)
            peer.session.setVideoEncoding(
                maxBitrateBps: profile.bitrate,
                maxFramerate: Int(profile.fps),
                keepResolution: true
            )
        }

        let pusher = ScreenFramePusher(source: source)
        screenPusher = pusher
        pusher.start()
        /* ReplayKit 刚开始广播时会重配一次系统音频路由，主 App 的 audio unit
           经常被顺手掐掉。共享和通话是两条独立链路，画面起来不能让声音躺下。 */
        reactivateAudioSession()
        syncTeardownBox()
    }

    /// Broadcast 扩展确认停止共享后调用：恢复摄像头轨。
    func endScreenFramePush() {
        screenPusher?.stop()
        screenPusher = nil
        isScreenSharing = false
        let back = localVideoTrack
        for peer in remotePeers.values {
            peer.session.replaceVideoTrack(with: back)
            // 恢复摄像头档位：2.5Mbps / 30fps，把上行让回给实时画面。
            peer.session.setVideoEncoding(maxBitrateBps: 2_500_000, maxFramerate: 30)
        }
        /* 广播结束同样会切一次路由：不抢回来，用户会遇到
           "共享停了以后反而听不见人说话"。 */
        reactivateAudioSession()
        syncTeardownBox()
    }

    /// 服务端拒绝共享（screen:busy / screen:denied）：停本地推流并通知上层。
    private func abortScreenShare(reason: String) {
        guard isScreenSharing else {
            delegate?.rtcDidScreenShareRejected(reason: reason)
            return
        }
        isScreenSharing = false
        screenPusher?.stop()
        screenPusher = nil
        let back = localVideoTrack
        for peer in remotePeers.values {
            peer.session.replaceVideoTrack(with: back)
            peer.session.setVideoEncoding(maxBitrateBps: 2_500_000, maxFramerate: 30)
        }
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
        try await withCheckedThrowingContinuation { continuation in
            signaling.join(
                no: options.no,
                name: options.name,
                password: options.password,
                audio: options.audioOn,
                video: options.videoOn,
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
        let factory = RTCPeerConnectionFactory()
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

        // 激活音频会话：外放 + 后台混音模式。
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        defer { audioSession.unlockForConfiguration() }
        try? audioSession.setCategory(.playAndRecord, with: [.allowBluetooth, .defaultToSpeaker])
        try? audioSession.setActive(true)
    }

    private static func requestCameraPermission() async -> Bool {
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
        // 任意一条连接拿到的都是同一路本地音频，取第一条即可。
        guard let pc = remotePeers.values.first?.session.peerConnection else { return }

        pc.statistics { [weak self] report in
            guard let self = self else { return }

            var peak: Float = 0
            for (_, stat) in report.statistics where stat.type == "media-source" {
                guard let value = stat.values["audioLevel"] as? NSNumber else { continue }
                peak = max(peak, value.floatValue)
            }

            DispatchQueue.main.async {
                self.delegate?.rtcDidUpdateLocalAudioLevel(peak)
            }
        }
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
        selfName = snapshot.selfInfo["name"] as? String ?? ""
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
                name: raw["name"] as? String ?? "",
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
        selfName = snapshot.selfInfo["name"] as? String ?? selfName
        selfAvatarColor = snapshot.selfInfo["avatarColor"] as? String ?? selfAvatarColor
        meetingInfo = snapshot.meeting
        publishBrand(from: snapshot.meeting)

        // 全部关闭重建。
        for (peerID, peer) in remotePeers {
            peer.session.close()
            delegate?.rtcDidLoseRemoteMedia(for: peerID)
        }
        remotePeers.removeAll()

        for raw in snapshot.peers {
            guard let peerID = raw["peerId"] as? String else { continue }
            guard let session = makePeerSession(peerID: peerID) else { continue }
            let peer = RemotePeer(
                peerID: peerID,
                name: raw["name"] as? String ?? "",
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

        guard let session = makePeerSession(peerID: peerID) else { return }
        session.attachLocalTracks(audio: localAudioTrack, video: isScreenSharing ? localScreenTrack : localVideoTrack)
        let remote = RemotePeer(
            peerID: peerID,
            name: peer["name"] as? String ?? "",
            role: peer["role"] as? String ?? "attendee",
            audio: peer["audio"] as? Bool ?? false,
            video: peer["video"] as? Bool ?? false,
            screen: peer["screen"] as? Bool ?? false,
            hand: peer["hand"] as? Bool ?? false,
            userId: peer["userId"] as? Int,
            avatarColor: peer["avatarColor"] as? String ?? "",
            session: session
        )
        remotePeers[peerID] = remote
        publishParticipants()
        syncTeardownBox()
    }

    func signaling(_ signaling: TianqiongSignaling, peerLeft peerID: String, name: String, reason: String) {
        guard let peer = remotePeers.removeValue(forKey: peerID) else { return }
        peer.session.close()
        delegate?.rtcDidLoseRemoteMedia(for: peerID)
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
        guard let peer = remotePeers[peerID] else { return }
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
            if let peer = remotePeers[session.peerID] {
                _ = peer
            }
        case .failed:
            // 交给 PeerSession 自己的 ICE restart / 重建逻辑。
            break
        default:
            break
        }
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

    func peerSessionNeedsRebuild(_ session: PeerSession) {
        // 身份校验：只处理"当前仍挂在该 peer 名下"的会话，
        // 旧会话迟到的失败回调不会误杀重建后的新会话。
        guard let peer = remotePeers[session.peerID], peer.session === session else { return }
        session.close()

        guard let newSession = makePeerSession(peerID: session.peerID) else {
            // 重建失败：把该 peer 移出（等 peer:joined/重连快照再恢复）。
            remotePeers.removeValue(forKey: session.peerID)
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

/// 把 Broadcast 扩展写入 App Group 的 JPEG 帧推给 WebRTC screen source。
/// 20fps / 1080p 的共享帧率下，解码在专用后台队列，绝不碰主线程。
final class ScreenFramePusher {

    private let source: RTCVideoSource
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

    /// 与扩展侧的 20fps 对齐：轮询比生产慢就会积压旧帧，比生产快则空转。
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

    init(source: RTCVideoSource) {
        self.source = source
        self.frameCapturer = RTCVideoCapturer(delegate: source)
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
        guard let jpeg = SharedFrameStore.readIfNewer(than: &lastFrameDate) else { return }

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
