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

    private let recorder = RPScreenRecorder.shared()
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var running = false

    func start(source: RTCVideoSource) {
        guard !running else { return }
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

        /* 不要在这里开麦克风：会议的音频走独立的 RTCAudioTrack，
           再让 ReplayKit 采一次会产生两路麦克风，对端听到回声。 */
        recorder.isMicrophoneEnabled = false

        running = true
        notify(.picking)

        recorder.startCapture { [weak self] sampleBuffer, sampleType, error in
            guard let self else { return }
            if let error = error {
                self.lastError = error.localizedDescription
                self.notify(.failed(error.localizedDescription))
                self.running = false
                return
            }
            guard sampleType == .video else { return }
            self.handle(sampleBuffer)
        } completionHandler: { [weak self] error in
            guard let self else { return }
            if let error = error {
                self.running = false
                self.lastError = error.localizedDescription
                self.notify(.failed(error.localizedDescription))
                return
            }
            self.notify(.running(startedAt: Date()))
        }
    }

    func stop() {
        guard running else {
            notify(.stopped)
            return
        }
        running = false
        recorder.stopCapture { [weak self] _ in
            self?.notify(.stopped)
        }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard running,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
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
