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

    /// 按源尺寸等比缩到长边 `maxLongEdge` 以内，宽高取 16 的倍数。
    ///
    /// 16 对齐不是为了好看：H.264 的宏块是 16×16，宽高不是 16 的倍数时，
    /// 硬件编码器要么补边（浏览器解出来整体偏移）、要么直接拒绝创建会话
    /// （表现就是"帧推进去了，framesEncoded 恒为 0"）。手机上 886 这种
    /// 宽度就踩过这个坑，改成 880 后编码器才正常出帧。
    static func fit(width: Int, height: Int, maxLongEdge: Int) -> (width: Int, height: Int) {
        guard width > 1, height > 1 else { return (16, 16) }
        let longEdge = max(width, height)
        let limit = max(maxLongEdge, 16)
        let scale = longEdge > limit ? Double(limit) / Double(longEdge) : 1

        let scaledWidth = align16(Int((Double(width) * scale).rounded()))
        let scaledHeight = align16(Int((Double(height) * scale).rounded()))
        return (scaledWidth, scaledHeight)
    }

    /// 向下取 16 的倍数，且不小于 16。
    ///
    /// 只向下取整：宁可少 8 个像素（缩放到 1920 长边时肉眼不可见），
    /// 也不能向上取整后超过源画面、把适配器逼进"放大再裁切"。
    static func align16(_ value: Int) -> Int {
        max((max(value, 16) / 16) * 16, 16)
    }

    /// 取不小于 2 的偶数。
    static func even(_ value: Int) -> Int {
        let clamped = max(value, 2)
        return clamped % 2 == 0 ? clamped : clamped - 1
    }
}
