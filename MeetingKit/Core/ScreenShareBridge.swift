//
//  ScreenShareBridge.swift
//  MeetingKit
//
//  主 App 侧的屏幕共享状态中枢：把"另一个进程正在发生的事"翻译成 SwiftUI 能消费的 @Published。
//
//  跨进程时序：
//    扩展 broadcastStarted  → ScreenShareStore(.active) + post stateChanged
//                            → 本类 refreshState() → isBroadcasting = true
//    扩展 processSampleBuffer → 写 JPEG 文件 + post frameUpdated
//                            → 本类 pullLatestFrame() → 解码 → latestFrame 更新
//    用户点"停止共享"        → requestStop() → post stopRequested → 扩展自行结束
//                            → 扩展 broadcastFinished → post stateChanged → 本类回到 idle
//    存活检测                → 读 ScreenShareStore.heartbeat（扩展每 2 秒刷一次）
//                            → 超过 12 秒没心跳才判死，与"有没有新帧"无关（H-1）
//

import Combine
import UIKit

@MainActor
final class ScreenShareBridge: ObservableObject {

    // MARK: - 对外状态（阶段 2 只读）

    @Published private(set) var isBroadcasting: Bool = false
    @Published private(set) var latestFrame: UIImage?
    @Published private(set) var startedAt: Date?

    // MARK: - 观察者生命周期

    /// 为什么用独立的盒子装 token：
    /// `@MainActor` 类的 `deinit` 是 nonisolated 的（对象销毁时没有 actor 上下文），
    /// 直接访问 actor 隔离的存储属性会编译失败。把 token 放进一个 Sendable 的盒子，
    /// 并声明成 `nonisolated let`，deinit 才能合法地把它取出来清理。
    private nonisolated let darwinTokens = ObserverTokenBag()
    private nonisolated let notificationTokens = ObserverTokenBag()

    private var isObserving = false

    // MARK: - 帧节流状态

    private var lastFrameDate: Date?
    private var lastFramePullTime: CFTimeInterval = 0

    /// 主线程解码上限 10fps。扩展侧是 4fps，这里留余量防止突发抖动时连续解码拖慢主线程。
    private static let minFramePullInterval: CFTimeInterval = 0.1

    /// 心跳超时。扩展最多每 2 秒写一次心跳，12 秒 = 连续漏掉 6 次，
    /// 足以排除系统调度抖动与 cfprefsd 延迟，又不会让"扩展已经死了"的界面卡太久。
    ///
    /// 判活必须靠心跳而不是"多久没收到新帧"：ReplayKit 在画面静止时会降低甚至
    /// 停发 sample，此时扩展完全健康却没有新 JPEG，用帧判活会误杀正常广播（H-1）。
    private static let heartbeatTimeout: TimeInterval = 12

    // MARK: - 初始化

    init() {
        // 冷启动时扩展可能已经在跑了（例如 App 被系统回收后用户仍在共享），
        // 所以初始化就同步读一次真实状态，避免 UI 先闪一下"未共享"。
        let state = ScreenShareStore.state
        isBroadcasting = Self.isBroadcasting(state)
        startedAt = ScreenShareStore.startedAt
    }

    deinit {
        // deinit 不能调用 @MainActor 方法，但 DarwinNotifier 与 NotificationCenter
        // 的移除接口都是 nonisolated 的，可以直接在这里收尾，防止野回调打到已释放对象。
        darwinTokens.drain().forEach { DarwinNotifier.removeObserver($0) }
        notificationTokens.drain().forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - 对外接口

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        // DarwinNotifier 内部已经把回调切到主线程，这里再包一层 Task 是因为
        // 闭包本身是 nonisolated 的，编译器不接受它同步调用 @MainActor 方法。
        let stateToken = DarwinNotifier.addObserver(ScreenShareSignal.stateChanged) { [weak self] in
            Task { @MainActor in
                // 用 guard 而不是 self?.xxx()，让闭包体是语句而非单表达式，
                // 避免 Task 的泛型返回类型被推断成 Void?。
                guard let self = self else { return }
                self.refreshState()
            }
        }
        darwinTokens.store(stateToken)

        let frameToken = DarwinNotifier.addObserver(ScreenShareSignal.frameUpdated) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.pullLatestFrame(force: false)
            }
        }
        darwinTokens.store(frameToken)

        // 兜底：Darwin 通知在后台可能被系统合并或延迟，回到前台时主动对一次账。
        let activeToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshState()
                self.pullLatestFrame(force: true)
            }
        }
        notificationTokens.store(activeToken)

        refreshState()
        pullLatestFrame(force: true)
    }

    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        darwinTokens.drain().forEach { DarwinNotifier.removeObserver($0) }
        notificationTokens.drain().forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 请求扩展停止共享。
    /// 注意是"请求"：主 App 无权直接终止扩展进程，扩展收到通知后自己调
    /// `finishBroadcastWithError` 走系统正常收尾流程，随后会广播 stateChanged。
    func requestStop() {
        DarwinNotifier.post(ScreenShareSignal.stopRequested)
    }

    /// 从 App Group 重新读取状态。轮询兜底、回到前台、收到 stateChanged 时都会调用。
    func refreshState() {
        let state = ScreenShareStore.state
        let broadcasting = Self.isBroadcasting(state)

        if isBroadcasting != broadcasting {
            isBroadcasting = broadcasting
        }

        let storedStart = broadcasting ? ScreenShareStore.startedAt : nil
        if startedAt != storedStart {
            startedAt = storedStart
        }

        if broadcasting {
            pullLatestFrame(force: false)
        } else {
            // 共享结束就清空预览：否则用户下次进会还能看到上一场的最后一帧，像是个 bug。
            if latestFrame != nil {
                latestFrame = nil
            }
            lastFrameDate = nil
        }
    }

    /// 存活检测。由 ViewModel 的低频轮询调用（每 4 秒一次即可：只是读一次 UserDefaults
    /// 里的心跳时间戳，不碰帧文件，成本可以忽略）。
    ///
    /// 判活依据是扩展写下的**心跳**（`ScreenShareStore.heartbeat`），不是帧到达：
    /// ReplayKit 在画面静止（用户只是说话、没在翻页）时会降低甚至停发 sample，
    /// 此时进程健康却一帧 JPEG 都没有；用"6 秒没有新帧"判死会把正常广播误杀，
    /// 叠加乐观置值就变成"广播还在推、App 里停不掉"这种互相矛盾的状态（H-1）。
    ///
    /// 只处理 `.active`：`.idle` 没有判定意义；`.paused` 期间系统不一定继续回调
    /// video 采样，心跳可能仍在也可能不在，判了只会误伤，所以直接跳过。
    func validateLiveness() {
        // 后台不解码，状态也可能被系统节流；此时判定一定误伤，直接跳过。
        guard UIApplication.shared.applicationState == .active else { return }

        let state = ScreenShareStore.state
        guard state == .active else { return }

        let now = Date()
        let isDead: Bool
        if let heartbeat = ScreenShareStore.heartbeat {
            isDead = now.timeIntervalSince(heartbeat) > Self.heartbeatTimeout
        } else if let start = ScreenShareStore.startedAt {
            // 一次心跳都没拿到（扩展刚起播、或心跳写入失败）：退回按启动时间兜底。
            // 阈值与心跳超时统一到 12 秒，避免出现"两种口径"各自一套宽限期。
            isDead = now.timeIntervalSince(start) > Self.heartbeatTimeout
        } else {
            // 状态是 .active 却没有 startedAt，说明扩展在写完 startedAt 前就被杀了，
            // 这是脏数据——不能 return，否则会永久卡在"正在共享"。
            isDead = true
        }

        guard isDead else { return }

        // 兜底收尾：扩展被 jetsam 杀掉后不会留下任何回调，只能由主 App 主动清脏状态，
        // 否则 UI 会一直停在"正在共享"，用户点停止也只是往空气里发通知。
        ScreenShareStore.reset()
        SharedFrameStore.clear()
        refreshState()
    }

    // MARK: - 私有

    /// 读取并解码最新一帧。`force` 用于跳过 10fps 节流（启动观察 / 回到前台时补帧）。
    private func pullLatestFrame(force: Bool) {
        let now = CACurrentMediaTime()
        if !force, now - lastFramePullTime < Self.minFramePullInterval {
            return
        }
        lastFramePullTime = now

        // 后台不解码：屏幕不可见，解码纯属浪费 CPU 和内存，还可能触发后台内存回收。
        guard UIApplication.shared.applicationState == .active else { return }
        guard let data = SharedFrameStore.readIfNewer(than: &lastFrameDate) else { return }
        // JPEG 只有几十 KB，主线程解码耗时在毫秒级，比跨线程往返 + 图片对象传递更划算。
        guard let image = UIImage(data: data) else { return }
        latestFrame = image
    }

    private static func isBroadcasting(_ state: ScreenShareState) -> Bool {
        // paused 也算"正在共享"：用户暂停的是画面推送，广播会话本身还在，UI 不能显示成已停止。
        state == .active || state == .paused
    }
}

// MARK: - Token 容器

/// 线程安全的观察者 token 盒。
///
/// 存在的唯一理由：给 `@MainActor` 类的 `deinit` 提供一条合法的清理路径
/// （deinit 是 nonisolated 的，不能碰 actor 隔离的存储属性）。
/// 用锁而不是队列，是因为 deinit 里不能假设任何 actor 上下文。
private final class ObserverTokenBag: @unchecked Sendable {

    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func store(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    /// 取出全部 token 并清空。返回快照后再由调用方移除观察者，
    /// 避免持锁执行外部代码（可能重入）。
    func drain() -> [NSObjectProtocol] {
        lock.lock()
        let snapshot = tokens
        tokens.removeAll()
        lock.unlock()
        return snapshot
    }
}
