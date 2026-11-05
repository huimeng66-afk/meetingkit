//
//  ScreenShareSignal.swift
//  Shared
//
//  屏幕共享的跨进程通信层。两个进程（主 App / 广播扩展）之间的全部交互只有三类：
//    1. 状态：ScreenShareStore 读写 App Group 容器里的一个小 JSON（可回读、有持久语义）
//    2. 信号：Darwin 通知（notify(3)），只做"有变化了"的提示，不携带负载
//    3. 数据：最新一帧 JPEG 走 SharedFrameStore 的文件通道
//
//  为什么不用 NotificationCenter.default：它只在单进程内有效，跨进程会静默丢失，
//  而且不会报错，是最容易踩且最难查的坑，所以这里必须用 Darwin notify center。
//

import Foundation

// MARK: - 跨进程通知名

enum ScreenShareSignal {

    /// 共享状态发生变化（开始 / 暂停 / 恢复 / 结束）。
    static let stateChanged = "com.tianqiong.meetingkit.screenshare.stateChanged"

    /// 扩展写出了一帧新画面，主 App 可以去读文件了。
    static let frameUpdated = "com.tianqiong.meetingkit.screenshare.frameUpdated"

    /// 主 App 请求停止共享（方向：主 App → 扩展）。
    /// 主 App 无法直接结束扩展进程，只能发出请求由扩展自己调用 finishBroadcastWithError。
    static let stopRequested = "com.tianqiong.meetingkit.screenshare.stopRequested"
}

// MARK: - 共享状态

enum ScreenShareState: String {
    case idle
    case active
    case paused
}

// MARK: - 状态存取

/// 共享状态存取。
///
/// ── 为什么从 UserDefaults 换成文件 ─────────────────────────────────────
/// 上一版把 state / startedAt / heartbeat 写在 `UserDefaults(suiteName:)` 里，
/// 结果在真机上出现"系统已经在录屏（状态栏红点），App 里却一直显示未共享"。
///
/// 根因是 cfprefsd 的跨进程可见性：每个进程各自持有一份 domain 缓存，
/// 写入方不保证立刻广播，读取方也没有"强制重读"的公开接口。表现就是
/// 扩展明明写了 .active，主 App 每 2 秒读一次却永远读到旧的 .idle，
/// 于是 `beginScreenFramePush()` 从不执行——一帧都不会上行，对方当然黑屏。
///
/// 换成共享容器里的一个小 JSON 文件后，读侧每次 `Data(contentsOf:)` 都是
/// 直接问文件系统，不存在缓存层；写侧用 `.atomic`（临时文件 + rename），
/// 读侧只会看到完整的旧版本或完整的新版本，不会读到半个 JSON。
///
/// 文件只有几百字节，每秒读一次的成本可以忽略。
enum ScreenShareStore {

    // MARK: 数据模型

    /// 一次共享的完整状态。所有时间戳统一用 `timeIntervalSince1970`，
    /// 避免 `Date` 编解码在不同进程/不同系统版本上出现精度或时区差异。
    struct Snapshot: Codable, Equatable {
        var state: String = ScreenShareState.idle.rawValue
        var startedAt: Double?
        var heartbeat: Double?
        /// 扩展侧最后一次失败的原因（App Group 不可用、编码器起不来等）。
        /// 主 App 读到后直接展示给用户——否则这类失败在真机上完全不可观测。
        var lastError: String?
        var errorAt: Double?
    }

    private static let fileName = "screen-share-state.json"

    /// 写串行化：扩展侧在广播开始/心跳/结束时都会写，避免两次写交叉。
    private static let writeQueue = DispatchQueue(
        label: "com.tianqiong.meetingkit.sharestore",
        qos: .userInitiated
    )

    // MARK: 路径

    static func fileURL() -> URL? {
        AppGroupConfig.containerURL()?.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: 读写

    /// 读当前快照。容器不可用 / 文件不存在 / 内容损坏一律返回 nil，
    /// 由调用方按 `.idle` 兜底——这条路径必须绝不抛错、绝不崩。
    static func snapshot() -> Snapshot? {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty,
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            return legacySnapshot()
        }
        return decoded
    }

    /// 写快照（原子替换）。失败静默：共享画面丢一次状态不该中断广播。
    private static func write(_ snapshot: Snapshot) {
        writeQueue.sync {
            guard let url = fileURL() else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 读-改-写。所有 setter 都走这里，避免"改一个字段把别的字段覆盖回旧值"。
    private static func mutate(_ body: (inout Snapshot) -> Void) {
        var current = snapshot() ?? Snapshot()
        body(&current)
        write(current)
    }

    // MARK: 对外属性

    /// 当前共享状态。读不到或值非法时按 `.idle` 兜底。
    static var state: ScreenShareState {
        get {
            guard let raw = snapshot()?.state,
                  let value = ScreenShareState(rawValue: raw) else {
                return .idle
            }
            return value
        }
        set {
            mutate { $0.state = newValue.rawValue }
        }
    }

    /// 本次共享的开始时间，用于主 App 显示计时。结束共享时置 nil。
    static var startedAt: Date? {
        get {
            guard let raw = snapshot()?.startedAt else { return nil }
            return Date(timeIntervalSince1970: raw)
        }
        set {
            mutate { $0.startedAt = newValue?.timeIntervalSince1970 }
        }
    }

    /// 扩展进程的心跳时间，主 App 用它判断"广播是否还活着"。
    ///
    /// 为什么用心跳而不是"有没有新帧"：ReplayKit 在画面静止（用户盯着文档不动、
    /// 只在说话）时会降低甚至暂停采样回调，此时扩展进程完全健康却一个 JPEG 都不出。
    /// 用"多久没收到帧"判活，会把一场正常广播误杀成"已中断"。
    /// 心跳由扩展在每次收到 `.video` 采样时刷新（扩展侧已节流到 2 秒一次），
    /// 只要系统还在回调它，心跳就会持续更新，与画面有没有变化无关。
    static var heartbeat: Date? {
        get {
            guard let raw = snapshot()?.heartbeat else { return nil }
            return Date(timeIntervalSince1970: raw)
        }
        set {
            mutate { $0.heartbeat = newValue?.timeIntervalSince1970 }
        }
    }

    /// 扩展侧上报的失败原因。读走快照，写由扩展调用 `recordError`。
    static var lastError: String? {
        snapshot()?.lastError
    }

    // MARK: 便捷操作

    /// 刷新心跳为当前时间。只应由广播扩展调用（主 App 若也写，就失去了判活意义）。
    static func touchHeartbeat() {
        mutate { $0.heartbeat = Date().timeIntervalSince1970 }
    }

    /// 记录一次失败。必须在 `finishBroadcastWithError` **之前**调用：
    /// 扩展进程随后就会被系统回收，晚一步写就永远写不进去。
    static func recordError(_ message: String) {
        mutate {
            $0.lastError = message
            $0.errorAt = Date().timeIntervalSince1970
        }
    }

    /// 清掉失败记录（新一次广播开始时）。
    static func clearError() {
        mutate {
            $0.lastError = nil
            $0.errorAt = nil
        }
    }

    /// 回到干净状态。扩展结束广播时必须调用，否则下次进入会议会误显示"正在共享"。
    static func reset() {
        let previous = snapshot()
        var fresh = Snapshot()
        // 失败原因要保留：扩展结束的同一刻主 App 可能正要展示它。
        fresh.lastError = previous?.lastError
        fresh.errorAt = previous?.errorAt
        write(fresh)
    }

    // MARK: 旧版兜底

    /// 旧版本（1.3.0 及以前）把状态写在 UserDefaults 里。
    /// 保留只读兜底：升级后第一次进会时文件还没生成，能读到旧值就不会闪一下"未共享"。
    private static func legacySnapshot() -> Snapshot? {
        guard let defaults = AppGroupConfig.sharedDefaults(),
              let raw = defaults.string(forKey: "screenShare.state") else {
            return nil
        }
        var legacy = Snapshot()
        legacy.state = raw
        if let started = defaults.object(forKey: "screenShare.startedAt") as? Date {
            legacy.startedAt = started.timeIntervalSince1970
        }
        if let beat = defaults.object(forKey: "screenShare.heartbeat") as? Date {
            legacy.heartbeat = beat.timeIntervalSince1970
        }
        return legacy
    }
}

// MARK: - 运行期统计

/// 主 App 进程内的共享运行统计，只服务于"共享诊断"面板。
///
/// 为什么要这个东西：共享链路横跨两个进程（扩展 → 文件 → 主 App → WebRTC），
/// 中间任何一段断掉，用户看到的都只是"对方黑屏"这同一个现象。
/// 没有分阶段计数时只能靠猜；有了它，一眼就能看出是"没帧"还是"没推"。
enum ScreenShareRuntime {

    private static let lock = NSLock()
    private static var _framesWritten = 0
    private static var _framesPushed = 0
    private static var _lastPushAt: Double?

    /// 扩展写出过多少帧（由主 App 读到新帧时累加）。
    static var framesWritten: Int {
        lock.lock(); defer { lock.unlock() }
        return _framesWritten
    }

    /// 主 App 成功推给 WebRTC 多少帧。
    static var framesPushed: Int {
        lock.lock(); defer { lock.unlock() }
        return _framesPushed
    }

    static var lastPushAt: Date? {
        lock.lock(); defer { lock.unlock() }
        guard let raw = _lastPushAt else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    static func noteFrameWritten() {
        lock.lock(); _framesWritten += 1; lock.unlock()
    }

    static func noteFramePushed() {
        lock.lock()
        _framesPushed += 1
        _lastPushAt = Date().timeIntervalSince1970
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        _framesWritten = 0
        _framesPushed = 0
        _lastPushAt = nil
        lock.unlock()
    }
}

// MARK: - Darwin 通知收发

enum DarwinNotifier {

    /// 观察者注册表。
    ///
    /// 为什么需要这个类：`CFNotificationCenterAddObserver` 只能传 C 函数指针，
    /// C 函数没有捕获上下文，拿不到 Swift 闭包。业界通行做法是准备一个稳定的裸指针，
    /// 在回调里用它把注册表找回来，再按通知名查 handler。
    private final class Registry: @unchecked Sendable {
        static let shared = Registry()

        let lock = NSLock()
        /// 通知名 → (注册序号 → 回调)
        var handlers: [String: [UUID: () -> Void]] = [:]
        /// 已经向 CFNotificationCenter 注册过 C 回调的通知名，避免重复注册。
        var registeredNames: Set<String> = []
    }

    /// 传给 CFNotificationCenter 的稳定指针。Registry.shared 是常驻单例，
    /// 生命周期覆盖整个进程，所以这个指针永远有效。
    private static var registryPointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(Registry.shared).toOpaque()
    }

    /// 全局唯一的 C 回调。函数体里不能捕获任何上下文，只能通过 observer 指针找回 Registry。
    private static let callback: CFNotificationCallback = { _, observer, name, _, _ in
        guard let observer = observer, let name = name else { return }
        let registry = Unmanaged<Registry>.fromOpaque(observer).takeUnretainedValue()
        let key = name.rawValue as String

        registry.lock.lock()
        // 先取快照再放锁：回调里可能又去 add/remove 观察者，持锁执行业务代码会死锁。
        let snapshot = registry.handlers[key].map { Array($0.values) } ?? []
        registry.lock.unlock()

        guard !snapshot.isEmpty else { return }

        // Darwin 回调跑在 notify(3) 自己的线程上，不是主线程；
        // UI 侧的状态更新统一在这里切回主线程，业务侧不必再关心线程。
        DispatchQueue.main.async {
            snapshot.forEach { $0() }
        }
    }

    /// 发出一个 Darwin 通知。本身不携带负载，接收方需要数据时自己去 App Group 读。
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    /// 注册观察者。返回的 token 必须保存好，并在 deinit / 退出时交给 removeObserver，
    /// 否则同一条通知会被重复处理。
    static func addObserver(_ name: String, handler: @escaping () -> Void) -> NSObjectProtocol {
        let observation = ObservationToken(name: name)
        let registry = Registry.shared

        registry.lock.lock()
        registry.handlers[name, default: [:]][observation.id] = handler
        // 同一个通知名只往 CFNotificationCenter 注册一次 C 回调，多个 Swift handler 共用它。
        let needsRegistration = registry.registeredNames.insert(name).inserted
        registry.lock.unlock()

        if needsRegistration {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                registryPointer,
                callback,
                name as CFString,
                nil,
                .deliverImmediately
            )
        }

        return observation
    }

    /// 移除观察者。只有该通知名下最后一个 handler 被移除时，才撤销 C 回调注册，
    /// 避免提前注销导致其它同学的 handler 收不到通知。
    static func removeObserver(_ token: NSObjectProtocol) {
        guard let observation = token as? ObservationToken else { return }
        let registry = Registry.shared

        registry.lock.lock()

        var needsUnregistration = false
        if var bucket = registry.handlers[observation.name] {
            bucket.removeValue(forKey: observation.id)

            if bucket.isEmpty {
                // 该通知名已无人监听：整条记录连同 C 回调注册一起撤掉。
                registry.handlers.removeValue(forKey: observation.name)
                needsUnregistration = registry.registeredNames.remove(observation.name) != nil
            } else {
                registry.handlers[observation.name] = bucket
            }
        }

        registry.lock.unlock()

        if needsUnregistration {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                registryPointer,
                CFNotificationName(observation.name as CFString),
                nil
            )
        }
    }

    /// addObserver 的返回值本体：只有它自己知道该摘掉"哪一条"注册。
    /// 对外只暴露 NSObjectProtocol，外部无法伪造或复用。
    private final class ObservationToken: NSObject {
        let id = UUID()
        let name: String

        init(name: String) {
            self.name = name
        }
    }
}
