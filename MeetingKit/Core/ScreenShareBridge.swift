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

    /// 扩展侧上报的失败原因（App Group 不可用、编码器起不来……）。
    /// 只在**没有在共享**时对外暴露：共享正常时残留的旧错误没有意义。
    @Published private(set) var failure: String?

    /// 用户已经点了"开始共享"、但扩展还没写回 .active 的请求时间。
    /// 面板据此在 6 秒后提示"系统广播没有真正启动"，而不是一直显示空状态。
    @Published private(set) var pendingRequestAt: Date?

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

    /// 本次共享会话的帧新鲜度下界。早于它的文件属于上一场，不能当新帧。
    private var sessionFloor: Date?

    /// 预览解码令牌：后台解码完成时只有"最新一帧"允许上屏，
    /// 否则慢的旧帧后到，会把已经显示的新帧盖回去（画面倒退一拍）。
    private var previewToken = 0

    /// 预览解码队列。1080p JPEG 解一次 10~20ms，10fps 就吃掉主线程
    /// 10%~20% 的预算；主线程正在跑 SwiftUI 重绘时，这就是可见的掉帧。
    private static let previewDecodeQueue = DispatchQueue(
        label: "com.tianqiong.meetingkit.screenpreview",
        qos: .userInitiated
    )

    /// 预览拉取上限 10fps。扩展侧是 24fps，但主 App 的小窗预览不需要
    /// 跟满帧；真正上行给远端的是 ScreenFramePusher（24fps 轮询），
    /// 两条链路互不影响。
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
        sessionFloor = ScreenShareStore.sessionFloor
        if !isBroadcasting {
            pendingRequestAt = Self.recentPendingRequest(ScreenShareStore.requestedAt)
        }
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

    /// 用户点"开始共享"、系统面板弹出**之前**调用。
    ///
    /// 做三件事：
    ///   1. 清掉上一场留在容器里的 JPEG —— 否则主 App 会把旧图当成新帧，
    ///      诊断面板出现"扩展 idle 却出了 46 帧"的鬼故事；
    ///   2. 写 requestedAt，扩展起播后所有帧都必须晚于这个时刻；
    ///   3. 清空上一场的诊断计数，面板只反映本次会话。
    ///
    /// 正在共享时不动：用户可能在共享中再次打开面板，清场会把真实会话抹掉。
    func prepareForNewShare() {
        guard !isBroadcasting else { return }

        ScreenShareRuntime.reset()
        SharedFrameStore.clear()
        ScreenShareStore.prepareForNewSession()

        sessionFloor = ScreenShareStore.sessionFloor
        pendingRequestAt = ScreenShareStore.requestedAt
        startedAt = nil
        failure = nil
        latestFrame = nil
        lastFrameDate = nil
        lastFramePullTime = 0
        previewToken &+= 1
    }

    /// 从 App Group 重新读取状态。轮询兜底、回到前台、收到 stateChanged 时都会调用。
    func refreshState() {
        // 一次调用只读一次快照：state / heartbeat / requestedAt 必须来自同一版本，
        // 否则跨进程写入正好落在两次读之间，会拼出一个自相矛盾的诊断。
        let snapshot = ScreenShareStore.snapshot()
        let state = ScreenShareState(rawValue: snapshot?.state ?? "") ?? .idle

        // 会话下界：扩展写回的 requestedAt 优先级最高，老版本没有就退回 startedAt。
        // 再往前放宽 2 秒，跨过两进程时钟与文件系统 mtime 的毫秒级抖动。
        if let raw = snapshot?.requestedAt ?? snapshot?.startedAt {
            sessionFloor = Date(timeIntervalSince1970: raw - 2)
        }

        // 双判据：状态文件 + "有没有本次会话的新鲜帧"。
        //
        // 只信状态文件是有风险的——它是跨进程写出来的，任何一次写入失败、
        // 或者上一版残留的旧实现，都会让界面永远认为"没在共享"，而实际上
        // 扩展正在一帧一帧地写 JPEG。反过来，只要共享容器里的帧在 3 秒内被
        // 更新过，就说明扩展进程确实在出帧，这比任何状态字段都硬。
        //
        // 1.5.4 起还必须晚于 sessionFloor：容器里可能躺着上一场的 JPEG，
        // 它的 mtime 也可能很新（例如扩展被系统杀掉前刚写的一帧），
        // 不加下界就会把一场已经结束的共享重新点亮。
        let broadcasting = Self.isBroadcasting(state) || hasFreshFrame(since: sessionFloor)

        if isBroadcasting != broadcasting {
            isBroadcasting = broadcasting
        }

        var storedStart: Date?
        if broadcasting {
            storedStart = snapshot?.startedAt.map(Date.init(timeIntervalSince1970:))
            /* 兜底：状态文件已经被 reset，但扩展在 clear() 之前被系统杀掉，
               会留下一张 3 秒内的"新鲜帧"。此时 hasFreshFrame() 让 UI 显示共享中，
               startedAt 却是 nil，计时器就卡在 0:00。
               帧文件的 mtime 就是这一场共享第一次出帧的时刻，误差 < 1 帧。 */
            if storedStart == nil {
                storedStart = SharedFrameStore.modificationDate()
            }
        }

        if startedAt != storedStart {
            startedAt = storedStart
        }

        // 失败原因：只在"确认没在共享"时取。共享进行中读到上一次的旧错误，
        // 会弹一个和当前状态矛盾的提示。
        let storedFailure = broadcasting ? nil : snapshot?.lastError
        if failure != storedFailure {
            failure = storedFailure
        }

        // 请求了但扩展没起来：保留 requestedAt，面板 6 秒后据此提示。
        // 只认 90 秒内的请求：用户上次在系统面板点了取消，下一次冷启动
        // 不该再弹一次"系统广播没有启动"。
        let storedPending = broadcasting ? nil : Self.recentPendingRequest(snapshot?.requestedAt.map(Date.init(timeIntervalSince1970:)))
        if pendingRequestAt != storedPending {
            pendingRequestAt = storedPending
        }

        if broadcasting {
            pullLatestFrame(force: false)
        } else {
            // 共享结束就清空预览：否则用户下次进会还能看到上一场的最后一帧，像是个 bug。
            // 令牌自增，让还在后台解码的那一帧作废。
            previewToken &+= 1
            if latestFrame != nil {
                latestFrame = nil
            }
            lastFrameDate = nil
        }
    }

    /// 消费一次失败原因（弹过提示就清掉，避免每次刷新都重复弹）。
    func consumeFailure() {
        failure = nil
        ScreenShareStore.clearError()
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
        guard let data = SharedFrameStore.readIfNewer(than: &lastFrameDate, notBefore: sessionFloor) else { return }
        // 收到新帧就先记一笔：诊断面板据此区分"扩展没出帧"与"出了帧但没推上去"。
        ScreenShareRuntime.noteFrameWritten()
        /* 解码挪到后台：1080p JPEG 是 10~20ms 的活，放在主线程会和
           SwiftUI 重绘抢同一个 runloop，预览越顺、会中 UI 越卡。 */
        previewToken &+= 1
        let token = previewToken
        Self.previewDecodeQueue.async { [weak self] in
            guard let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.previewToken == token else { return }
                self.latestFrame = image
            }
        }
    }

    /// 生成一次共享链路诊断快照。面板每次展开时调用一次即可。
    func makeDiagnostics() -> ScreenShareDiagnostics {
        let snapshot = ScreenShareStore.snapshot()
        let now = Date()
        let state = ScreenShareState(rawValue: snapshot?.state ?? "") ?? .idle

        var frameBytes = 0
        var frameModified: Date?
        if let path = SharedFrameStore.fileURL()?.path,
           let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            frameBytes = (attributes[.size] as? Int) ?? 0
            frameModified = attributes[.modificationDate] as? Date
        }
        let video = ScreenShareRuntime.videoStats

        return ScreenShareDiagnostics(
            appGroupAvailable: AppGroupConfig.isAvailable,
            appGroupID: AppGroupConfig.identifier,
            extensionAppGroup: snapshot?.appGroup,
            state: state,
            startedAt: startedAt,
            heartbeatAge: snapshot?.heartbeat.map { now.timeIntervalSince1970 - $0 },
            extensionFrameSeq: snapshot?.frameSeq,
            extensionVersion: snapshot?.extensionVersion,
            framesWritten: ScreenShareRuntime.framesWritten,
            framesPushed: ScreenShareRuntime.framesPushed,
            lastPushAge: ScreenShareRuntime.lastPushAt.map { now.timeIntervalSince($0) },
            frameBytes: frameBytes,
            frameAge: frameModified.map { now.timeIntervalSince($0) },
            requestedAt: snapshot?.requestedAt.map(Date.init(timeIntervalSince1970:)),
            videoPacketsSent: video.packetsSent,
            videoFramesEncoded: video.framesEncoded,
            screenTrackAttached: video.screenAttached,
            lastError: snapshot?.lastError
        )
    }

    private static func isBroadcasting(_ state: ScreenShareState) -> Bool {
        // paused 也算"正在共享"：用户暂停的是画面推送，广播会话本身还在，UI 不能显示成已停止。
        state == .active || state == .paused
    }

    /// 只把 90 秒内的 requestedAt 当作"刚刚点过共享"。
    /// 超时的请求属于上一次已放弃的尝试，不能在新会话/冷启动时反复提示。
    private static func recentPendingRequest(_ date: Date?) -> Date? {
        guard let date = date else { return nil }
        return Date().timeIntervalSince(date) < 90 ? date : nil
    }

    /// 共享容器里是否有一个"刚刚才写过"的帧文件。
    ///
    /// 3 秒 = 扩展侧 24fps 出帧的正常间隔的 70 倍，足够跨过卡顿、切后台、
    /// 编码重入；又短到用户点完"停止"后不会长时间停留在共享态。
    ///
    /// - Parameter floor: 本次会话的起始时间。早于它的文件一律不算，
    ///   否则上一场的残留帧会把"已经停止的共享"重新点亮。
    private func hasFreshFrame(since floor: Date?) -> Bool {
        guard let modified = SharedFrameStore.modificationDate() else { return false }
        if let floor = floor, modified < floor { return false }
        return Date().timeIntervalSince(modified) < 3
    }
}

// MARK: - 诊断快照

/// 屏幕共享链路的一次性体检结果。
///
/// 链路是四段：扩展出帧 → 写共享容器 → 主 App 读帧 → 推给 WebRTC。
/// 任何一段断掉，用户看到的都是"对方黑屏"。这些计数就是用来定位断在哪一段的：
///   · 扩展组与 App 组不一致 → 扩展写多少帧主 App 都读不到（1.5.4 真机根因）
///   · extensionFrameSeq == 0 → 扩展没出帧（采样回调 / 编码器的问题）
///   · extensionFrameSeq 在涨、framesWritten 不涨 → 主 App 没读到（组或路径不一致）
///   · 两者都在涨但 videoPacketsSent == 0 → 共享轨没挂到 video sender / 编码器没启动
///   · packetsSent 在涨但对方仍黑屏 → 浏览器选轨或渲染问题
struct ScreenShareDiagnostics {
    var appGroupAvailable: Bool
    var appGroupID: String
    var extensionAppGroup: String?
    var state: ScreenShareState
    var startedAt: Date?
    var heartbeatAge: TimeInterval?
    var extensionFrameSeq: Int?
    var extensionVersion: String?
    var framesWritten: Int
    var framesPushed: Int
    var lastPushAge: TimeInterval?
    var frameBytes: Int
    var frameAge: TimeInterval?
    var requestedAt: Date?
    var videoPacketsSent: Int
    var videoFramesEncoded: Int
    var screenTrackAttached: Bool
    var lastError: String?

    /// 扩展与主 App 解析出的 App Group 是否真的不一致。
    var appGroupMismatch: Bool {
        guard let extensionAppGroup = extensionAppGroup else { return false }
        return extensionAppGroup != appGroupID
    }

    /// 给面板直接展示的多行文本。
    var report: String {
        var lines: [String] = []
        lines.append("App Group（App）：\(appGroupAvailable ? "可用" : "不可用")（\(appGroupID)）")

        if let extensionAppGroup = extensionAppGroup {
            let suffix = extensionAppGroup == appGroupID ? " · 一致" : "  ⚠️ 不一致，扩展写不进本容器"
            lines.append("App Group（扩展）：\(extensionAppGroup)\(suffix)")
        } else {
            lines.append("App Group（扩展）：未上报（扩展未启动，或读不到本容器）")
        }

        var stateLine = "扩展状态：\(state.rawValue)"
        if let version = extensionVersion {
            stateLine += " · 扩展 \(version)"
        }
        if let frames = extensionFrameSeq {
            stateLine += " · 扩展出帧 \(frames) 帧"
        }
        if let age = heartbeatAge {
            stateLine += String(format: " · 心跳 %.0f 秒前", age)
        } else {
            stateLine += " · 心跳无"
        }
        lines.append(stateLine)

        if state == .idle, let requestedAt = requestedAt {
            let waited = Date().timeIntervalSince(requestedAt)
            if waited > 6 {
                lines.append(String(format: "请求已 %.0f 秒，仍未收到扩展状态 ⚠️", waited))
            }
        }

        var readLine = "主 App 读到：\(framesWritten) 帧"
        if frameBytes > 0 {
            readLine += "（最新 \(frameBytes / 1024) KB"
            if let age = frameAge {
                readLine += String(format: " · %.1f 秒前", age)
            }
            readLine += "）"
        }
        lines.append(readLine)

        lines.append("已推 RTC：\(framesPushed) 帧" + (lastPushAge.map { String(format: "（%.0f 秒前）", $0) } ?? ""))
        lines.append(
            "RTC 视频：发送 \(videoPacketsSent) 包 · 编码 \(videoFramesEncoded) 帧 · "
            + (screenTrackAttached ? "共享轨已挂" : "共享轨未挂 ⚠️")
        )

        if let error = lastError {
            lines.append("最近错误：\(error)")
        }
        return lines.joined(separator: "\n")
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
