//
//  GlassSurface.swift
//  MeetingKit
//
//  历史 API 的薄封装。
//
//  Liquid Glass 2.0 的实现全部搬到了 `Theme/LiquidGlass.swift`，这个文件只剩下
//  四个兼容入口——全仓 20 多处调用点（底栏、顶栏、抽屉、Toast、胶囊、角标）
//  都还在用它们，签名一个字都不能动，否则这一轮就变成了"顺手重写整个界面"。
//
//  新旧映射关系：
//    · 旧 `tint`        → 新实现的底色覆盖（默认 `black 0.28` 与 `.regular` 完全一致）
//    · 旧 `strokeColor` → 作为内圈补线叠在新渐变描边之上（默认 `white 0.08` 几乎不可见）
//    · 旧 `hasShadow`    → 新实现的投影开关（参数取值统一到 18/8，小圆钮 6/3）
//
//  也就是说：调用点不改，观感升级。想单独换语义（更透 / 着色）时再用
//  `liquidGlass(_:cornerStyle:)` 直接指定 variant。
//

import SwiftUI

extension View {

    /// 通用写法，适合自定义 Shape（例如进度环、斜切卡片）。
    func glassSurface<S: Shape>(
        shape: S,
        tint: Color = Theme.Palette.glassTint,
        strokeColor: Color = Theme.Palette.glassStroke,
        hasShadow: Bool = false
    ) -> some View {
        modifier(
            LiquidGlassModifier(
                shape: shape,
                variant: .regular,
                isInteractive: false,
                castsShadow: hasShadow,
                compactShadow: false,
                tintOverride: tint,
                strokeOverride: strokeColor
            )
        )
    }

    /// 圆角矩形：卡片、面板、底栏。
    func glassRoundedRect(
        cornerRadius: CGFloat,
        tint: Color = Theme.Palette.glassTint,
        strokeColor: Color = Theme.Palette.glassStroke,
        hasShadow: Bool = false
    ) -> some View {
        modifier(
            LiquidGlassModifier(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                variant: .regular,
                isInteractive: false,
                castsShadow: hasShadow,
                compactShadow: false,
                tintOverride: tint,
                strokeOverride: strokeColor
            )
        )
    }

    /// 胶囊：Toast、人数角标、状态标签。
    func glassCapsule(
        tint: Color = Theme.Palette.glassTint,
        strokeColor: Color = Theme.Palette.glassStroke,
        hasShadow: Bool = false
    ) -> some View {
        modifier(
            LiquidGlassModifier(
                shape: Capsule(),
                variant: .regular,
                isInteractive: false,
                castsShadow: hasShadow,
                compactShadow: true,
                tintOverride: tint,
                strokeOverride: strokeColor
            )
        )
    }

    /// 圆形：顶栏的布局切换按钮。
    func glassCircle(
        tint: Color = Theme.Palette.glassTint,
        strokeColor: Color = Theme.Palette.glassStroke,
        hasShadow: Bool = false
    ) -> some View {
        modifier(
            LiquidGlassModifier(
                shape: Circle(),
                variant: .regular,
                isInteractive: false,
                castsShadow: hasShadow,
                compactShadow: true,
                tintOverride: tint,
                strokeOverride: strokeColor
            )
        )
    }
}
