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

        // MARK: 1.5.4 会话握手

        /// 主 App 点"开始共享"时写入的请求时间。
        ///
        /// 它解决的是"旧帧冒充新帧"：容器里可能躺着上一场共享的 JPEG，
        /// 主 App 一读 mtime 就以为扩展正在出帧，诊断里出现"出帧 46 帧、
        /// 已推 299 帧"但扩展其实是 idle。只有 mtime ≥ requestedAt 的帧
        /// 才属于本次会话。
        var requestedAt: Double?

        /// 扩展进程实际解析到的 App Group。
        ///
        /// 这是 1.5.4 的关键自检：主 App 与扩展各自从签名里探测 group，
        /// 只要两边名字不一致，扩展写多少帧主 App 都看不到。把它写进
        /// 共享状态，诊断面板就能直接指出"App 组 ≠ 扩展组"。
        var appGroup: String?

        /// 扩展侧累计出帧数（每 2 秒随心跳写一次）。
        /// 与主 App 自己读到的新帧数分开：前者证明"扩展在编码"，
        /// 后者证明"主 App 读到了"，两段链路可以分别定位。
        var frameSeq: Int?

        /// 扩展侧最后一帧的写入时间。
        var lastFrameAt: Double?

        /// 扩展的 CFBundleShortVersionString（用于确认设备上跑的是新包）。
        var extensionVersion: String?
    }

    private static let fileName = "screen-share-state.json"

    /// 写串行化：扩展侧在广播开始/心跳/结束时都会写，避免两次写交叉。
    /// 同时挂一个队列标记：读改写已经在这条队列里时不再 sync，否则必死锁。
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private static let writeQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.tianqiong.meetingkit.sharestore",
            qos: .userInitiated
        )
        queue.setSpecific(key: queueKey, value: 1)
        return queue
    }()

    private static var isOnWriteQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) == 1
    }

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
        if isOnWriteQueue {
            writeOnQueue(snapshot)
        } else {
            writeQueue.sync { writeOnQueue(snapshot) }
        }
    }

    /// 仅在 writeQueue 内调用，避免嵌套 sync 死锁。
    private static func writeOnQueue(_ snapshot: Snapshot) {
        guard let url = fileURL(),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 读取也必须在队列内：否则心跳会用旧快照覆盖刚写入的 paused/active。
    /// 此队列只保证同进程串行，不等同于主 App 与扩展之间的跨进程锁。
    private static func mutate(_ body: (inout Snapshot) -> Void) {
        if isOnWriteQueue {
            var current = snapshot() ?? Snapshot()
            body(&current)
            writeOnQueue(current)
            return
        }
        writeQueue.sync {
            var current = snapshot() ?? Snapshot()
            body(&current)
            writeOnQueue(current)
        }
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

    /// 本次共享的请求时间（主 App 在弹系统面板前写入）。
    static var requestedAt: Date? {
        guard let raw = snapshot()?.requestedAt else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    /// 本次会话的帧新鲜度下界。
    ///
    /// 优先用 requestedAt（用户在本次点"开始共享"的时刻），
    /// 老版本状态没有这个字段时退回 startedAt。再往前放宽 2 秒，
    /// 避免两进程时钟读数与文件系统 mtime 的毫秒级抖动误杀第一帧。
    static var sessionFloor: Date? {
        let current = snapshot()
        let raw = current?.requestedAt ?? current?.startedAt
        guard let raw = raw else { return nil }
        return Date(timeIntervalSince1970: raw - 2)
    }

    /// 主 App 点"开始共享"后、系统面板弹出前调用。
    ///
    /// 目的有三个：
    ///   1. 给本次会话打时间戳，旧帧不能再冒充新帧；
    ///   2. 清掉上一场的失败原因与组信息，诊断面板只反映本次；
    ///   3. 留下 requestedAt。即使用户在系统面板里点了取消，主 App
    ///      也能据此判断"请求过、但扩展没起来"，给出明确提示。
    static func prepareForNewSession() {
        var fresh = Snapshot()
        fresh.requestedAt = Date().timeIntervalSince1970
        // 旧错误不带到新会话：用户点共享是来解决问题的，
        // 不该先被上一场的报错吓一次。
        fresh.lastError = nil
        fresh.errorAt = nil
        write(fresh)
    }

    /// 扩展 `broadcastStarted` 时调用：一次写入完整会话头。
    ///
    /// 为什么不复用 state/startedAt 两个 setter：那样会读改写三次 JSON，
    /// 中间任何一次被系统杀掉都会留下半截状态。这里只写一次。
    static func beginSession(appGroup: String, extensionVersion: String?) {
        var current = snapshot() ?? Snapshot()
        let now = Date().timeIntervalSince1970

        current.state = ScreenShareState.active.rawValue
        current.startedAt = now
        current.heartbeat = now
        current.lastError = nil
        current.errorAt = nil
        current.appGroup = appGroup
        current.frameSeq = 0
        current.lastFrameAt = nil
        current.extensionVersion = extensionVersion
        // 主 App 没写 requestedAt（例如从控制中心直接起播）时，以启动时间为准。
        if current.requestedAt == nil {
            current.requestedAt = now
        }
        write(current)
    }

    /// 刷新心跳为当前时间。只应由广播扩展调用（主 App 若也写，就失去了判活意义）。
    /// - Parameter frames: 扩展侧累计出帧数；随心跳一起写，主 App 可分辨
    ///   "扩展没出帧"与"扩展出了帧但主 App 没读到"。
    static func touchHeartbeat(frames: Int? = nil) {
        let now = Date().timeIntervalSince1970
        mutate {
            $0.heartbeat = now
            if let frames = frames {
                $0.frameSeq = frames
                if frames > 0 {
                    $0.lastFrameAt = now
                }
            }
        }
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
        // requestedAt / appGroup / frameSeq 属于上一场会话，必须清掉。
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

/// 一次视频上行采样。
///
/// 为什么单列 `trackEnabled` / `sendsUpstream`：1.7.0 真机出现了
/// "出帧 119、发送 0 包、编码 0 帧、共享轨已挂"这一组互相矛盾的数字。
/// 根因就是"挂上"只说明 sender.track 指向共享轨，**不说明这条轨是开的**，
/// 也不说明 SDP 的 m-line 允许发送。少了这两项，诊断会把"轨被关掉"
/// 误报成"已经挂好"，排查方向直接被带偏。
struct ScreenVideoStats {
    var packetsSent = 0
    var framesEncoded = 0
    /// sender.track 是否就是本端的共享轨。
    var screenAttached = false
    /// 共享轨本身是否 enabled。false = 帧推到 source 也被丢弃，永远进不了编码器。
    var trackEnabled = false
    /// 本地 SDP 里视频 m-line 的方向是否允许发送（sendrecv / sendonly）。
    var sendsUpstream = true
    /// 采样时连着的 peer 数。0 表示根本没采样，不要把它当成"没发包"。
    var senders = 0
    /// 最近一次采样时间。nil 表示看门狗还没跑过——此时"共享轨已挂"是**没有依据**的，
    /// 诊断必须显示"尚未采样"，而不是拿默认值冒充结论。
    var sampledAt: Date?
    /// 共享这条流上一采样周期的实际上行码率（bps）。
    /// 糊不糊最终由它决定：880x1920 低于 1.5Mbps 必然糊，跟分辨率设置无关。
    var bitrateBps = 0
    /// 摄像头那条流的实际上行码率。它和共享共用同一条连接的带宽预算，
    /// 摄像头偷偷占 2Mbps 时，共享就只能糊。
    var cameraBitrateBps = 0
    /// 编码器这一路自己的目标码率（bps）。这是 GCC 实际拨给编码器的数字，
    /// 比我们在 parameters 里写的上限更能说明"允许发多少"。
    /// 上限 8Mbps、目标 300kbps，就是"带宽不够"，不是"参数没设对"。
    var targetBitrateBps = 0
    /// WebRTC 自己给出的受限原因：bandwidth / cpu / other / none。
    /// 这是"糊"的判决书：bandwidth 要加带宽，cpu 要降分辨率或降帧，
    /// 两者都没有还糊，才是画布或缩放的问题。
    var qualityReason = ""
    /// 候选对的可用上行估计（bps）。走 TURN 中继时它通常远低于物理上行，
    /// 是被中继服务器卡住的，不是手机的问题。
    var availableOutgoingBps = 0
    /// 候选对的往返时延（毫秒）。
    var rttMs = 0
    /// 本端 / 远端候选类型：host / srflx / prflx / relay。
    /// relay = 流量过 TURN，带宽与延迟都由中继服务器决定。
    var localCandidate = ""
    var remoteCandidate = ""
    /// 编码器自己的现场，一行文本：`impl=libvpx key=0 sent=0 0x0 重传=0`。
    ///
    /// 这是「帧推进去了但 framesEncoded 恒为 0」唯一能定性的证据：
    ///   · impl 为空 —— 编码器根本没建起来（sender/source 没接上）
    ///   · impl 有值、key=0、帧尺寸 0x0 —— 帧没进到编码器
    ///   · impl 有值、key=0、帧尺寸正常 —— VideoToolbox 每一帧都拒绝
    var encoderFacts = ""

    var sampled: Bool { sampledAt != nil }
}

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

    // 1.5.4：RTP 视频上行统计。用来区分"帧没进编码器"与"编码了但没发出去"。
    private static var _video = ScreenVideoStats()

    // 1.7.1：本进程直采（SCK / in-app）的帧计数。
    // 这是"共享真的在出帧"唯一的独立证据：它由采集侧写入，
    // 不依赖 ViewModel 的状态机，也不依赖任何跨进程文件。
    private static var _nativeFrames = 0
    private static var _nativeLastAt: Double?

    /// 1.9.1：直接挂在 `localScreenTrack` 上的回环接收器数到的帧数。
    ///
    /// 它回答的是一个此前没法回答的问题：**帧到底有没有进"这条轨"**。
    /// 采集侧计数（`_nativeFrames`）只证明 `RTCVideoSource.capturer` 被调用了，
    /// 不证明被推的那个 source 就是 sender 正在消费的那条轨的 source。
    /// 两者一旦不是同一个对象，现场就是：
    ///   已推 164 帧 · 轨开 · mid/ssrc/编码器全在 · framesEncoded=0 · 0x0。
    /// 有回环计数以后：
    ///   镜像 > 0 而编码 = 0 → 断在"轨 → sender"，重挂 sender 的轨即可；
    ///   镜像 = 0            → 断在"source → 轨"，推错了 source。
    private static var _loopbackFrames = 0

    static var loopbackFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return _loopbackFrames
    }

    static func noteLoopbackFrame() {
        lock.lock()
        _loopbackFrames += 1
        lock.unlock()
    }

    static func resetLoopbackFrames() {
        lock.lock()
        _loopbackFrames = 0
        lock.unlock()
    }

    /// 自愈动作的流水账。共享链路上每一次"发现不对、动手修"都记一行：
    /// 真机复验时这几行比任何状态码都直接——它告诉你哪条兜底被触发了。
    private static var _notes: [String] = []

    /// 上行守护强制指定的画布。
    ///
    /// 背景：帧按 880x1920 推进 RTCVideoSource，采集侧计数在涨，
    /// 而 outbound-rtp 的 framesEncoded / packetsSent 恒为 0。
    /// 已经排除的：track.isEnabled（libwebrtc 的发送链路绑的是
    /// `track->GetSource()`，不读 enabled 位）、sender 没有 encoding、
    /// m-line 方向、ICE。剩下的高频嫌疑是编码器按这个尺寸每帧都被
    /// VideoToolbox 拒绝——硬件编码器对宏块数/level 有硬门槛，
    /// 拒绝时不报错，只让 framesEncoded 永远停在 0。
    ///
    /// 所以这里留一个"强制降画布"的开关：守门狗判定零产出就往下调一档，
    /// 调了能出帧就说明是尺寸问题，调了还不出就是编码器本身建不起来。
    /// 非 nil 时采集侧不再按源比例自己算画布。
    private static var _forcedCanvas: (width: Int, height: Int)?

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

    /// 最近一次采样到的视频 RTP 计数。
    /// `sampled` 为 false 时其余字段没有意义，UI 不应把 `screenAttached` 当成结论。
    static var videoStats: ScreenVideoStats {
        lock.lock(); defer { lock.unlock() }
        return _video
    }

    /// 最近一次采样的时刻。
    static var videoStatsAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _video.sampledAt
    }

    /// 本进程直采累计推了多少帧，以及最后一帧的时刻。
    /// 上行守护用它判断"帧到底有没有在进 RTC"。
    static var nativeFrameStats: (count: Int, lastAt: Date?) {
        lock.lock(); defer { lock.unlock() }
        return (_nativeFrames, _nativeLastAt.map { Date(timeIntervalSince1970: $0) })
    }

    /// 当前被守护强制的画布。nil = 按源比例自动算。
    static var forcedCanvas: (width: Int, height: Int)? {
        lock.lock(); defer { lock.unlock() }
        return _forcedCanvas
    }

    /// 强制一个画布。宽高必须已按 16 对齐（H.264 宏块是 16x16）。
    static func forceCanvas(width: Int, height: Int) {
        lock.lock()
        _forcedCanvas = (width, height)
        lock.unlock()
    }

    static func clearForcedCanvas() {
        lock.lock()
        _forcedCanvas = nil
        lock.unlock()
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

    /// SCK / in-app 每真正推进一帧就记一次。
    ///
    /// 放在采集侧而不是 RTC 侧：这是"源真的有画面"的原始信号。
    /// 只要它在涨、而编码器是 0，问题就一定在 track / sender 这一段，
    /// 不用再去猜系统面板有没有选中内容。
    static func noteNativeFrame() {
        lock.lock()
        _nativeFrames += 1
        _nativeLastAt = Date().timeIntervalSince1970
        lock.unlock()
    }

    /// 记一条自愈动作。只保留最近 6 条，避免诊断面板被历史噪音撑爆。
    static func note(_ text: String) {
        lock.lock()
        if !_notes.contains(text) {
            _notes.append(text)
            if _notes.count > 6 { _notes.removeFirst() }
        }
        lock.unlock()
    }

    /// 自愈流水账，诊断面板原样展示。
    static var notesText: String {
        lock.lock(); defer { lock.unlock() }
        return _notes.joined(separator: " · ")
    }

    /// 由共享看门狗写入。
    static func noteVideoStats(
        packetsSent: Int,
        framesEncoded: Int,
        screenAttached: Bool,
        trackEnabled: Bool = false,
        sendsUpstream: Bool = true,
        senders: Int = 0,
        bitrateBps: Int = 0,
        cameraBitrateBps: Int = 0,
        targetBitrateBps: Int = 0,
        qualityReason: String = "",
        availableOutgoingBps: Int = 0,
        rttMs: Int = 0,
        localCandidate: String = "",
        remoteCandidate: String = "",
        encoderFacts: String = ""
    ) {
        lock.lock()
        _video.packetsSent = packetsSent
        _video.framesEncoded = framesEncoded
        _video.screenAttached = screenAttached
        _video.trackEnabled = trackEnabled
        _video.sendsUpstream = sendsUpstream
        _video.senders = senders
        _video.bitrateBps = bitrateBps
        _video.cameraBitrateBps = cameraBitrateBps
        _video.targetBitrateBps = targetBitrateBps
        _video.qualityReason = qualityReason
        _video.availableOutgoingBps = availableOutgoingBps
        _video.rttMs = rttMs
        _video.localCandidate = localCandidate
        _video.remoteCandidate = remoteCandidate
        _video.encoderFacts = encoderFacts
        _video.sampledAt = Date()
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        _forcedCanvas = nil
        _framesWritten = 0
        _framesPushed = 0
        _lastPushAt = nil
        _video = ScreenVideoStats()
        _nativeFrames = 0
        _nativeLastAt = nil
        _loopbackFrames = 0
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
