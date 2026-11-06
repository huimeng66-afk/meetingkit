//
//  ScreenCaptureKitSharer.swift
//  MeetingKit
//
//  iOS 27 起，ReplayKit 的广播扩展被 Apple 判为 "No longer supported"：
//  RPBroadcastSampleHandler 在 iOS 27 SDK 里标成 API_DEPRECATED(ios(10.0, 27.0))，
//  RPSystemBroadcastPickerView 也一并废弃。系统收到「开始共享」后只会弹出
//  共享卡片（天穹会议 00:04 + 转圈），**不再创建扩展进程**。
//
//  这正是真机诊断里那一组自相矛盾数据的来源：
//      扩展进程：本次未启动 / 扩展状态 idle / 心跳无 / 0 帧
//  不是签名问题，不是 App Group 问题，是平台机制换了。
//
//  Apple 给出的替代是 ScreenCaptureKit：系统弹 SCContentSharingPicker，
//  用户在面板里选「整个屏幕」或某个 App，帧以 CMSampleBuffer 直接回到本进程。
//  没有第二个进程、没有 App Group、没有 50MB 内存上限、也没有 IPC。
//

import Foundation
import AVFoundation
import ReplayKit
import WebRTC

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// 屏幕共享会话的统一抽象。
///
/// 存在的意义：让 ViewModel 不直接依赖 ScreenCaptureKit。
/// 如果构建机是 Xcode 26（没有 iOS 27 SDK），`canImport` 为 false，
/// 下面整段 SCK 实现不参与编译，App 仍然能在 iOS 26 及以下用广播扩展。
protocol ScreenSharingSession: AnyObject {
    var onStateChange: ((ScreenSharingSessionState) -> Void)? { get set }
    /// 已推给编码器的帧数。诊断用。
    var frameCount: Int { get }
    /// 被 SCK 的 idle 帧挡下的次数（画面没变化）。诊断用。
    var idleFrameCount: Int { get }
    var lastFrameAt: Date? { get }
    func start(source: RTCVideoSource)
    func stop()
}

enum ScreenSharingSessionState {
    /// 系统面板已弹出，等用户选内容。
    case picking
    /// 已经在推帧。
    case running(startedAt: Date)
    /// 已停止（用户取消、或从系统共享条点了停止）。
    case stopped
    case failed(String)
}

/// 本进程内共享有两条实现，能力不同，UI 需要知道当前是哪一条。
enum ScreenSharingBackend {
    /// iOS 27+ + iOS 27 SDK：系统内容面板，可选整个屏幕或单个 App。
    case screenCaptureKit
    /// iOS 27+ 但构建机没有 iOS 27 SDK：ReplayKit in-app 捕获，只能共享本 App。
    case inApp
    /// iOS 26 及以下：广播扩展（App Group + 独立进程）。
    case broadcastExtension
}

enum ScreenSharingSessionFactory {

    /// 当前系统是否支持「本进程内的共享」。
    ///
    /// iOS 26 及以下返回 false：那条路仍然走广播扩展，比 in-app 捕获更强
    /// （能共享整个屏幕、切到别的 App 也不断）。
    static var isSupported: Bool {
        backend != .broadcastExtension
    }

    static var backend: ScreenSharingBackend {
        guard #available(iOS 27.0, *) else { return .broadcastExtension }

        #if canImport(ScreenCaptureKit)
        if SCContentSharingPicker.shared.isAvailable {
            return .screenCaptureKit
        }
        #endif

        // 构建机没有 iOS 27 SDK 时走到这里。ReplayKit 的 in-app 捕获
        // 在 iOS 27 上仍然可用，先保证"能共享"，代价是只能共享本 App。
        if RPScreenRecorder.shared().isAvailable {
            return .inApp
        }
        return .broadcastExtension
    }

    static func make() -> ScreenSharingSession? {
        guard #available(iOS 27.0, *) else { return nil }

        #if canImport(ScreenCaptureKit)
        if SCContentSharingPicker.shared.isAvailable {
            return ScreenCaptureKitSharer()
        }
        #endif

        if RPScreenRecorder.shared().isAvailable {
            return InAppScreenCapturer()
        }
        return nil
    }
}

#if canImport(ScreenCaptureKit)

@available(iOS 27.0, *)
final class ScreenCaptureKitSharer: NSObject, ScreenSharingSession {

    var onStateChange: ((ScreenSharingSessionState) -> Void)?

    /// 已推给编码器的帧数。诊断用。
    private(set) var frameCount = 0
    private(set) var lastFrameAt: Date?
    /// 被 SCK 的 idle 帧挡下的次数。静止画面时这个数会涨，帧数不涨——正常现象。
    private(set) var idleFrameCount = 0
    private(set) var lastError: String?

    private let picker = SCContentSharingPicker.shared
    private var stream: SCStream?
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var running = false

    /// 帧回调不挂在主队列：共享时用户很可能正在别的 App 里翻页，
    /// 主线程被降频不该拖住编码输入。
    private let sampleQueue = DispatchQueue(
        label: "com.tianqiong.meetingkit.screencapturekit",
        qos: .userInitiated
    )

    // MARK: - 生命周期

    func start(source: RTCVideoSource) {
        guard !running else { return }
        self.source = source
        self.capturer = RTCVideoCapturer(delegate: source)
        frameCount = 0
        idleFrameCount = 0
        lastFrameAt = nil
        lastError = nil

        // remove 先走一遍：重复点「开始共享」时不会叠加观察者，
        // 否则一次选择会触发多次 startStream。
        picker.remove(self)
        picker.add(self)
        picker.isActive = true
        notify(.picking)
        picker.present()
    }

    func stop() {
        let runningStream = stream
        stream = nil
        running = false
        if let runningStream {
            Task { try? await runningStream.stopCapture() }
        }
        picker.isActive = false
        picker.remove(self)
        notify(.stopped)
    }

    // MARK: - 建立 SCStream

    private func startStream(with filter: SCContentFilter) {
        let size = Self.outputSize(for: filter)

        let configuration = SCStreamConfiguration()
        // iOS 上 width/height 的单位是**像素**，不是点。
        // 不显式设置会按内容原始分辨率输出，3x 屏的整屏就是 1179x2556，
        // 编码器和上行带宽都吃不消。
        configuration.width = size.width
        configuration.height = size.height

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            lastError = "无法接收屏幕帧：\(error.localizedDescription)"
            notify(.failed(lastError ?? "无法接收屏幕帧"))
            return
        }

        stream = newStream
        running = true

        Task { [weak self] in
            do {
                try await newStream.startCapture()
                guard let self else { return }
                self.notify(.running(startedAt: Date()))
            } catch {
                guard let self else { return }
                self.stream = nil
                self.running = false
                self.lastError = error.localizedDescription
                self.notify(.failed(error.localizedDescription))
            }
        }
    }

    /// 输出画布：长边 1280，按内容的宽高比缩放，且保证是偶数。
    ///
    /// 只用 `contentRect` 的宽高比、不乘 `pointPixelScale`：
    /// 比例是无量纲的，乘不乘都一样，少依赖一个 iOS 上可能变动的属性。
    private static func outputSize(for filter: SCContentFilter) -> (width: Int, height: Int) {
        let rect = filter.contentRect
        let width = max(rect.width, 1)
        let height = max(rect.height, 1)
        let ratio = width / height
        let longEdge: CGFloat = 1280

        if ratio >= 1 {
            return (even(Int(longEdge)), even(Int((longEdge / ratio).rounded())))
        }
        return (even(Int((longEdge * ratio).rounded())), even(Int(longEdge)))
    }

    private static func even(_ value: Int) -> Int {
        max((value / 2) * 2, 2)
    }

    // MARK: - 状态广播

    private func notify(_ state: ScreenSharingSessionState) {
        if Thread.isMainThread {
            onStateChange?(state)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(state)
            }
        }
    }
}

// MARK: - SCContentSharingPickerObserver

@available(iOS 27.0, *)
extension ScreenCaptureKitSharer: SCContentSharingPickerObserver {

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        // 共享中途用户在系统面板里换了内容：更新过滤器即可，
        // 不能重建 SCStream——重建会断流，对端画面黑一下。
        if let existing = self.stream {
            Task { try? await existing.updateContentFilter(filter) }
            return
        }
        startStream(with: filter)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        // 已经有流在跑时，"取消"只是关掉面板，不代表停止共享。
        guard self.stream == nil else { return }
        notify(.stopped)
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        lastError = error.localizedDescription
        notify(.failed(error.localizedDescription))
    }
}

// MARK: - SCStreamOutput

@available(iOS 27.0, *)
extension ScreenCaptureKitSharer: SCStreamOutput {

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, self.stream === stream else { return }

        /* SCK 与 ReplayKit 最大的语义差别：回调 ≠ 新画面。
           画面没变化时它照样回调，但附带的 status 是 .idle，
           底层还是同一块 IOSurface。这种帧转发出去只会让编码器
           重复编同一张图，白白吃掉码率。
           解析不出 status 时**照常转发**：宁可多推几帧，也不能黑屏。 */
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[SCStreamFrameInfo.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete, status != .started {
            idleFrameCount += 1
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let source,
              let capturer else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timestamp) * 1_000_000_000)
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: buffer, rotation: .deg0, timeStampNs: timeStampNs)
        source.capturer(capturer, didCapture: frame)

        frameCount += 1
        lastFrameAt = Date()
    }
}

// MARK: - SCStreamDelegate

@available(iOS 27.0, *)
extension ScreenCaptureKitSharer: SCStreamDelegate {

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 用户从系统「正在共享」条点停止、或系统强制中断，都会走到这里。
        guard self.stream === stream else { return }
        self.stream = nil
        running = false
        lastError = error.localizedDescription
        notify(.stopped)
    }
}

#endif
