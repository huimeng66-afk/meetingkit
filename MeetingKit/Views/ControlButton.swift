//
//  ControlButton.swift
//  MeetingKit
//
//  底栏单键：48pt 圆形容器 + 10pt 标签 + 右上角角标。
//
//  三套外观集中在这里，避免底栏调用点各写一套填充/描边：
//    · neutral   —— 白 6% 玻璃圆盘（白 6% 填充 + 玻璃描边）
//    · off       —— 麦克风/摄像头关闭：danger 16% 填充 + danger 32% 描边 + #FCA5A5
//    · broadcast —— 屏幕共享中：danger 实心 + 白字 + 红色光晕
//
//  命中区：整颗按钮（圆盘 + 标签）都用 contentShape(Rectangle()) 包住，
//  实际可点面积 ≥ 48×56，满足设计规范对触控目标的硬要求。
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
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    iconDisc
                    badgeLayer
                }

                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(labelColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlButtonPressStyle())
        .accessibilityLabel(accessibilityText ?? title)
    }

    // MARK: - 圆盘

    private var iconDisc: some View {
        ZStack {
            Circle()
                .fill(discFill)
                .overlay(Circle().stroke(discStroke, lineWidth: 1))

            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(iconColor)
        }
        .frame(width: 48, height: 48)
        .shadow(
            color: appearance == .broadcast ? Theme.Palette.danger.opacity(0.55) : Color.clear,
            radius: appearance == .broadcast ? 8 : 0,
            x: 0,
            y: 0
        )
    }

    private var discFill: Color {
        switch appearance {
        case .neutral:
            return Color.white.opacity(0.06)
        case .off:
            return Theme.Palette.danger.opacity(0.16)
        case .broadcast:
            return Theme.Palette.danger
        }
    }

    private var discStroke: Color {
        switch appearance {
        case .neutral:
            return Theme.Palette.glassStroke
        case .off:
            return Theme.Palette.danger.opacity(0.32)
        case .broadcast:
            return Color.white.opacity(0.18)
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

    private var labelColor: Color {
        switch appearance {
        case .neutral:
            return Theme.Palette.textSecondary
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
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(Color(hex: 0x4F8CFF)))
                // 描边用页面底色：角标压在圆盘上时能"浮"起来，不糊成一团。
                .overlay(Capsule().stroke(Theme.Palette.background, lineWidth: 1.5))
                .offset(x: 4, y: -2)
        } else if let symbol = badgeSymbol {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.Palette.accent)
                .padding(3)
                .background(Circle().fill(Theme.Palette.background.opacity(0.9)))
                .overlay(Circle().stroke(Theme.Palette.glassStroke, lineWidth: 1))
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
