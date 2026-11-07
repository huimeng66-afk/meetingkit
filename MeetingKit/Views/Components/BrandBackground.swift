//
//  BrandBackground.swift
//  MeetingKit
//
//  页面底：浅灰页面 + 两处极弱的品牌冷光。
//
//  ── 为什么是浅色 ────────────────────────────────────────────────────
//  网页端（public/assets/css/base.css）的主色是 --bg #f4f5f7 / --surface #ffffff /
//  --ink-900 #191c21。App 之前是深空蓝 #04060D，两端截图放在一起完全是两个产品。
//  现在底色、卡片、文字三级灰全部照搬网页令牌，视觉才是一套。
//
//  ── 光怎么打 ────────────────────────────────────────────────────────
//  浅色底最怕"脏"：任何一处高饱和光斑都会让白卡片泛灰。所以只留两点极淡的
//  品牌色（蓝 0.10、紫 0.06），半径都超过半屏，衰减到边缘时几乎为 0。
//  它们的唯一作用，是让玻璃边缘有一点色相变化，而不是形成看得见的圆形。
//
//  深色版的"顶部/底部压暗"整段删掉了。浅色底压暗会变成脏灰，
//  换成一整块自上而下的极淡冷灰，让页面下半部分（Dock 区域）略微沉一点。
//

import SwiftUI

struct BrandBackground: View {

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)

            ZStack {
                Theme.Palette.background

                // 左上冷蓝：方向感来源。半径给到 0.95 屏宽，衰减极缓，
                // 这样它不会形成"一个圆"，而是像房间角落的一盏灯。
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Theme.Palette.accent.opacity(0.10), location: 0.0),
                        .init(color: Theme.Palette.accent.opacity(0.03), location: 0.45),
                        .init(color: Color.clear, location: 1.0)
                    ]),
                    center: UnitPoint(x: 0.10, y: -0.08),
                    startRadius: 0,
                    endRadius: width * 0.95
                )

                // 右上冷紫：与左上的蓝拉开一点色相，避免整屏只有一种蓝。
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Theme.Palette.violet.opacity(0.06), location: 0.0),
                        .init(color: Color.clear, location: 1.0)
                    ]),
                    center: UnitPoint(x: 1.02, y: 0.22),
                    startRadius: 0,
                    endRadius: width * 0.78
                )

                // 下半部分极淡的冷灰。作用不是"压暗"，是给悬浮 Dock 一点落差：
                // 白玻璃压在纯 #f4f5f7 上几乎看不出边界。
                LinearGradient(
                    stops: [
                        .init(color: Color.clear, location: 0.55),
                        .init(color: Color(hex: 0xDDE3EC).opacity(0.55), location: 1.0)
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
            .scaleEffect(configuration.isPressed ? GlassMotion.scale(0.98) : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animationCompat(Theme.Motion.standard, value: configuration.isPressed)
    }
}
