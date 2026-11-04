//
//  SampleHandler.swift
//  MeetingBroadcast
//
//  ReplayKit 广播上传扩展的入口。
//
//  ── 跨进程时序（全链路）────────────────────────────────────────────────
//   1. 主 App 内点击 RPSystemBroadcastPickerView → 系统拉起本扩展（独立进程）
//   2. 系统回调 broadcastStarted → 写 ScreenShareStore(.active) → post stateChanged
//   3. 系统高频回调 processSampleBuffer → 节流到 4fps → 缩放 ≤800px 宽 → JPEG(0.5)
//      → 写入 App Group 容器 → post frameUpdated
//      注：无论这一帧是否被节流/编码重入丢弃，只要收到 .video 就按 2 秒一次刷新
//      ScreenShareStore.heartbeat —— 主 App 靠心跳判活，不靠"有没有新帧"（H-1）
//   4. 主 App 的 ScreenShareBridge 收到 frameUpdated → 读文件 → UIImage 刷新预览
//   5. 主 App 点"停止共享" → post stopRequested → 本扩展先清状态/清帧/移除观察者，
//      再 finishBroadcastWithError → 系统回调 broadcastFinished（幂等再清一次）→ 进程退出
//
//  ── 内存红线 ─────────────────────────────────────────────────────────
//  广播扩展进程的常驻内存上限约 50MB，超限被系统 jetsam 杀掉时用户只会看到
//  "共享中断"，没有任何日志。因此：CIContext 必须复用、每帧处理必须包
//  autoreleasepool、输出图必须缩到 800px 宽、绝不缓存多帧。
//

import UIKit
import CoreVideo
import CoreMedia
import CoreImage
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {

    // MARK: - 常量

    /// 目标 4fps。屏幕共享以"看清内容"为目标，4fps 足够；更高帧率只会挤占 RTC 的上行带宽。
    private static let frameInterval: CFTimeInterval = 0.25

    /// 心跳最小写入间隔。UserDefaults 每次写入都要经 cfprefsd 做跨进程同步，
    /// 按采样频率（60Hz）写会把扩展的 CPU 与内存拖到 jetsam 边缘；
    /// 主 App 的心跳超时是 12 秒，2 秒一次留了 6 次容错，足够判活。
    private static let heartbeatInterval: CFTimeInterval = 2

    /// 输出最大边长。短边超过这个值的帧按比例缩到短边 = 800：
    /// 横屏（手机横放）宽 800，竖屏高 800，保证任何方向下主 App 的 720p 画布都不留大片黑边。
    private static let maxPixelEdge: CGFloat = 800

    /// 0.5 是清晰度与体积的经验平衡点：800px 宽下约 40~80KB。
    private static let jpegQuality: CGFloat = 0.5

    /// 自定义错误域，主 App 可据此区分"用户主动停止"与系统异常中断。
    private static let stopErrorDomain = "com.example.meetingkit.broadcast"

    // MARK: - 属性

    /// CIContext 的初始化成本很高（GPU 资源 + kernel 编译），必须作为属性复用，
    /// 每帧新建会直接把扩展拖到内存红线并卡死采样回调。
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 编码专用串行队列：缩放、JPEG 编码、落盘全部在这里做，绝不占用采样回调。
    private let encodeQueue = DispatchQueue(
        label: "com.example.meetingkit.broadcast.encode",
        qos: .userInitiated
    )

    /// 防重入标记。采样回调和编码队列不在同一线程，所以用锁保护，
    /// 保证同一时刻最多有一帧在编码，避免多帧堆积把内存顶爆。
    private let encodeLock = NSLock()
    private var isEncoding = false

    /// 上一次接受帧的时间戳（CACurrentMediaTime，单调递增，不受系统时间调整影响）。
    private var lastFrameTime: CFTimeInterval = 0

    /// 上一次写心跳的时间戳（CACurrentMediaTime）。与帧节流完全独立：
    /// 即使这一帧因为帧率/编码重入被丢弃，心跳仍然要按自己的节奏刷新。
    private var lastHeartbeatTime: CFTimeInterval = 0

    /// stopRequested 的观察者 token，结束广播时必须摘掉。
    private var stopObserver: NSObjectProtocol?

    // MARK: - 生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 每次广播都当作一次全新会话：重置节流与重入标记，防止上一次的残留状态吞掉首帧。
        lastFrameTime = 0
        lastHeartbeatTime = 0
        encodeLock.lock()
        isEncoding = false
        encodeLock.unlock()

        ScreenShareStore.state = .active
        ScreenShareStore.startedAt = Date()
        // 起播立刻写一次心跳：否则主 App 在收到第一帧之前只能退化成按 startedAt 计时，
        // 这里补一次能让存活判定从一开始就走心跳分支。
        ScreenShareStore.touchHeartbeat()
        lastHeartbeatTime = CACurrentMediaTime()
        DarwinNotifier.post(ScreenShareSignal.stateChanged)

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
        // 暂停期间系统不一定继续回调采样，心跳会停在暂停那一刻。恢复的瞬间先补一次，
        // 否则主 App 可能在首个新采样到达之前就拿着旧心跳判死（H-1 的同一条误杀路径）。
        ScreenShareStore.touchHeartbeat()
        lastHeartbeatTime = CACurrentMediaTime()
        DarwinNotifier.post(ScreenShareSignal.stateChanged)
    }

    override func broadcastFinished() {
        lastFrameTime = 0
        lastHeartbeatTime = 0
        encodeLock.lock()
        isEncoding = false
        encodeLock.unlock()

        // 先摘观察者再清状态：避免清理过程中又被 stopRequested 触发一次 finish。
        if let observer = stopObserver {
            DarwinNotifier.removeObserver(observer)
            stopObserver = nil
        }

        ScreenShareStore.reset()
        SharedFrameStore.clear()
        DarwinNotifier.post(ScreenShareSignal.stateChanged)
    }

    // MARK: - 采样

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            // 心跳必须挂在"收到采样"这一层，而不是挂在编码成功之后：
            // 画面静止时 ReplayKit 可能压低甚至停发采样，但只要它还在回调 .video，
            // 就证明扩展进程活着，主 App 就不该判死（H-1）。
            touchHeartbeatIfNeeded()
            handleVideoSampleBuffer(sampleBuffer)

        case .audioApp, .audioMic:
            // 音频不在这里处理：屏幕共享期间的声音由主 App 侧的 RTC SDK 直接从麦克风采集，
            // 系统混音轨（audioApp）后续通过 SDK 的 ReplayKit 音频通道接入，本阶段不上行。
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
            // autoreleasepool 是扩展的保命符：CoreGraphics / UIImage 会往当前线程的
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
            // 等比缩放：短边压到 800，另一边自动跟随，避免画面变形。
            let scale = Self.maxPixelEdge / shortEdge
            scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaled = source
        }

        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        // 这里用 UIImage 而不是直接拿 CGImage 转 Data，是为了走系统成熟的 JPEG 编码器；
        // 图片在函数返回后即可释放，不会常驻。
        let image = UIImage(cgImage: cgImage)
        guard let jpeg = image.jpegData(compressionQuality: Self.jpegQuality) else { return }

        SharedFrameStore.write(jpeg: jpeg)
        // 顺序很重要：先落盘再发信号。写是同步的，主 App 收到通知时文件一定已就绪，
        // 不会出现"收到通知却读出上一帧"的竞态。
        DarwinNotifier.post(ScreenShareSignal.frameUpdated)
    }

    // MARK: - 内部工具

    /// 按 2 秒节流刷新心跳。与帧节流/编码重入全部解耦：
    /// 被 FrameInterval 或 isEncoding 丢掉的帧，同样算"进程还活着"。
    private func touchHeartbeatIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastHeartbeatTime >= Self.heartbeatInterval else { return }
        lastHeartbeatTime = now
        ScreenShareStore.touchHeartbeat()
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
        // 先摘观察者：避免收尾过程中又被 stopRequested 触发一次 finish。
        if let observer = stopObserver {
            DarwinNotifier.removeObserver(observer)
            stopObserver = nil
        }

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
