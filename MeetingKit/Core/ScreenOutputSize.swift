//
//  ScreenOutputSize.swift
//  MeetingKit
//
//  共享画面的输出画布。
//
//  为什么需要它：WebRTC 的 `RTCVideoSource.adaptOutputFormat` 不是"缩放"，
//  而是 **按目标画布裁切 + 缩放**。过去这里固定写 1920x1080（16:9），
//  手机竖屏内容（约 9:19.5）推进去，适配器会先横向裁到 16:9 —— 上下直接被切掉，
//  再把 590 宽的画面放大到 1920，于是"顶部底部没了"和"糊"同时出现。
//
//  正确做法：目标画布与源保持同一宽高比。适配器算下来裁切区域等于整帧，
//  既不丢内容，也不会做无谓的放大。
//

import CoreGraphics

enum ScreenOutputSize {

    /// 按源尺寸等比缩到长边 `maxLongEdge` 以内，宽高取偶数。
    ///
    /// 偶数不是为了好看：H.264 的 4:2:0 编码对奇数宽高会触发补边，
    /// 部分解码器（尤其是浏览器）补边后画面会整体偏移一个像素。
    static func fit(width: Int, height: Int, maxLongEdge: Int) -> (width: Int, height: Int) {
        guard width > 1, height > 1 else { return (2, 2) }
        let longEdge = max(width, height)
        let limit = max(maxLongEdge, 2)
        let scale = longEdge > limit ? Double(limit) / Double(longEdge) : 1

        let scaledWidth = even(Int((Double(width) * scale).rounded()))
        let scaledHeight = even(Int((Double(height) * scale).rounded()))
        return (scaledWidth, scaledHeight)
    }

    /// 取不小于 2 的偶数。
    static func even(_ value: Int) -> Int {
        let clamped = max(value, 2)
        return clamped % 2 == 0 ? clamped : clamped - 1
    }
}
