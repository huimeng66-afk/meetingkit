//
//  HomeDock.swift
//  MeetingKit
//
//  首页悬浮 Dock：四个一级目的地，每个 tab 各自持有一块玻璃。
//
//  ── 为什么不是"一条玻璃里排四个图标" ──────────────────────────────────
//  一整块玻璃包住所有按钮是 Web toolbar 的思路：玻璃只有一层，选中态只能在
//  图标下面垫一个色块，按下去整条都不动。iOS 26 的 Liquid Glass 要求每个可交互
//  元素各自持有玻璃，再放进同一个 GlassEffectContainer —— 相邻玻璃会互相吸附、
//  选中时只有那一片液化，这才是系统相机/控制中心的手感来源。
//
//  ── 为什么是竖排图标 + 文字 ────────────────────────────────────────────
//  横排 icon+文字在四项时会把每个 tab 压到 70pt 左右，中文标签一旦变成
//  "通讯录"三个字就开始挤压；竖排是 iOS 原生 tab bar 的语言，用户不需要学习。
//
//  尺寸：64 × 50，触控区完整覆盖，SE（375pt）上四个 tab 共 274pt，仍居中。
//

import SwiftUI

struct HomeDock: View {

    @Binding var selection: HomeTab

    /// 根视图安全区底部。Dock 必须自己补，否则会压在 home indicator 上。
    var bottomInset: CGFloat = 0

    /// 重复点击当前 tab。宿主用它把列表滚回顶部（系统 tab bar 的既定行为）。
    var onReselect: (HomeTab) -> Void = { _ in }

    /// 同一个 namespace 下的玻璃才会互相吸附；缺了它，四块玻璃只是四个圆角模糊。
    @Namespace private var dockNamespace

    var body: some View {
        LiquidGlassContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(HomeTab.allCases) { tab in
                    item(tab)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, bottomInset + 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
    }

    private func item(_ tab: HomeTab) -> some View {
        let isSelected = selection == tab

        return Button {
            if isSelected {
                // 重选不切换页面，只把内容滚回顶部。给一次轻触觉，
                // 否则用户点了一下"什么都没发生"，会以为 Dock 失灵。
                Haptics.impact(.light)
                onReselect(tab)
            } else {
                Haptics.selection()
                withAnimation(Theme.Motion.standard) {
                    selection = tab
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? tab.selectedSymbol : tab.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(height: 18)

                Text(tab.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? .white : Theme.Palette.ink2)
            .frame(width: 64, height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        // 选中态用染色玻璃而不是实心色块：染色仍保留折射与高光，
        // 实心填充会把 Dock 变成四个普通按钮。
        .liquidGlass(
            isSelected ? .tinted(Theme.Palette.accent) : .regular,
            cornerStyle: .capsule,
            isInteractive: true,
            castsShadow: false
        )
        .liquidGlassID(tab.rawValue, in: dockNamespace)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct HomeDock_Previews: PreviewProvider {
    static var previews: some View {
        ZStack(alignment: .bottom) {
            BrandBackground()
            HomeDock(selection: .constant(.meetings), bottomInset: 34)
        }
        .preferredColorScheme(.dark)
    }
}
