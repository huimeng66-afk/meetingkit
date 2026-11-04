//
//  BrandBackground.swift
//  MeetingKit
//
//  天穹品牌底：深空蓝 + 四团缓慢漂移的极光。
//
//  ── 为什么必须"动" ────────────────────────────────────────────────
//  玻璃质感成立的前提是**下面有东西可折射**。之前的实现是三层静态径向渐变，
//  在纯深色底上几乎看不出层次，盖在上面的玻璃只能糊成一块灰——这就是
//  "卡片像灰块、跟网页端不是一个级别"的根因。
//
//  现在改成四团大半径光斑做极慢漂移（18~26 秒一个来回，肉眼几乎察觉不到在动，
//  但每次扫视时折射角度都不一样），玻璃才有了"活"的底色。
//
//  性能取舍：不用 TimelineView / Canvas 逐帧重绘，只让 4 个已光栅化的圆做
//  位移动画——走的是 Core Animation 合成层，不触发 SwiftUI body 重算。
//  降低动态效果（accessibilityReduceMotion）时全部停在初始位，不做位移。
//

import SwiftUI

struct BrandBackground: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 单一相位驱动四团光斑，避免四套独立动画各自计时导致画面"打架"。
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)

            ZStack {
                Theme.Palette.background

                // 左上：品牌蓝，最大最亮，负责定调。
                orb(
                    color: Theme.Palette.accent,
                    opacity: 0.30,
                    diameter: width * 1.55
                )
                .position(
                    x: width * 0.10 + phase * 26,
                    y: height * 0.06 - phase * 18
                )

                // 右上：紫，与蓝色拉开色相，制造"极光交界"。
                orb(
                    color: Theme.Palette.violet,
                    opacity: 0.24,
                    diameter: width * 1.30
                )
                .position(
                    x: width * 0.96 - phase * 20,
                    y: height * 0.18 + phase * 30
                )

                // 底部中：青，托住底栏区域，让悬浮 Dock 下面有冷暖对比。
                orb(
                    color: Theme.Palette.accent2,
                    opacity: 0.16,
                    diameter: width * 1.70
                )
                .position(
                    x: width * 0.46 + phase * 14,
                    y: height * 1.02 - phase * 22
                )

                // 中部偏右：一圈很淡的靛蓝，填掉中间容易发死黑的部分。
                orb(
                    color: Color(hex: 0x3B82F6),
                    opacity: 0.12,
                    diameter: width * 0.95
                )
                .position(
                    x: width * 0.72 + phase * 18,
                    y: height * 0.56 - phase * 14
                )

                // 顶部压暗：让状态栏、大标题始终有足够对比度。
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.28), location: 0.0),
                        .init(color: Color.clear, location: 0.28)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // 底部压暗：悬浮 Dock 底下如果还是亮光斑，玻璃会发灰、白字会飘。
                LinearGradient(
                    stops: [
                        .init(color: Color.clear, location: 0.60),
                        .init(color: Color.black.opacity(0.42), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: startDrifting)
    }

    /// 26 秒一个来回的 easeInOut。用极长的周期是因为要"看起来是静态的、但会呼吸"，
    /// 周期短于 10 秒就会明显抢注意力，反而廉价。
    private func startDrifting() {
        guard !reduceMotion else { return }
        // 已经在动就不要重复叠加，否则多次 onAppear 会把动画推回起点。
        guard phase == 0 else { return }
        withAnimation(.easeInOut(duration: 26).repeatForever(autoreverses: true)) {
            phase = 1
        }
    }
}

// MARK: - 光斑

private extension BrandBackground {

    /// 一团柔光。`RadialGradient` 中心到边缘线性衰减，再叠一层大半径模糊，
    /// 抹掉圆形轮廓——不模糊的话两团光相交处会出现一条清晰的圆弧边。
    func orb(color: Color, opacity: Double, diameter: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: color.opacity(opacity), location: 0.0),
                        .init(color: color.opacity(opacity * 0.55), location: 0.45),
                        .init(color: color.opacity(0.0), location: 1.0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.5
                )
            )
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.06)
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
