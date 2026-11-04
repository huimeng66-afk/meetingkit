//
//  ToastView.swift
//  MeetingKit
//
//  轻提示。会议里所有"操作已生效"的反馈都走这里，
//  因此样式必须足够克制：一条胶囊、一个图标、一句话，2s 后自动消失。
//
//  自动消失的计时放在 ViewModel（toast 是 @Published，由 VM 清空），
//  视图只负责渲染与进出动画，避免出现两份计时器互相打架。
//

import SwiftUI

struct ToastView: View {

    let message: ToastMessage

    var body: some View {
        HStack(spacing: Theme.Metrics.space2) {
            Image(systemName: SymbolCompat.name(message.systemImage, "info.circle"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tintColor)

            Text(message.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, Theme.Metrics.space4)
        .padding(.vertical, Theme.Metrics.space2 + 2)
        .liquidGlass(.clear, cornerStyle: .capsule, castsShadow: true)
    }

    /// 颜色只表达语义强弱，文案本身由调用方决定。
    private var tintColor: Color {
        switch message.style {
        case .info:
            return Theme.Palette.accent
        case .success:
            return Theme.Palette.success
        case .warning:
            return Theme.Palette.warning
        case .danger:
            return Theme.Palette.danger
        }
    }
}

struct ToastView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.tileBackground
            VStack(spacing: 12) {
                ToastView(message: .micMuted(true))
                ToastView(message: .screenShareStarted())
                ToastView(message: .networkPoor())
                ToastView(message: ToastMessage(
                    text: "会议已结束",
                    systemImage: "phone.down.fill",
                    style: .danger
                ))
            }
        }
        .preferredColorScheme(.dark)
    }
}
