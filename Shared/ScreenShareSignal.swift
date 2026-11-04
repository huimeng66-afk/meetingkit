//
//  ScreenShareSignal.swift
//  Shared
//
//  屏幕共享的跨进程通信层。两个进程（主 App / 广播扩展）之间的全部交互只有三类：
//    1. 状态：ScreenShareStore 读写 App Group UserDefaults（可回读、有持久语义）
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
    static let stateChanged = "com.example.meetingkit.screenshare.stateChanged"

    /// 扩展写出了一帧新画面，主 App 可以去读文件了。
    static let frameUpdated = "com.example.meetingkit.screenshare.frameUpdated"

    /// 主 App 请求停止共享（方向：主 App → 扩展）。
    /// 主 App 无法直接结束扩展进程，只能发出请求由扩展自己调用 finishBroadcastWithError。
    static let stopRequested = "com.example.meetingkit.screenshare.stopRequested"
}

// MARK: - 共享状态

enum ScreenShareState: String {
    case idle
    case active
    case paused
}

// MARK: - 状态存取

/// 基于 App Group UserDefaults 的状态存取。
///
/// 为什么状态放 UserDefaults 而帧放文件：状态只有几个标量，UserDefaults 已经由
/// cfprefsd 处理了跨进程同步与原子写；帧数据体积大且高频，走文件更合适。
enum ScreenShareStore {

    private static let stateKey = "screenShare.state"
    private static let startedAtKey = "screenShare.startedAt"
    private static let heartbeatKey = "screenShare.heartbeat"

    /// 当前共享状态。读不到或值非法时按 `.idle` 兜底，绝不让调用方处理可选值。
    static var state: ScreenShareState {
        get {
            guard let raw = AppGroupConfig.sharedDefaults()?.string(forKey: stateKey),
                  let value = ScreenShareState(rawValue: raw) else {
                return .idle
            }
            return value
        }
        set {
            AppGroupConfig.sharedDefaults()?.set(newValue.rawValue, forKey: stateKey)
        }
    }

    /// 本次共享的开始时间，用于主 App 显示计时。结束共享时置 nil。
    static var startedAt: Date? {
        get {
            AppGroupConfig.sharedDefaults()?.object(forKey: startedAtKey) as? Date
        }
        set {
            guard let defaults = AppGroupConfig.sharedDefaults() else { return }
            if let value = newValue {
                defaults.set(value, forKey: startedAtKey)
            } else {
                defaults.removeObject(forKey: startedAtKey)
            }
        }
    }

    /// 扩展进程的心跳时间，主 App 用它判断"广播是否还活着"。
    ///
    /// 为什么用心跳而不是"有没有新帧"：ReplayKit 在画面静止（用户盯着文档不动、
    /// 只在说话）时会降低甚至暂停采样回调，此时扩展进程完全健康却一个 JPEG 都不出。
    /// 用"多久没收到帧"判活，会把一场正常广播误杀成"已中断"，用户看到的是
    /// "扩展还在推流、App 里却停不掉"这种自相矛盾的状态（H-1）。
    /// 心跳由扩展在每次收到 `.video` 采样时刷新（扩展侧已节流到 2 秒一次），
    /// 只要系统还在回调它，心跳就会持续更新，与画面有没有变化无关。
    static var heartbeat: Date? {
        get {
            AppGroupConfig.sharedDefaults()?.object(forKey: heartbeatKey) as? Date
        }
        set {
            guard let defaults = AppGroupConfig.sharedDefaults() else { return }
            if let value = newValue {
                defaults.set(value, forKey: heartbeatKey)
            } else {
                defaults.removeObject(forKey: heartbeatKey)
            }
        }
    }

    /// 刷新心跳为当前时间。只应由广播扩展调用（主 App 若也写，就失去了判活意义）。
    static func touchHeartbeat() {
        heartbeat = Date()
    }

    /// 回到干净状态。扩展结束广播时必须调用，否则下次进入会议会误显示"正在共享"。
    static func reset() {
        state = .idle
        startedAt = nil
        // 心跳必须一起清：残留的旧心跳会让主 App 在下一场广播的头几秒里
        // 拿着上一场的时间戳判活，既可能误杀也可能误活。
        heartbeat = nil
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
                CFNotificationName(name as CFString),
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
