//
//  BrandBackground.swift
//  MeetingKit
//
//  天穹品牌底：深空蓝 + 三团极低透明度的径向光晕。
//
//  为什么不用动画：这是所有页面的最底层，任何持续动画都会让整屏每秒重绘，
//  在 14 的老设备上直接吃掉滚动帧率。星辰感靠静态渐变就够。
//  三层光晕只做氛围，透明度上限 20%，保证 ink / ink2 的对比度不被破坏。
//

import SwiftUI

struct BrandBackground: View {

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)

            ZStack {
                Theme.Palette.background

                // 左上蓝
                glow(
                    color: Theme.Palette.accent,
                    opacity: 0.20,
                    center: UnitPoint(x: 0.04, y: 0.00),
                    radius: width * 1.20
                )

                // 右上紫
                glow(
                    color: Theme.Palette.violet,
                    opacity: 0.17,
                    center: UnitPoint(x: 1.00, y: 0.14),
                    radius: width * 1.00
                )

                // 底部青
                glow(
                    color: Theme.Palette.accent2,
                    opacity: 0.11,
                    center: UnitPoint(x: 0.50, y: 1.04),
                    radius: width * 1.30
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        // 纯装饰层：不参与命中，否则会把上面的滚动 / 按钮全部吞掉。
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glow(
        color: Color,
        opacity: Double,
        center: UnitPoint,
        radius: CGFloat
    ) -> some View {
        RadialGradient(
            gradient: Gradient(colors: [color.opacity(opacity), color.opacity(0)]),
            center: center,
            startRadius: 0,
            endRadius: radius
        )
    }
}

// MARK: - 按压手感

/// 品牌页统一按压比例（设计规范 0.96）。
/// 会议室内部的 `ControlButtonPressStyle` 是 0.92，属于另一套手感，不复用也不修改。
struct BrandPressStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animationCompat(Theme.Motion.standard, value: configuration.isPressed)
    }
}
