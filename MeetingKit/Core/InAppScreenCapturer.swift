//
//  InAppScreenCapturer.swift
//  MeetingKit
//
//  第三条路：ReplayKit 的 in-app 捕获。
//
//  为什么需要它：iOS 27 上广播扩展已被 Apple 判为 "No longer supported"
//  （系统不再创建扩展进程），而正路的 ScreenCaptureKit 又要求用 iOS 27 SDK
//  编译。如果构建机只有 Xcode 26（macos-15 / macos-26 镜像都如此），
//  产物里一行 SCK 代码都编不进去——用户装完仍然开不了共享。
//
//  RPScreenRecorder.startCapture 从 iOS 11 就有，Xcode 26 里能编译，
//  iOS 27 上仍然可用（只是被标记 deprecated）。它在**本进程**里拿到
//  CMSampleBuffer，不经过扩展、不经过 App Group、不看签名。
//
//  代价说清楚：它只能捕获本 App 的画面。用户切到别的 App，捕获会停。
//  所以只要构建环境有 iOS 27 SDK，就优先走 ScreenCaptureKit。
//

import AVFoundation
import Foundation
import ReplayKit
import WebRTC

final class InAppScreenCapturer: NSObject, ScreenSharingSession {

    var onStateChange: ((ScreenSharingSessionState) -> Void)?

    private(set) var frameCount = 0
    private(set) var idleFrameCount = 0
    private(set) var lastFrameAt: Date?
    private(set) var lastError: String?
    private(set) var phase: ScreenSharingPhase = .idle
    private(set) var stopReason: String?
    private(set) var captureSummary: String?

    private let recorder = RPScreenRecorder.shared()
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var running = false
    private var stoppingCapture = false
    /// 已设过的输出画布（见 ScreenOutputSize）。
    private var adaptedCanvas: (width: Int, height: Int)?
    /// 上一帧送进编码器的时间戳与间隔：帧率闸门，多出来的帧直接丢。
    private var lastPushAt: CFTimeInterval = 0
    private var pushInterval: CFTimeInterval = 1.0 / 24.0

    /// 轮次号，用途与 SCK 通道一致：让排队的旧回调自动作废。
    private var epoch = 0
    private let stateLock = NSLock()

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    func start(source: RTCVideoSource) {
        // ReplayKit stopCapture is asynchronous. A repeated start must not race
        // its completion or stop an unrelated recording owned by the singleton.
        stateLock.lock()
        let busy = running || stoppingCapture
        stateLock.unlock()
        guard !busy else { return }
        guard !recorder.isRecording else {
            lastError = "系统录屏正在使用，请先停止现有录屏"
            notify(.failed(lastError!))
            return
        }
        stateLock.lock()
        epoch += 1
        let captureEpoch = epoch
        stateLock.unlock()

        guard recorder.isAvailable else {
            lastError = "当前设备不支持屏幕捕获"
            notify(.failed(lastError ?? "当前设备不支持屏幕捕获"))
            return
        }

        self.source = source
        self.capturer = RTCVideoCapturer(delegate: source)
        frameCount = 0
        idleFrameCount = 0
        lastFrameAt = nil
        lastError = nil
        stopReason = nil
        captureSummary = nil
        phase = .idle
        adaptedCanvas = nil
        lastPushAt = 0
        pushInterval = 1.0 / Double(max(Int(RealRTCClient.screenEncodingProfile.fps), 1))

        /* 不要在这里开麦克风：会议的音频走独立的 RTCAudioTrack，
           再让 ReplayKit 采一次会产生两路麦克风，对端听到回声。 */
        recorder.isMicrophoneEnabled = false

        stateLock.lock()
        running = true
        stateLock.unlock()
        phase = .picking
        notify(.picking)

        recorder.startCapture { [weak self] sampleBuffer, sampleType, error in
            guard let self, self.acceptsCallback(epoch: captureEpoch) else { return }
            if let error = error {
                self.lastError = error.localizedDescription
                self.fail(error.localizedDescription)
                return
            }
            guard sampleType == .video else { return }
            self.handle(sampleBuffer)
        } completionHandler: { [weak self] error in
            guard let self, self.acceptsCallback(epoch: captureEpoch) else { return }
            if let error = error {
                self.lastError = error.localizedDescription
                self.fail(error.localizedDescription)
                return
            }
            self.notify(.running(startedAt: Date()))
        }
    }

    func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        stoppingCapture = stoppingCapture || wasRunning
        // 先占票号：此后排队的旧回调一律作废。
        epoch += 1
        stateLock.unlock()
        phase = .stopped

        guard wasRunning else {
            notify(.stopped)
            return
        }
        recorder.stopCapture { [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            self.stoppingCapture = false
            self.stateLock.unlock()
            self.notify(.stopped)
        }
    }

    private func fail(_ message: String) {
        lastError = message
        stopReason = message
        phase = .failed
        stateLock.lock()
        let shouldStop = running
        running = false
        stoppingCapture = stoppingCapture || shouldStop
        epoch += 1
        stateLock.unlock()
        if shouldStop {
            recorder.stopCapture { [weak self] _ in
                guard let self else { return }
                self.stateLock.lock()
                self.stoppingCapture = false
                self.stateLock.unlock()
            }
        }
        notify(.failed(message))
    }

    private func acceptsCallback(epoch token: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && epoch == token
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let source,
              let capturer else { return }

        /* 画布必须和源同一个宽高比。
           WebRTC 的 adaptOutputFormat 是"裁切 + 缩放"：按固定 16:9 设画布，
           竖屏内容就会被切掉上下。 */
        adaptCanvasIfNeeded(pixelBuffer: pixelBuffer, source: source)

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPushAt >= pushInterval else { return }
        lastPushAt = now

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timestamp) * 1_000_000_000)
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timeStampNs)
        source.capturer(capturer, didCapture: frame)

        frameCount += 1
        lastFrameAt = Date()
        ScreenShareRuntime.noteNativeFrame()
        if captureSummary == nil {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            captureSummary = "\(width)x\(height)"
        }
        if phase != .running { phase = .running }
    }

    /// 按真实像素比例设置输出画布（只在首帧与尺寸变化时调用）。
    private func adaptCanvasIfNeeded(pixelBuffer: CVPixelBuffer, source: RTCVideoSource) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 1, height > 1 else { return }

        let profile = RealRTCClient.screenEncodingProfile
        let longEdge = max(Int(profile.width), Int(profile.height))
        let target = ScreenOutputSize.fit(width: width, height: height, maxLongEdge: longEdge)
        if let adaptedCanvas,
           adaptedCanvas.width == target.width,
           adaptedCanvas.height == target.height {
            return
        }
        adaptedCanvas = (target.width, target.height)
        pushInterval = 1.0 / Double(max(Int(profile.fps), 1))
        source.adaptOutputFormat(
            toWidth: Int32(target.width),
            height: Int32(target.height),
            fps: profile.fps
        )
    }

    private func notify(_ state: ScreenSharingSessionState) {
        // 票号机制与 SCK 通道一致：旧一轮排队的回调不会影响新一轮。
        stateLock.lock()
        let token = epoch
        stateLock.unlock()
        let deliver = { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let current = self.epoch
            self.stateLock.unlock()
            guard current == token else { return }
            self.onStateChange?(state)
        }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }
}
