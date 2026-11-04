//
//  BrandBackground.swift
//  MeetingKit
//
//  页面底：深空黑 + 两处极弱的品牌冷光。
//
//  ── 为什么删掉了"极光" ──────────────────────────────────────────────
//  上一版是四团 26 秒漂移的光斑（蓝 / 紫 / 青 / 靛）。它的出发点是"玻璃下面
//  得有东西可折射"，但做出来的观感是典型的 AI 生成式界面：高饱和、彩色烟雾、
//  处处发光。真实的高端 App 底色几乎都是**安静的**——光只用来交代一个方向感，
//  不参与抢注意力。
//
//  现在只留两个静态光源：左上一点冷蓝，右上一点靛紫，透明度都压到 0.10 附近，
//  中间大面积保持接近纯黑。玻璃盖上去时，边缘会折射出一点点颜色变化，足够了；
//  剩下的层次交给玻璃自己的边缘高光，而不是靠背景硬撑。
//
//  性能上也不再需要任何动画：整块背景是一次性的渐变合成，不占帧。
//

import SwiftUI

struct BrandBackground: View {

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)

            ZStack {
                Theme.Palette.background

                // 左上冷光：方向感来源。半径给到 0.9 屏宽，衰减极缓，
                // 这样它不会形成"一个圆"，而是像房间角落的一盏灯。
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Theme.Palette.accent.opacity(0.16), location: 0.0),
                        .init(color: Theme.Palette.accent.opacity(0.05), location: 0.45),
                        .init(color: Color.clear, location: 1.0)
                    ]),
                    center: UnitPoint(x: 0.12, y: -0.06),
                    startRadius: 0,
                    endRadius: width * 0.95
                )

                // 右上冷紫：与左上的蓝拉开一点色相，避免整屏只有一种蓝。
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Theme.Palette.violet.opacity(0.10), location: 0.0),
                        .init(color: Color.clear, location: 1.0)
                    ]),
                    center: UnitPoint(x: 1.02, y: 0.28),
                    startRadius: 0,
                    endRadius: width * 0.75
                )

                // 底部压暗：悬浮 Dock 底下的亮度必须低于内容区，
                // 否则玻璃会跟着变亮、白字对比度掉下去。
                LinearGradient(
                    stops: [
                        .init(color: Color.clear, location: 0.52),
                        .init(color: Color.black.opacity(0.36), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // 顶部压暗：状态栏与大标题区域需要稳定的对比度底。
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.22), location: 0.0),
                        .init(color: Color.clear, location: 0.22)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: width, height: height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 按压手感

/// 品牌页统一按压比例（设计规范 0.96）。
/// 会议室内部的 `ControlButtonPressStyle` 是 0.92，属于另一套手感，不复用也不修改。
struct BrandPressStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animationCompat(Theme.Motion.standard, value: configuration.isPressed)
    }
}
