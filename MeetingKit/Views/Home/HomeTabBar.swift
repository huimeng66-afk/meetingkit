//
//  HomeTabBar.swift
//  MeetingKit
//
//  首页底部导航条 —— 与网页端 `.mobile-tabbar` 同构。
//
//  ── 为什么从"悬浮玻璃胶囊"换成通栏 tab bar ──────────────────────────
//  上一版是四块独立玻璃浮在内容之上，视觉上确实像 iOS 26 的 Dock，但它有三个
//  实际问题：一，玻璃的折射与高光会随下层内容变化，深色页面上看起来是一团发灰
//  的雾；二，四块胶囊之间只有 6pt 缝隙，误触率高；三，文字被压到 9.5pt，中文
//  在这个尺寸下几乎糊成一团。网页端那条件条 —— 通栏、发丝线上边、20pt 图标
//  加 10.5pt 文字、选中变蓝 —— 反而更清楚、更好点，这也是用户明确要的样子。
//
//  ── 尺寸 ────────────────────────────────────────────────────────────
//  内容区 56pt（与网页端一致）+ 安全区。SE（375pt）上四项各 93.75pt，
//  远超 44pt 触控下限；横屏时同样按四等分，不会出现某一项被挤成图标条。
//

import SwiftUI

struct HomeTabBar: View {

    @Binding var selection: HomeTab

    /// 根视图安全区底部。导航条自己补这一段，才不会压在 home indicator 上。
    var bottomInset: CGFloat = 0

    /// 重复点击当前 tab：宿主用它把列表滚回顶部（系统 tab bar 的既定行为）。
    var onReselect: (HomeTab) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeTab.allCases) { tab in
                item(tab)
            }
        }
        .frame(height: 56)
        .padding(.bottom, bottomInset)
        .background(barBackground)
        .overlay(alignment: .top) {
            // 发丝线：网页端用 border-top，这里用 0.5pt 的高度画一条。
            // 用 Rectangle 而不是 Divider，避免 Divider 在深色下自带缩进与更粗的灰。
            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
    }

    // MARK: - 单项

    private func item(_ tab: HomeTab) -> some View {
        let isSelected = selection == tab

        return Button {
            if isSelected {
                // 重选不切换页面，只把内容滚回顶部。给一次轻触觉，
                // 否则用户点了一下"什么都没发生"，会以为导航条失灵。
                onReselect(tab)
                Haptics.impact(.light)
            } else {
                Haptics.selection()
                withAnimation(Theme.Motion.standard) {
                    selection = tab
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? tab.selectedSymbol : tab.symbol)
                    .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                    .frame(height: 22)

                Text(tab.tabBarTitle)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            // 选中只改颜色和字重，不垫色块：网页端就是这么做的，
            // 底部通栏里再出现一个圆角选中块，会立刻变回"四个按钮"。
            .foregroundColor(isSelected ? Theme.Palette.accent : Theme.Palette.ink3)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 底

    /// 半透明材质 + 底色压暗。
    ///
    /// 只用 material 时，深空底透上来会偏灰；只用纯色又会挡住下方滚动的画面，
    /// 失去"内容从底下穿过"的层次。两层叠加同时保住对比度与通透感。
    private var barBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Theme.Palette.background.opacity(0.72)
        }
    }
}

struct HomeTabBar_Previews: PreviewProvider {
    static var previews: some View {
        ZStack(alignment: .bottom) {
            BrandBackground()
            HomeTabBar(selection: .constant(.meetings), bottomInset: 34)
        }
        .preferredColorScheme(.dark)
    }
}
