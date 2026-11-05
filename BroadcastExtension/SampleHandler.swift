//
//  SampleHandler.swift
//  MeetingBroadcast
//
//  ReplayKit 广播上传扩展的入口。
//
//  ── 跨进程时序（全链路）────────────────────────────────────────────────
//   1. 主 App 内点击 RPSystemBroadcastPickerView → 系统拉起本扩展（独立进程）
//   2. 系统回调 broadcastStarted → 先清旧帧，再写 ScreenShareStore(.active)
//      → 写本次会话的 appGroup / startedAt → post stateChanged
//   3. 系统高频回调 processSampleBuffer → 节流到 24fps → 短边缩到 1080
//      → CIContext 直接编码 JPEG → 写入 App Group 容器 → post frameUpdated
//      心跳由独立 DispatchSourceTimer 每 2 秒刷新，**不依赖采样回调**：
//      ReplayKit 在画面静止时会降低甚至停发 sample，只靠 .video 刷心跳
//      会让主 App 把一场正常广播误判成"已中断"并清掉状态。
//   4. 主 App 的 ScreenShareBridge 收到 frameUpdated → 读文件 → 预览
//   5. 主 App 点"停止共享" → post stopRequested → 本扩展先置 isStopping、
//      清状态/清帧/移除观察者，再 finishBroadcastWithError
//
//  ── 1.5.4 的两个真机修复 ────────────────────────────────────────────
//   · App Group：扩展的 Bundle.main 是 .appex，重签后的 profile 往往只在
//     主 App 根目录。AppGroupConfig 现在会往上两级找，并用代码签名
//     entitlements 兜底；实际用到的 group 会写进共享状态，主 App 可对比。
//   · 内存：不再 CGImage → UIImage → Data 三份大对象，
//     改用 CIContext.jpegRepresentation 一步出 JPEG，峰值内存显著下降。
//     广播扩展常驻内存上限约 50MB，超限会被 jetsam 静默杀掉。
//

import UIKit
import CoreVideo
import CoreMedia
import CoreImage
import ImageIO
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {

    // MARK: - 常量

    /// 目标 24fps。共享的是文档、代码、演示稿：20fps 滚动时文字会"拖影"，
    /// 观感就是"卡"；24 是跨进程落盘还能跟上的上限（1080p 每帧约 210~300KB）。
    private static let frameInterval: CFTimeInterval = 1.0 / 24.0

    /// 心跳写入间隔。主 App 的心跳超时是 12 秒，2 秒一次留了 6 次容错。
    private static let heartbeatInterval: CFTimeInterval = 2

    /// 输出短边上限。短边缩到 1080 即等价 1080p：
    /// 横屏（手机横放）输出 1920×1080，竖屏输出 1080×1920，文字边缘不再糊成一团。
    private static let maxPixelEdge: CGFloat = 1080

    /// 0.78：文档类画面的关键是文字边缘。
    /// 0.7 在 1080p 下已经能看到笔画发虚，再经 H.264 二次压缩就是"糊"；
    /// 0.78 的可读性提升很明显，体积只涨约 15%（每帧 210~300KB）。
    private static let jpegQuality: CGFloat = 0.78

    /// 自定义错误域，主 App 可据此区分"用户主动停止"与系统异常中断。
    private static let stopErrorDomain = "com.tianqiong.meetingkit.broadcast"

    // MARK: - 属性

    /// CIContext 的初始化成本很高（GPU 资源 + kernel 编译），必须作为属性复用。
    /// `cacheIntermediates: false` 是扩展的内存保命项：默认会缓存中间纹理，
    /// 1080p 24fps 下很快逼近 50MB 上限。
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,
    ])

    /// 编码专用串行队列：缩放、JPEG 编码、落盘全部在这里做，绝不占用采样回调。
    private let encodeQueue = DispatchQueue(
        label: "com.tianqiong.meetingkit.broadcast.encode",
        qos: .userInitiated
    )

    /// 心跳专用队列。与编码解耦：编码卡住时心跳仍要按时写。
    private let heartbeatQueue = DispatchQueue(
        label: "com.tianqiong.meetingkit.broadcast.heartbeat",
        qos: .utility
    )

    /// 防重入标记。采样回调和编码队列不在同一线程，所以用锁保护，
    /// 保证同一时刻最多有一帧在编码，避免多帧堆积把内存顶爆。
    private let encodeLock = NSLock()
    private var isEncoding = false

    /// 出帧计数 / 停止标记共用一把锁。
    ///
    /// 停止时必须和"写帧"互斥：否则收尾的 clear() 跑完，编码队列里
    /// 最后一帧又落盘，主 App 下次打开共享面板就会把这张旧图当成新帧
    /// （1.5.3 诊断里的"出帧 46 帧（75 KB）"就是这么来的）。
    private let stateLock = NSLock()
    private var frameCount = 0
    private var stopping = false

    /// 上一次接受帧的时间戳（CACurrentMediaTime，单调递增，不受系统时间调整影响）。
    private var lastFrameTime: CFTimeInterval = 0

    /// 上一次写心跳的时间戳。采样回调仍会按自己的节奏补心跳，
    /// 但真正的判活由 heartbeatTimer 保证。
    private var lastHeartbeatTime: CFTimeInterval = 0

    /// 独立心跳定时器。ReplayKit 在画面静止时可能停发 .video 采样，
    /// 没有它，主 App 的 12 秒存活检测会把健康广播误杀。
    private var heartbeatTimer: DispatchSourceTimer?

    /// stopRequested 的观察者 token，结束广播时必须摘掉。
    private var stopObserver: NSObjectProtocol?

    // MARK: - 生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 第一道也是最后一道防线：扩展与主 App 之间**只有** App Group 这一条通道。
        // 证书没授权任何 group 时（免费 Apple ID 自签、部分代签工具剥离 entitlements），
        // 扩展照样能起播、照样在录屏，但一帧都写不出去，用户看到的是"共享中 + 对面黑屏"。
        // 与其让用户对着黑屏等到自己发现，不如在这里按系统规范立刻结束并给出原因。
        guard AppGroupConfig.isAvailable else {
            // 先把原因落盘再结束：主 App 读不到这条记录时，用户只能看到
            // "共享莫名其妙中断"，没有任何可排查的线索。
            ScreenShareStore.recordError("扩展未获得 App Group（\(AppGroupConfig.identifier)），共享画面无法传回会议")
            let error = NSError(
                domain: Self.stopErrorDomain,
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "当前签名没有把 App Group（\(AppGroupConfig.identifier)）授予屏幕共享扩展。请用同时包含主 App 与扩展的完整签名重新安装，或先用网页版共享屏幕。"
                ]
            )
            finishBroadcastWithError(error)
            return
        }

        // 每次广播都当作一次全新会话：重置节流、重入、停止标记与出帧计数。
        resetForNewSession()

        /* 先清旧帧，再写会话头。
           顺序反了的话，主 App 可能在新会话开始的一瞬间读到上一场的残留帧，
           把"已结束的共享"重新点亮。 */
        SharedFrameStore.clear()
        ScreenShareStore.beginSession(
            appGroup: AppGroupConfig.identifier,
            extensionVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        lastHeartbeatTime = CACurrentMediaTime()
        DarwinNotifier.post(ScreenShareSignal.stateChanged)

        startHeartbeatTimer()

        // 主 App 想结束共享时没有别的通道可用：它无法直接杀掉扩展进程，
        // 只能发 Darwin 通知，由扩展自己调 finishBroadcastWithError 走系统正常结束流程。
        stopObserver = DarwinNotifier.addObserver(ScreenShareSignal.stopRequested) { [weak self] in
            self?.finishBroadcastBecauseUserStopped()
        }
    }

    override func broadcastPaused() {
        ScreenShareStore.state = .paused
        DarwinNotifier.post(ScreenShareSignal.stateChanged)
    }

    override func broadcastResumed() {
        ScreenShareStore.state = .active
        // 暂停期间系统不一定继续回调采样；恢复的瞬间先补一次，
        // 否则主 App 可能在首个新采样到达之前就拿着旧心跳判死。
        ScreenShareStore.touchHeartbeat(frames: currentFrameCount)
        lastHeartbeatTime = CACurrentMediaTime()
        DarwinNotifier.post(ScreenShareSignal.stateChanged)
    }

    override func broadcastFinished() {
        // 先置停止标记：编码队列里尚未落盘的那一帧会被 commitFrame 拒绝。
        markStopping()
        stopHeartbeatTimer()
        removeStopObserver()
        resetEncodingState()

        ScreenShareStore.reset()
        SharedFrameStore.clear()
        DarwinNotifier.post(ScreenShareSignal.stateChanged)
    }

    // MARK: - 采样

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            // 采样到达时顺手补一次心跳（比定时器更及时）；
            // 画面静止时没有采样，定时器仍然每 2 秒续命。
            touchHeartbeatIfNeeded()
            handleVideoSampleBuffer(sampleBuffer)

        case .audioApp, .audioMic:
            /* 共享内的 App 声音（audioApp）当前不上行，这是能力边界，不是漏写：
               官方 WebRTC iOS SDK 的 RTCAudioSource 只有 volume 属性，
               没有喂 PCM 的公开接口（buffer / capture 都不存在），
               ReplayKit 的 audioApp 采样无法送进编码器。
               要支持"共享视频带声音"，只能换自编译 WebRTC + 自定义
               AudioDeviceModule，属于换 SDK，不是打补丁。

               audioMic 更不能在这里采：主 App 的麦克风已经在采，
               这里再采一份就是双份音轨 + 回声。 */
            break

        @unknown default:
            break
        }
    }

    // MARK: - 视频帧处理

    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        // 节流放在最前面：不满足帧间隔时连 pixelBuffer 都不取，开销最低。
        guard now - lastFrameTime >= Self.frameInterval else { return }
        guard beginEncoding() else { return }
        lastFrameTime = now

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            endEncoding()
            return
        }

        // ReplayKit 在 iOS 12+ 把画面方向放在 sample buffer 附件里：
        // 横屏共享时 pixelBuffer 可能仍是竖屏尺寸 + 旋转附件，
        // 不读它编码出的 JPEG 就是"躺着"的画面（主 App 侧无从纠正）。
        let orientation = orientation(of: sampleBuffer)

        // imageBuffer 的所有权属于 sampleBuffer，但 Swift 对 CVImageBuffer 做 ARC 管理，
        // 捕获进闭包时引用计数 +1，即使采样回调返回、sampleBuffer 被复用也不会野指针。
        encodeQueue.async { [weak self] in
            guard let self = self else { return }
            // autoreleasepool 是扩展的保命符：CoreGraphics / CoreImage 会往当前线程的
            // autorelease pool 里塞临时对象，不主动排空的话它们会攒到整帧结束才释放。
            autoreleasepool {
                self.encodeAndPublish(imageBuffer: imageBuffer, orientation: orientation)
                self.endEncoding()
            }
        }
    }

    /// 从 sample buffer 附件读取画面方向（RPVideoSampleOrientationKey）。
    private func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[CFString: Any]],
            let first = attachments.first,
            let rawValue = first[RPVideoSampleOrientationKey as CFString] as? UInt32
        else {
            return .up
        }
        return CGImagePropertyOrientation(rawValue: rawValue) ?? .up
    }

    /// 纠正方向、缩放到目标边长并发布 JPEG。只在 encodeQueue 上执行。
    private func encodeAndPublish(
        imageBuffer: CVImageBuffer,
        orientation: CGImagePropertyOrientation
    ) {
        var source = CIImage(cvPixelBuffer: imageBuffer)
        // 先摆正方向再缩放：oriented 的数学变换基于未旋转的 extent，顺序反了会算出负坐标。
        if orientation != .up {
            source = source.oriented(orientation)
        }
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let scaled: CIImage
        let shortEdge = min(extent.width, extent.height)
        if shortEdge > Self.maxPixelEdge {
            // 等比缩放：短边压到 1080，另一边自动跟随，避免画面变形。
            let scale = Self.maxPixelEdge / shortEdge
            scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaled = source
        }

        /* 一步出 JPEG。
           旧实现 CGImage → UIImage → jpegData 会同时持有三份大对象，
           1080p 下峰值接近 40MB，扩展很容易被 jetsam 杀掉。
           CIContext 的 jpegRepresentation 在渲染管线内直接编码，
           只保留一份输出 Data。

           注意 options 的类型是 `[CIImageRepresentationOption: Any]`，
           不是 `[CIContextOption: Any]` —— 这两个类型互不兼容，写错直接编译失败
           （1.5.4 第一次 CI 就栽在这里）。压缩质量键仍是 CoreGraphics 的那个常量。 */
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): Self.jpegQuality
        ]
        guard let jpeg = ciContext.jpegRepresentation(
            of: scaled,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: options
        ) else {
            return
        }

        // 落盘与停止标记在同一把锁里：clear() 之后不可能再冒出旧帧。
        guard commitFrame(jpeg) else { return }
        // 顺序很重要：先落盘再发信号。写是同步的，主 App 收到通知时文件一定已就绪。
        DarwinNotifier.post(ScreenShareSignal.frameUpdated)
    }

    // MARK: - 内部工具

    private func resetForNewSession() {
        lastFrameTime = 0
        lastHeartbeatTime = CACurrentMediaTime()
        encodeLock.lock()
        isEncoding = false
        encodeLock.unlock()
        stateLock.lock()
        frameCount = 0
        stopping = false
        stateLock.unlock()
    }

    private func resetEncodingState() {
        lastFrameTime = 0
        lastHeartbeatTime = 0
        encodeLock.lock()
        isEncoding = false
        encodeLock.unlock()
    }

    private func markStopping() {
        stateLock.lock()
        stopping = true
        stateLock.unlock()
    }

    private var currentFrameCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return frameCount
    }

    /// 落盘并累加计数。返回 false 表示这次写入被停止流程拒绝或磁盘失败。
    private func commitFrame(_ jpeg: Data) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopping else { return false }
        guard SharedFrameStore.write(jpeg: jpeg) else { return false }
        frameCount += 1
        return true
    }

    private func startHeartbeatTimer() {
        stopHeartbeatTimer()
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(
            deadline: .now() + 1,
            repeating: Self.heartbeatInterval,
            leeway: .milliseconds(300)
        )
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let isStopping = self.stopping
            let frames = self.frameCount
            self.stateLock.unlock()
            guard !isStopping else { return }
            ScreenShareStore.touchHeartbeat(frames: frames)
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeatTimer() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func removeStopObserver() {
        if let observer = stopObserver {
            DarwinNotifier.removeObserver(observer)
            stopObserver = nil
        }
    }

    /// 按 2 秒节流刷新心跳。与帧节流/编码重入全部解耦：
    /// 被 FrameInterval 或 isEncoding 丢掉的帧，同样算"进程还活着"。
    private func touchHeartbeatIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastHeartbeatTime >= Self.heartbeatInterval else { return }
        lastHeartbeatTime = now
        ScreenShareStore.touchHeartbeat(frames: currentFrameCount)
    }

    private func beginEncoding() -> Bool {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        if isEncoding { return false }
        isEncoding = true
        return true
    }

    private func endEncoding() {
        encodeLock.lock()
        isEncoding = false
        encodeLock.unlock()
    }

    /// 用户从主 App 主动停止共享：用自定义错误结束，系统会正常回收扩展进程。
    ///
    /// 顺序很关键：**先**把跨进程状态清干净、**再**调 finishBroadcastWithError。
    /// 扩展被 jetsam 杀掉或系统这一版没回调 broadcastFinished 时，主 App 只能靠
    /// App Group 里的 state 判断"还在不在共享"，如果这里不主动收尾，
    /// 状态会永久停在 .active，UI 冷启动就会一直显示"正在共享"且点了停止也没反应。
    private func finishBroadcastBecauseUserStopped() {
        markStopping()
        stopHeartbeatTimer()
        removeStopObserver()
        resetEncodingState()

        ScreenShareStore.reset()
        SharedFrameStore.clear()
        DarwinNotifier.post(ScreenShareSignal.stateChanged)

        let error = NSError(
            domain: Self.stopErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "用户已停止共享屏幕"]
        )
        finishBroadcastWithError(error)
    }
}
