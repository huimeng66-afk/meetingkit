//
//  HomeTabBar.swift
//  MeetingKit
//
//  首页底部导航 —— 一整块悬浮玻璃胶囊 + 右侧圆形主操作。
//
//  ── 形态 ────────────────────────────────────────────────────────────
//  用户要的是"一个大胶囊，可以拖着切换"，不是四块分离的小玻璃。
//  所以底座只有**一块**玻璃（`.liquidGlass(.regular, cornerStyle: .capsule)`），
//  四个 tab 均分它的宽度，选中态是里面一颗实色指示器。
//
//  ── 为什么指示器不用 prominentGlass ─────────────────────────────────
//  它是压在玻璃底座**上面**的一层。两层玻璃叠在一起会互相采样，
//  白玻璃底 + 半透明蓝的结果是发灰的紫，白字对比度只剩 3:1 左右。
//  浅色主题下直接给不透明的 accent（与网页端按钮同色 #1677ff），
//  白字稳定在 4.6:1，也和网页端的"当前项"完全一致。
//
//  ── 拖动 ────────────────────────────────────────────────────────────
//  指示器跟手位移，松手按"过半格"判定切不切。边界做了阻尼（拖不出胶囊）。
//  手势挂在底座上、`minimumDistance: 12`：轻点仍然落到下面的 Button，
//  只有真正的横向滑动才进入拖动态，两者不打架。
//
//  ── 尺寸 ────────────────────────────────────────────────────────────
//  胶囊高 58，FAB 直径 58，底边对齐。指示器左右各留 6pt，
//  393pt 屏上每个 slot 约 68pt，指示器 56×46，仍高于 44pt 触控下限。
//

import SwiftUI

struct HomeTabBar: View {

    @Binding var selection: HomeTab

    /// 根视图安全区底部。Dock 自己补这一段，才能浮在 home indicator 上方。
    var bottomInset: CGFloat = 0

    /// 重复点击当前 tab：宿主用它把列表滚回顶部（系统 tab bar 的既定行为）。
    var onReselect: (HomeTab) -> Void = { _ in }

    /// 是否显示右侧的"发起会议"圆钮。
    /// 通讯录/企业/设置页没有"在这里开会"的上下文，全局常驻会让用户误触。
    var showsStartMeeting: Bool = true

    /// 右侧圆形主操作。
    var onStartMeeting: () -> Void = {}

    /// 拖动时指示器相对选中槽位的位移。
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    private let barHeight: CGFloat = 58
    private let indicatorInset: CGFloat = 6

    private var tabs: [HomeTab] { HomeTab.allCases }

    private var activeIndex: Int {
        tabs.firstIndex(of: selection) ?? 0
    }

    var body: some View {
        HStack(spacing: 8) {
            tabCapsule

            if showsStartMeeting {
                startMeetingButton
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, bottomInset + 10)
        .animationCompat(Theme.Motion.standard, value: showsStartMeeting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
    }

    // MARK: - 玻璃胶囊

    private var tabCapsule: some View {
        GeometryReader { geo in
            let count = CGFloat(max(tabs.count, 1))
            let slot = geo.size.width / count
            let indicatorWidth = max(slot - indicatorInset * 2, 40)

            ZStack(alignment: .leading) {
                // 选中指示器：实色，压在玻璃之上。
                Capsule(style: .continuous)
                    .fill(Theme.Palette.accent)
                    .frame(width: indicatorWidth, height: barHeight - indicatorInset * 2)
                    .offset(x: slot * CGFloat(activeIndex) + indicatorInset + dragOffset)
                    .shadow(
                        color: Theme.Palette.accent.opacity(0.28),
                        radius: 10,
                        x: 0,
                        y: 4
                    )
                    // 拖动态不给动画：跟手要 1:1，有动画就会"追手指"。
                    // 松手（dragOffset 归零）和点击切换才走 spring。
                    .animation(isDragging ? nil : Theme.Motion.standard, value: activeIndex)
                    .animation(isDragging ? nil : Theme.Motion.standard, value: dragOffset)

                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        item(tab, slot: slot)
                    }
                }
            }
            .frame(width: geo.size.width, height: barHeight)
            .contentShape(Capsule(style: .continuous))
            // simultaneousGesture 而不是 gesture：让 Button 继续接收轻点，
            // 只有位移超过 12pt 才由这里接管。
            .simultaneousGesture(dragGesture(slot: slot))
        }
        .frame(height: barHeight)
        .liquidGlass(
            .regular,
            cornerStyle: .capsule,
            isInteractive: false,
            castsShadow: true
        )
    }

    // MARK: - 单个 tab

    private func item(_ tab: HomeTab, slot: CGFloat) -> some View {
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
            // 选中态压在实色 accent 上 → 白字；未选中压在玻璃上 → 次级灰。
            .foregroundColor(isSelected ? Theme.Palette.onAccent : Theme.Palette.ink2)
            .frame(width: slot, height: barHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(TabPressStyle())
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 拖动

    private func dragGesture(slot: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                isDragging = true
                // 边界阻尼：第一个 tab 不能再往右，最后一个不能再往左。
                let minOffset = -slot * CGFloat(activeIndex)
                let maxOffset = slot * CGFloat(max(tabs.count - 1 - activeIndex, 0))
                dragOffset = min(max(value.translation.width, minOffset), maxOffset)
            }
            .onEnded { value in
                isDragging = false
                let moved = value.translation.width / max(slot, 1)

                var target = activeIndex
                if moved > 0.5 {
                    target = min(activeIndex + 1, tabs.count - 1)
                } else if moved < -0.5 {
                    target = max(activeIndex - 1, 0)
                }

                if target != activeIndex {
                    Haptics.selection()
                    selection = tabs[target]
                }
                withAnimation(Theme.Motion.standard) {
                    dragOffset = 0
                }
            }
    }

    // MARK: - 主操作

    private var startMeetingButton: some View {
        Button {
            Haptics.impact(.medium)
            onStartMeeting()
        } label: {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Theme.Palette.onAccent)
                .frame(width: 58, height: 58)
                .contentShape(Circle())
        }
        .buttonStyle(HomeTabFABButtonStyle())
        .accessibilityLabel("发起会议")
    }
}

// MARK: - 样式

/// tab 的按压缩放。玻璃在底座上，这里只管手感，不再叠第二层玻璃。
private struct TabPressStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animationCompat(Theme.Motion.snappy, value: configuration.isPressed)
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
        .preferredColorScheme(.light)
    }
}
