//
//  HomeTabBar.swift
//  MeetingKit
//
//  首页底部导航 —— 四个独立悬浮的 Liquid Glass 按钮。
//
//  ── 为什么是"四块独立玻璃"而不是一整条 tab bar ────────────────────────
//  系统默认 TabView 在 iOS 26 上会把整条 tab bar 渲染成一整块玻璃底板，
//  四个图标只是底板上的文字。这里要的是苹果「电话」App 那种观感：
//  每个入口自己是一块玻璃，块与块之间留出真实缝隙，下面的内容从缝隙里透出来。
//  所以完全不用 TabView，也不给 HStack 加任何整块背景，
//  每一块的玻璃都由自己的 `.liquidGlass` / `.prominentGlass()` 负责。
//
//  ── 选中态 ──────────────────────────────────────────────────────────
//  未选中：`.liquidGlass(.regular)`，图标文字是次级灰，玻璃退到背景层。
//  选中：`.prominentGlass()`，系统级强调玻璃（accent tint + 按下形变），
//        图标文字转白。选中不是"多一个色块"，而是这块玻璃本身变得更实、更亮。
//
//  ── 尺寸 ────────────────────────────────────────────────────────────
//  tab 块高 58，FAB 直径 58，两者底边对齐。
//  iPhone 393pt：393 − 28(边距) − 10(FAB 间距) − 58(FAB) − 24(三处 8pt 缝)
//  = 273，四等分每块 68pt，高于 44pt 触控下限；SE 375pt 上仍有 63pt。
//

import SwiftUI

struct HomeTabBar: View {

    @Binding var selection: HomeTab

    /// 根视图安全区底部。Dock 自己补这一段，才能浮在 home indicator 上方。
    var bottomInset: CGFloat = 0

    /// 重复点击当前 tab：宿主用它把列表滚回顶部（系统 tab bar 的既定行为）。
    var onReselect: (HomeTab) -> Void = { _ in }

    /// 是否显示右侧的"发起会议"圆钮。
    /// 通讯录/企业/设置页没有"在这里开会"的上下文，
    /// 全局常驻会让用户在别人的企业页里误触，所以由宿主按 tab 决定。
    var showsStartMeeting: Bool = true

    /// 右侧圆形主操作。
    var onStartMeeting: () -> Void = {}

    var body: some View {
        // spacing 传 0：GlassEffectContainer 只在元素间距小于该值时把玻璃吸附融合。
        // 我们要的是"独立"，所以这里必须小于实际的 8pt 缝隙。
        // 仍然套容器，是因为同屏多块玻璃需要在同一个容器里才能正确采样背景。
        LiquidGlassContainer(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(HomeTab.allCases) { tab in
                    item(tab)
                }

                if showsStartMeeting {
                    startMeetingButton
                        .padding(.leading, 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animationCompat(Theme.Motion.standard, value: showsStartMeeting)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, bottomInset + 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
    }

    // MARK: - Tab 块

    private func item(_ tab: HomeTab) -> some View {
        let isSelected = selection == tab

        return Button {
            if isSelected {
                onReselect(tab)
                Haptics.impact(.light)
            } else {
                Haptics.selection()
                withAnimation(Theme.Motion.standard) {
                    selection = tab
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: isSelected ? tab.selectedSymbol : tab.symbol)
                    .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                    .frame(height: 21)

                Text(tab.tabBarTitle)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            // 选中时白字压在 accent 玻璃上；未选中用次级灰，让玻璃本身保持安静。
            .foregroundColor(isSelected ? .white : Theme.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(HomeTabGlassButtonStyle(isSelected: isSelected))
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 主操作

    private var startMeetingButton: some View {
        Button {
            Haptics.impact(.medium)
            onStartMeeting()
        } label: {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 58, height: 58)
                .contentShape(Circle())
        }
        .buttonStyle(HomeTabFABButtonStyle())
        .accessibilityLabel("发起会议")
    }
}

// MARK: - 样式

/// 单个 tab 的玻璃。选中 → 强调玻璃，未选中 → 常规玻璃。
///
/// 玻璃必须挂在 ButtonStyle 里、包住整个 label，而不是挂在 label 的 VStack 上：
/// 前者让 58pt 整块都可点，后者只有图标和文字本身可点，缝隙里点下去会穿透。
private struct HomeTabGlassButtonStyle: ButtonStyle {

    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .liquidGlassOrProminent(isSelected)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animationCompat(Theme.Motion.standard, value: configuration.isPressed)
    }
}

private extension View {

    /// 把「选中 / 未选中」收在一处，避免 ButtonStyle 里出现两套重复的玻璃参数。
    @ViewBuilder
    func liquidGlassOrProminent(_ isSelected: Bool) -> some View {
        if isSelected {
            self.prominentGlass(
                cornerStyle: .capsule,
                isInteractive: true,
                castsShadow: true
            )
        } else {
            self.liquidGlass(
                .regular,
                cornerStyle: .capsule,
                isInteractive: true,
                castsShadow: true
            )
        }
    }
}

private struct HomeTabFABButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .prominentGlass(
                cornerStyle: .circle,
                isInteractive: true,
                castsShadow: true
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animationCompat(Theme.Motion.standard, value: configuration.isPressed)
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
