//
//  MockRTCClient.swift
//  MeetingKit
//
//  本地"假会议"。阶段 2 的 UI 需要持续变化的数据源才能开发（参会者进出、
//  发言人轮换、网络抖动、聊天消息），而真实 RTC SDK 要到阶段 3 才接入。
//
//  实现要点：
//    1. 用 DispatchSourceTimer（主队列，1s 间隔）驱动，所有状态只在主线程读写；
//    2. 定时器捕获 [weak self]，deinit 与 leave 都取消定时器，避免循环引用与幽灵回调；
//    3. join / leave 幂等：重复调用不会起第二个定时器，也不会重复回调 delegate。
//

import Foundation
import UIKit

@MainActor
final class MockRTCClient: RTCClient {

    // MARK: - RTCClient

    weak var delegate: RTCClientDelegate?

    // MARK: - 内部状态（仅主线程访问）

    private var heartbeatTimer: DispatchSourceTimer?
    private var isJoined = false
    private var roomID: String = ""
    private var localUser: MeetingUser?
    private var participants: [MeetingUser] = []

    private var tickCount = 0
    private var qualityCursor = 0
    private var messageCursor = 0
    private var speakerCursor = 0

    // MARK: - 模拟节奏

    private static let heartbeatInterval: TimeInterval = 1.0
    private static let speakerRotationTicks = 6
    private static let qualityTicks = 3
    private static let messageTicks = 9

    /// 质量在 good/fair/poor 之间来回波动，让"网络差"的提示条有机会被验证到。
    private static let networkCycle: [NetworkQuality] = [.good, .good, .fair, .poor, .fair, .good]

    /// 7 个假参会者（不含自己）。名字与配色索引配合，方便阶段 2 直接映射头像底色。
    private static let remoteSeeds: [(name: String, role: MeetingRole, colorIndex: Int)] = [
        ("陈思远", .coHost, 1),
        ("林悦", .participant, 2),
        ("王皓", .participant, 3),
        ("赵敏", .participant, 4),
        ("周宇", .participant, 5),
        ("孙嘉", .participant, 6),
        ("李航", .participant, 7)
    ]

    private static let cannedMessages: [String] = [
        "我这边的画面有点卡，你们呢？",
        "第三章的表格我补充到共享文档里了。",
        "稍等，我调整一下麦克风。",
        "建议大家都戴耳机，不然会有回音。",
        "会议纪要我会后发到群里。",
        "时间还够的话，我们把下半部分也过一遍。"
    ]

    // MARK: - 生命周期

    deinit {
        // @MainActor 类的 deinit 是 nonisolated 的，不能碰隔离属性；
        // 定时器由 leave() 负责取消（VM 离会时一定会调），这里不再重复清理。
    }

    // MARK: - RTCClient: 连接

    func join(roomID: String, me: MeetingUser, options: JoinOptions) async throws {
        // 为什么要绕 MainActor.run：
        // 按 SE-0338，nonisolated 的 async 函数整个函数体都跑在并发执行器上，
        // 而不是调用方所在的线程。本类的全部状态都由主队列上的定时器与 leave() 读写，
        // 所以 join 的每一步都必须显式切回主线程，否则就是数据竞争。
        let accepted: Bool = await MainActor.run { [weak self] in
            guard let self = self else { return false }
            return self.prepareJoin(roomID: roomID, me: me)
        }
        guard accepted else { return }  // 已入会（幂等）或对象已释放

        // 模拟信令 + ICE 的握手耗时。真实实现里这段时间会有好几轮网络往返。
        try await Task.sleep(nanoseconds: 350_000_000)

        await MainActor.run { [weak self] in
            guard let self = self else { return }
            self.completeJoin(me: me)
        }
    }

    /// 入会第一阶段（主线程）：占位、置为 connecting。返回 false 表示拒绝本次入会。
    @MainActor
    private func prepareJoin(roomID: String, me: MeetingUser) -> Bool {
        guard !isJoined else { return false }  // 幂等：已入会时直接返回，不重复建连

        isJoined = true
        self.roomID = roomID
        localUser = me
        participants = []
        tickCount = 0
        qualityCursor = 0
        messageCursor = 0
        speakerCursor = 0

        publish { $0.rtcDidChangeConnectionState(.connecting) }
        return true
    }

    /// 入会第二阶段（主线程）：填充参会者、通知 connected、启动心跳。
    @MainActor
    private func completeJoin(me: MeetingUser) {
        // 等待期间用户可能已经点了"离开"，此时不应该再把自己"拉进会"。
        guard isJoined else { return }

        participants = Self.makeParticipants(me: me)
        publish { $0.rtcDidUpdateParticipants(self.participants) }
        publish { $0.rtcDidChangeConnectionState(.connected) }
        publish { $0.rtcDidChangeActiveSpeaker(self.firstRemoteID()) }
        publish { $0.rtcDidChangeNetworkQuality(.good) }

        startHeartbeat()
    }

    func leave() {
        guard isJoined else { return }  // 幂等
        isJoined = false
        stopHeartbeat()

        participants.removeAll()
        localUser = nil
        roomID = ""

        publish { $0.rtcDidChangeActiveSpeaker(nil) }
        publish { $0.rtcDidUpdateParticipants([]) }
        publish { $0.rtcDidChangeConnectionState(.disconnected) }
    }

    // MARK: - RTCClient: 设备与状态

    func setMicEnabled(_ enabled: Bool) {
        updateLocalUser { $0.isMicOn = enabled }
    }

    func setCameraEnabled(_ enabled: Bool) {
        updateLocalUser { $0.isCameraOn = enabled }
    }

    func setHandRaised(_ raised: Bool) {
        updateLocalUser { $0.isHandRaised = raised }
    }

    func startScreenShare() {
        // 本阶段无副作用：App 无法自行发起 ReplayKit 广播，
        // 真实共享状态由 ScreenShareBridge 从 App Group 读取，避免两处状态互相打架。
    }

    func stopScreenShare() {
        // 同 startScreenShare：停止动作走 ScreenShareBridge.requestStop()。
    }

    func switchCamera() {
        // Mock 无真实摄像头。
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        // Mock 无真实音频设备。
    }

    func localPreviewView() -> UIView? {
        nil
    }

    func beginScreenFramePush() {
        // Mock 无真实推流。
    }

    func endScreenFramePush() {
        // Mock 无真实推流。
    }

    // MARK: - RTCClient: 主持人操作（Mock 只改本地状态）

    func mutePeer(_ userID: String) {
        updateParticipant(userID) { $0.isMicOn = false }
    }

    func muteAllPeers() {
        for index in participants.indices where !participants[index].isLocal {
            participants[index].isMicOn = false
        }
        publish { $0.rtcDidUpdateParticipants(self.participants) }
    }

    func removePeer(_ userID: String) {
        participants.removeAll { $0.id == userID }
        publish { $0.rtcDidUpdateParticipants(self.participants) }
    }

    func transferHost(to userID: String) {
        for index in participants.indices {
            if participants[index].id == userID {
                participants[index].role = .host
            } else if participants[index].role == .host {
                participants[index].role = .coHost
            }
        }
        publish { $0.rtcDidUpdateParticipants(self.participants) }
    }

    func setRoomLocked(_ locked: Bool) {
        // Mock 无服务端，锁定只影响本地 UI（由 VM 维护）。
    }

    func endMeeting() {
        // Mock：结束会议 = 直接离会（VM 层处理遮罩）。
        leave()
    }

    // MARK: - RTCClient: 消息

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let me = localUser else { return }

        let message = ChatMessage(
            senderID: me.id,
            senderName: me.name,
            text: trimmed,
            kind: .text
        )
        publish { $0.rtcDidReceiveMessage(message) }
    }

    // MARK: - 心跳

    private func startHeartbeat() {
        stopHeartbeat()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.heartbeatInterval,
            repeating: Self.heartbeatInterval,
            leeway: .milliseconds(200)
        )
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func tick() {
        guard isJoined else { return }
        tickCount += 1

        if tickCount % Self.speakerRotationTicks == 0 {
            rotateSpeaker()
        }
        if tickCount % Self.qualityTicks == 0 {
            shiftNetworkQuality()
        }
        if tickCount % Self.messageTicks == 0 {
            deliverSyntheticMessage()
        }
    }

    private func rotateSpeaker() {
        let remotes = participants.filter { !$0.isLocal }
        guard !remotes.isEmpty else { return }

        speakerCursor = (speakerCursor + 1) % remotes.count
        let speakerID = remotes[speakerCursor].id

        // 发言人标记是全量的：先把所有人清掉再点亮一个，避免出现"多人同时在说话"。
        for index in participants.indices {
            participants[index].isSpeaking = (participants[index].id == speakerID)
        }

        publish { $0.rtcDidChangeActiveSpeaker(speakerID) }
        publish { $0.rtcDidUpdateParticipants(self.participants) }
    }

    private func shiftNetworkQuality() {
        qualityCursor = (qualityCursor + 1) % Self.networkCycle.count
        let quality = Self.networkCycle[qualityCursor]
        publish { $0.rtcDidChangeNetworkQuality(quality) }
    }

    private func deliverSyntheticMessage() {
        let remotes = participants.filter { !$0.isLocal }
        guard !remotes.isEmpty else { return }

        let sender = remotes[messageCursor % remotes.count]
        let text = Self.cannedMessages[messageCursor % Self.cannedMessages.count]
        messageCursor += 1

        let message = ChatMessage(
            senderID: sender.id,
            senderName: sender.name,
            text: text,
            kind: .text
        )
        publish { $0.rtcDidReceiveMessage(message) }
    }

    // MARK: - 工具

    private func updateLocalUser(_ mutate: (inout MeetingUser) -> Void) {
        guard let index = participants.firstIndex(where: { $0.isLocal }) else { return }
        mutate(&participants[index])
        publish { $0.rtcDidUpdateParticipants(self.participants) }
    }

    private func updateParticipant(_ id: String, _ mutate: (inout MeetingUser) -> Void) {
        guard let index = participants.firstIndex(where: { $0.id == id }) else { return }
        mutate(&participants[index])
        publish { $0.rtcDidUpdateParticipants(self.participants) }
    }

    private func firstRemoteID() -> String? {
        participants.first(where: { !$0.isLocal })?.id
    }

    /// 所有 delegate 回调的统一出口。
    ///
    /// 为什么不在各处自己包 DispatchQueue.main：阶段 2 的 UI 会在这些回调里直接改
    /// @State / @Published，线程正确性由协议实现方一次性保证，UI 侧不必也没能力判断。
    private func publish(_ block: @escaping (RTCClientDelegate) -> Void) {
        let deliver: () -> Void = { [weak self] in
            guard let self = self, let delegate = self.delegate else { return }
            block(delegate)
        }

        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    private static func makeParticipants(me: MeetingUser) -> [MeetingUser] {
        // 自己放第一位：宫格布局和"发言人优先"排序都以数组顺序为基准。
        // isMicOn / isCameraOn / isHandRaised 必须原样沿用 me：这三个值由 ViewModel 持有，
        // 在这里硬编码 true 会让"重进会议后底栏与参会人列表互相矛盾"（D-03）。
        var local = me
        local.isLocal = true
        local.isSpeaking = false

        var result: [MeetingUser] = [local]
        for seed in remoteSeeds {
            let remote = MeetingUser(
                id: "remote-\(seed.colorIndex)",
                name: seed.name,
                role: seed.role,
                isMicOn: seed.colorIndex % 2 == 1,
                isCameraOn: seed.colorIndex % 3 != 0,
                isHandRaised: false,
                isSpeaking: false,
                isLocal: false,
                avatarColorIndex: seed.colorIndex
            )
            result.append(remote)
        }
        return result
    }
}
