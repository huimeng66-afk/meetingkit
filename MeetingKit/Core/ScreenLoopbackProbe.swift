//
//  ScreenLoopbackProbe.swift
//  MeetingKit
//
//  挂在**共享轨自己**上的回环接收器。
//
//  为什么需要它：
//  诊断面板上"已推 164 帧"这个数字来自 `RTCVideoSource.capturer(...)` 的调用处，
//  只能证明"我们把帧交给了一个 source 对象"，不能证明这个对象就是
//  sender 正在消费的那条轨的 source。两者不是同一个对象时，现场非常具有迷惑性：
//
//      已推 164 帧 · 共享轨已挂 · 轨开 · mid=2/enc=1/ssrc=…
//      · 编码器 impl=VideoToolbox key=0 sent=0 0x0 重传=0
//
//  每个状态位都对，就是一个包都没有。1.9.0 就是这个现场。
//
//  把接收器直接挂在 `localScreenTrack` 上，WebRTC 的 `VideoTrack` 会把这条轨
//  收到的每一帧同时分发给所有 sink（编码器是其中一个，我们也是其中一个）。
//  于是这个计数成了"这条轨的源到底有没有在出帧"的硬证据：
//
//    · 镜像帧 > 0，编码 0 → 轨是活的，断在 sender 绑定；
//    · 镜像帧 = 0，已推 > 0 → 推错 source 了（推给了没人消费的另一个 source）。
//
//  注意：这是本地轨，接收器不会被对端影响；也不额外占带宽。
//

import Foundation
import WebRTC

final class ScreenLoopbackProbe: NSObject, RTCVideoRenderer {

    private let lock = NSLock()
    private var _frames = 0

    var frames: Int {
        lock.lock(); defer { lock.unlock() }
        return _frames
    }

    func reset() {
        lock.lock()
        _frames = 0
        lock.unlock()
    }

    // MARK: - RTCVideoRenderer

    func setSize(_ size: CGSize) {
        /* 尺寸对判断没有意义：`renderFrame` 能到就说明轨在出帧。 */
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame = frame else { return }
        /* 触碰一下宽高，确保不是构造到一半的坏帧。 */
        guard frame.width > 0, frame.height > 0 else { return }

        lock.lock()
        _frames += 1
        lock.unlock()

        ScreenShareRuntime.noteLoopbackFrame()
    }
}
