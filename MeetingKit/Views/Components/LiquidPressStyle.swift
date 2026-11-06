//
//  LiquidPressStyle.swift
//  MeetingKit
//
//  液态按压 —— 所有可点元素的统一手感。
//
//  ── 参考实现怎么做的 ──────────────────────────────────────────────
//  `webgl-apple-liquid-glass` 的 Press 场景里有三种按压：
//    · 按钮：按下时玻璃**向外鼓出**（pressed lens），边缘高光增强；
//    · 导航滑块：按下时选中胶囊变宽、变高，被拖动时沿轨道拉伸；
//    · 开关：旋钮按下时原地"bloom"，半径涨 8%，松手回位。
//  共同点是：**按下不是缩小，而是被压扁 + 向外溢出**。
//  只做 `scaleEffect(0.96)` 会像按了一块塑料，因为塑料不会向外鼓。
//
//  ── 这里怎么用 SwiftUI 表达"鼓出" ────────────────────────────────
//  1. 整体压到 0.955（被压扁）；
//  2. 叠一层同形状的描边，按下时从 0 涨到 1，模拟边缘被压出的高光；
//  3. 叠一层极淡的白色径向渐变，按下时从中心亮起，模拟光被折射进玻璃；
//  4. 曲线用 Graphics 里那条欠阻尼 spring（damping 0.62），松手过一次冲。
//
//  ── 为什么不直接 scaleEffect(1.04) ─────────────────────────────────
//  1.04 会把按钮顶到相邻元素上（底栏 7 颗并排，间距只有 6pt），
//  溢出必须发生在**裁剪内部**，靠高光而不靠尺寸。所以"鼓出"是画出来的，
//  不是撑大的——这点和 WebGL 实现一致：它也只改 shader 里的 thickness 场。
//

import SwiftUI

// MARK: - 样式

struct LiquidPressStyle: ButtonStyle {

    /// 按下时压到的比例。0.955 是"看得出被按、又不至于跳一下"的值。
    var pressedScale: CGFloat = 0.955
    /// 圆角，用于裁剪"鼓出"的高光层。传 nil 时用胶囊。
    var cornerRadius: CGFloat? = nil
    /// 是否在按下时加一圈外发光（主操作按钮用）。
    var glow: Bool = false
    /// 按下高光的强度。0 表示只要缩放（列表行这类大面积的元素用）。
    var highlight: Double = 1

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? GlassMotion.scale(pressedScale) : 1)
            .overlay(
                LensBloom(
                    isPressed: configuration.isPressed,
                    cornerRadius: cornerRadius,
                    intensity: highlight
                )
                .allowsHitTesting(false)
            )
            .shadow(
                color: glow && configuration.isPressed
                    ? Theme.Palette.accent.opacity(0.28)
                    : Color.clear,
                radius: configuration.isPressed ? 14 : 0,
                x: 0,
                y: 4
            )
            // 按下用欠阻尼（会过冲），松手用 settle（稳）。两态用不同曲线，
            // 因为"被压"和"回弹"在物理上本来就不是同一条曲线。
            .animation(
                configuration.isPressed ? GlassMotion.press : GlassMotion.settle,
                value: configuration.isPressed
            )
    }
}

// MARK: - 压出的高光

/// 盖在按钮内容上的"透镜边界"。
///
/// 两层，都以 opacity 参与动画（不用 mask，避免离屏渲染）：
///   · 描边：一圈 1px 白线，按下时从 0 到 0.55——玻璃被压时边缘会积光；
///   · 中心光：径向渐变，按下时从 0 到 0.10——光透过被压薄的玻璃。
private struct LensBloom: View {

    var isPressed: Bool
    var cornerRadius: CGFloat?
    var intensity: Double

    private var shape: LensShape {
        if let radius = cornerRadius {
            return LensShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        return LensShape(Capsule(style: .continuous))
    }

    var body: some View {
        ZStack {
            shape
                .stroke(Color.white.opacity(isPressed ? 0.55 * intensity : 0), lineWidth: 1)

            shape
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(isPressed ? 0.13 * intensity : 0),
                            Color.white.opacity(0)
                        ],
                        center: .top,
                        startRadius: 0,
                        endRadius: 26
                    )
                )
        }
    }
}

// MARK: - 形状擦除

/// SwiftUI 的 `Shape` 是泛型，无法在同一个属性里存两种形状。
/// iOS 16 有 `AnyShape`，但部署目标是 15，所以这里自己补一个最小的类型擦除。
///
/// 只实现 `Path(in:)`，足够给 `stroke` / `fill` 用。
struct LensShape: Shape {

    private let builder: (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        builder = { rect in
            shape.path(in: rect)
        }
    }

    func path(in rect: CGRect) -> Path {
        builder(rect)
    }
}

// MARK: - 便捷入口

extension View {

    /// 给任意可点视图套上液态按压。用于无法用 ButtonStyle 的场景
    /// （例如 `onTapGesture` 的卡片、`NavigationLink` 之外的自绘行）。
    func liquidPressable(pressed: Bool, scale: CGFloat = 0.97, cornerRadius: CGFloat? = nil) -> some View {
        self
            .scaleEffect(pressed ? GlassMotion.scale(scale) : 1)
            .overlay(
                LensBloom(isPressed: pressed, cornerRadius: cornerRadius, intensity: 1)
                    .allowsHitTesting(false)
            )
            .animation(pressed ? GlassMotion.press : GlassMotion.settle, value: pressed)
    }
}
