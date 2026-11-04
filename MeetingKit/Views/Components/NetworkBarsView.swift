//
//  NetworkBarsView.swift
//  MeetingKit
//
//  三格网络信号。格数直接来自 `NetworkQuality.bars`，
//  这样顶栏、成员列表等任何位置对"当前网络"的表述都不会互相矛盾。
//

import SwiftUI

struct NetworkBarsView: View {

    let quality: NetworkQuality

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            // 常量区间用 id: \.self 显式声明，避免依赖 Range 的隐式 Identifiable 推断。
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(barColor(at: index))
                    .frame(width: 3, height: CGFloat(5 + index * 3))
            }
        }
        .frame(height: 12, alignment: .bottom)
        .accessibilityLabel(accessibilityText)
    }

    private func barColor(at index: Int) -> Color {
        guard index < quality.bars else {
            // 未点亮的格子保留一点亮度，否则在纯黑画面上整组会消失。
            return Color.white.opacity(0.22)
        }
        if case .poor = quality {
            return Theme.Palette.warning
        }
        return Color.white.opacity(0.9)
    }

    private var accessibilityText: String {
        if case .poor = quality {
            return "网络较差"
        }
        switch quality.bars {
        case 3:
            return "网络良好"
        case 2:
            return "网络一般"
        default:
            return "网络状态未知"
        }
    }
}

struct NetworkBarsView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.background
            HStack(spacing: 20) {
                NetworkBarsView(quality: .good)
                NetworkBarsView(quality: .fair)
                NetworkBarsView(quality: .poor)
                NetworkBarsView(quality: .unknown)
            }
        }
        .preferredColorScheme(.dark)
    }
}
