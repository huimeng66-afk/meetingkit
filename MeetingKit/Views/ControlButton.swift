//
//  ControlButton.swift
//  MeetingKit
//
//  会议室底栏单键：一颗纯图标玻璃圆钮 + 右上角角标。
//
//  ── 为什么去掉 10pt 文字标签 ────────────────────────────────────────
//  7 个键挤在 393pt 宽度里，每键只有 52pt。图标下面再塞一行 10pt 中文，
//  既压不出留白，也让整条底栏看起来像"工具栏"而不是系统控件。
//  iOS 26 之后苹果自己的通话界面（FaceTime / 电话）都是纯图标 + 无障碍标签，
//  语义交给 VoiceOver，视觉交给 SF Symbols —— 这才是原生观感。
//
//  外观只剩两种：常态玻璃、警示着色玻璃（麦克风关闭 / 共享中）。
//  全部走 `liquidGlass`，在 iOS 26 上是系统 `glassEffect`，
//  和底栏容器的其它玻璃会自然融合。
//

import SwiftUI

// MARK: - 外观

/// 底栏按钮的状态语义。调用方只表达"现在是什么状态"，具体色值不外泄。
enum ControlButtonAppearance: Equatable {
    case neutral
    case off
    case broadcast
}

// MARK: - 按钮

struct ControlButton: View {

    let systemImage: String
    let title: String

    var appearance: ControlButtonAppearance = .neutral

    /// 圆钮直径。底栏默认 46：7 颗 × 46 + 6 段间距刚好落在 375pt 的安全区内。
    var size: CGFloat = 46

    /// 数字角标（成员人数）。传 nil 不显示。
    var badgeText: String? = nil
    /// SF Symbol 角标（举手 hand.raised.fill）。传 nil 不显示。
    var badgeSymbol: String? = nil
    /// 小红点（录制中）。
    var badgeDot: Bool = false

    /// 朗读用的完整语义。nil 时回退到 title。
    var accessibilityText: String? = nil

    var action: () -> Void

    var body: some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: size, height: size)
                    .liquidGlass(
                        glassVariant,
                        cornerStyle: .circle,
                        isInteractive: true,
                        castsShadow: false
                    )
                    .contentShape(Circle())

                badgeLayer
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(ControlButtonPressStyle())
        .accessibilityLabel(accessibilityText ?? title)
    }

    // MARK: - 着色

    /// 只保留"常态 / 警示"两档语义，颜色差异全部交给玻璃的 tint，
    /// 不再自己画填充 + 描边（那是塑料感的来源）。
    private var glassVariant: LiquidGlassVariant {
        switch appearance {
        case .neutral:
            return .regular
        case .off:
            return .tinted(Theme.Palette.danger)
        case .broadcast:
            return .tinted(Theme.Palette.danger)
        }
    }

    private var iconColor: Color {
        switch appearance {
        case .neutral:
            return Theme.Palette.textPrimary
        case .off:
            return Color(hex: 0xFCA5A5)
        case .broadcast:
            return .white
        }
    }

    // MARK: - 角标

    @ViewBuilder
    private var badgeLayer: some View {
        if let badgeText = badgeText {
            Text(badgeText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 17, minHeight: 17)
                .background(Capsule().fill(Theme.Palette.accent))
                // 描边用页面底色：角标压在圆钮上时能"浮"起来，不糊成一团。
                .overlay(Capsule().stroke(Theme.Palette.background, lineWidth: 1.5))
                .offset(x: 3, y: -2)
        } else if let symbol = badgeSymbol {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Palette.accent)
                .padding(3)
                .background(Circle().fill(Theme.Palette.background.opacity(0.9)))
                .offset(x: 3, y: -2)
        } else if badgeDot {
            Circle()
                .fill(Theme.Palette.danger)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Theme.Palette.background, lineWidth: 1.5))
                .offset(x: 2, y: 0)
        }
    }
}

// MARK: - 按压回弹

/// 会议里所有圆钮共用这一档手感：按下缩到 0.94，松手弹回。
struct ControlButtonPressStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animationCompat(Theme.Motion.standard, value: configuration.isPressed)
    }
}

struct ControlButton_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.background
            HStack(spacing: 8) {
                ControlButton(
                    systemImage: SymbolCompat.name("mic.slash.fill", "mic.slash"),
                    title: "取消静音",
                    appearance: .off
                ) {}
                ControlButton(systemImage: SymbolCompat.name("video.fill"), title: "摄像头") {}
                ControlButton(
                    systemImage: SymbolCompat.name(
                        "rectangle.inset.filled.and.person.filled",
                        "rectangle.on.rectangle"
                    ),
                    title: "停止共享",
                    appearance: .broadcast
                ) {}
                ControlButton(
                    systemImage: SymbolCompat.name("person.2.fill", "person.2"),
                    title: "成员",
                    badgeText: "12"
                ) {}
                ControlButton(
                    systemImage: SymbolCompat.name("ellipsis", "ellipsis.circle"),
                    title: "更多",
                    badgeSymbol: "hand.raised.fill"
                ) {}
            }
        }
        .preferredColorScheme(.dark)
    }
}
