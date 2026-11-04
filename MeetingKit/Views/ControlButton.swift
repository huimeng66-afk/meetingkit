//
//  ControlButton.swift
//  MeetingKit
//
//  会议室底栏单键：玻璃圆钮 + 文字标签 + 右上角角标。
//
//  ── 为什么加回文字标签 ──────────────────────────────────────────────
//  上一版按"苹果通话界面都是纯图标"的判断去掉了文字，结果用户完全认不出
//  7 颗一模一样的圆钮分别是什么，只能逐个点开试——这是可用性问题，不是审美问题。
//  系统电话/FaceTime 的图标之所以能省文字，是因为它们只有 3~4 颗、且图标语义极强；
//  7 颗里同时出现"安全/邀请/成员/共享/更多"时，没有任何用户能靠图标分辨。
//  所以文字必须回来：9.5pt、单行、不参与玻璃，颜色跟随状态。
//
//  ── 视觉分级 ────────────────────────────────────────────────────────
//  七个键不再共用一种外观：
//    · 共享：常驻强调色玻璃（蓝色），是底栏唯一的主操作；
//    · 麦克风/摄像头：关闭时红色染色玻璃，状态一眼可见；
//    · 其余：中性玻璃。
//  同一种玻璃重复七次，用户会以为整条底栏是一个控件。
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
    var isPrimary: Bool = false

    /// 圆钮直径。底栏 40：7 颗并排后每颗仍有约 51pt 的横向命中区，
    /// 圆钮本身 40 也高于 40pt 的可用下限，手指不会点到隔壁。
    var size: CGFloat = 40

    /// 数字角标（成员人数）。传 nil 不显示。
    var badgeText: String? = nil
    /// SF Symbol 角标（举手 hand.raised.fill）。传 nil 不显示。
    var badgeSymbol: String? = nil
    /// 小红点（录制中）。
    var badgeDot: Bool = false

    /// 是否显示圆钮下方的文字。默认显示：见文件头的可用性说明。
    var showsTitle: Bool = true

    /// 朗读用的完整语义。nil 时回退到 title。
    var accessibilityText: String? = nil

    var action: () -> Void

    var body: some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
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

                if showsTitle {
                    Text(title)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(titleColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlButtonPressStyle())
        .accessibilityLabel(accessibilityText ?? title)
    }

    // MARK: - 着色

    /// 只保留"常态 / 警示 / 主操作"三档语义，颜色差异全部交给玻璃的 tint。
    private var glassVariant: LiquidGlassVariant {
        switch appearance {
        case .neutral:
            return isPrimary ? .tinted(Theme.Palette.accent) : .regular
        case .off:
            return .tinted(Theme.Palette.danger)
        case .broadcast:
            return .tinted(Theme.Palette.danger)
        }
    }

    private var iconColor: Color {
        switch appearance {
        case .neutral:
            return isPrimary ? .white : Theme.Palette.textPrimary
        case .off:
            return Color(hex: 0xFCA5A5)
        case .broadcast:
            return .white
        }
    }

    /// 文字压在页面底色上，不能沿用图标的白/粉：
    /// 9.5pt 的白字在深背景上会散光，反而不如次级灰好读。
    private var titleColor: Color {
        switch appearance {
        case .neutral:
            return isPrimary ? Theme.Palette.accent : Theme.Palette.textSecondary
        case .off, .broadcast:
            return Color(hex: 0xFCA5A5)
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
            HStack(spacing: 0) {
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
                    title: "共享",
                    isPrimary: true
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
            .padding(.horizontal, 8)
        }
        .preferredColorScheme(.dark)
    }
}
