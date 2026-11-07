//
//  SearchField.swift
//  MeetingKit
//
//  搜索框。系统没有"可控深色玻璃样式"的搜索框（`searchable` 是 15 起且样式不可控），
//  会议面板里又是一个自绘抽屉，所以这里手写一个更稳。
//

import SwiftUI

struct SearchField: View {

    var placeholder: String = "搜索参会人"
    @Binding var text: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Metrics.space2) {
            Image(systemName: SymbolCompat.name("magnifyingglass"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Palette.textTertiary)

            ZStack(alignment: .leading) {
                // TextField 的占位符无法单独指定颜色，用一层 Text 覆盖得到设计稿里的三級灰。
                if text.isEmpty {
                    Text(placeholder)
                        .font(Theme.Typography.body)
                        .foregroundColor(Theme.Palette.textTertiary)
                }
                TextField("", text: $text)
                    .focused($isFocused)
                    .accessibilityLabel(placeholder)
                    .submitLabel(.search)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Palette.textPrimary)
                    .accentColor(Theme.Palette.accent)
            }

            if !text.isEmpty {
                Button {
                    Haptics.selection()
                    text = ""
                } label: {
                    Image(systemName: SymbolCompat.name("xmark.circle.fill", "xmark.circle"))
                        .font(.system(size: 14))
                        .foregroundColor(Theme.Palette.textTertiary)
                        // 图标只有 14pt，直接当命中区很难点中；
                        // 补到 32×32 并用矩形 contentShape 把整个方形都变成可点区域。
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(LiquidPressStyle(pressedScale: 0.985, highlight: 0))
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, Theme.Metrics.space3)
        .frame(minHeight: 48)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.surfaceSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isFocused ? Theme.Palette.accent : Theme.Palette.hairline, lineWidth: isFocused ? 1.5 : 1)
        )
        .animation(Theme.Motion.snappy, value: isFocused)
    }
}

struct SearchField_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.background
            SearchField(text: .constant(""))
                .padding()
        }
        .preferredColorScheme(.dark)
    }
}
