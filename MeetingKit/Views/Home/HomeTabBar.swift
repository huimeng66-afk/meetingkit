//
//  HomeTabBar.swift
//  MeetingKit
//
//  首页底部导航 —— 一整块悬浮玻璃胶囊 + 右侧圆形主操作。
//
//  ── 形态 ────────────────────────────────────────────────────────────
//  用户要的是"一个大胶囊，可以拖着切换"，不是四块分离的小玻璃。
//  所以底座只有**一块**玻璃（`.liquidGlass(.regular, cornerStyle: .capsule)`），
//  四个 tab 均分它的宽度，选中态是里面一颗胶囊指示器。
//
//  ── 指示器为什么要"垫一层实色 + 盖一层玻璃" ──────────────────────────
//  iOS 26 的 Glass 是**折射材质**：它把背后的内容弯折、在边缘产生高光与色散。
//  只写 `Glass.regular.tint(accent)` 时，蓝色是半透明的，白字压在它上面
//  在浅色底只有 3:1 左右，10pt 的标签会糊。
//  所以指示器做成两层：底下是实色 accent（锁死对比度），上面盖一层
//  `glassEffect`（拿到系统级的边缘折射与色散）。
//  看上去仍然是"一块着了色的玻璃"，而不是一张蓝色贴纸。
//
//  ── 拖动 ────────────────────────────────────────────────────────────
//  指示器跟手位移，**越过半格就实时切换**（不等松手），带轻触感反馈。
//  松手时按最近的一格吸附。边界有阻尼，拖不出胶囊。
//  手势 `minimumDistance: 8`：轻点仍然落到下面的 Button，只有横向滑动才拖。
//
//  ── 尺寸 ────────────────────────────────────────────────────────────
//  胶囊高 62，FAB 直径 62，底边对齐。指示器左右各留 5pt，
//  393pt 屏上每个 slot 约 68pt，指示器 58×52，仍高于 44pt 触控下限。
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

    private let barHeight: CGFloat = 62
    private let indicatorInset: CGFloat = 5

    private var tabs: [HomeTab] { HomeTab.allCases }

    private var activeIndex: Int {
        tabs.firstIndex(of: selection) ?? 0
    }

    var body: some View {
        HStack(spacing: 10) {
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
            let indicatorWidth = max(slot - indicatorInset * 2, 44)

            ZStack(alignment: .leading) {
                // 一层极淡的色光，压在玻璃**里面**。
                // 纯灰底上的玻璃几乎是白的，用户看不到任何折射；
                // 有了这层冷光，边缘色散才有东西可以弯折。
                aurora

                indicator(slot: slot, width: indicatorWidth)

                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        item(tab, slot: slot)
                    }
                }
            }
            .frame(width: geo.size.width, height: barHeight)
            .contentShape(Capsule(style: .continuous))
            // simultaneousGesture 而不是 gesture：让 Button 继续接收轻点，
            // 只有位移超过 8pt 才由这里接管。
            .simultaneousGesture(dragGesture(slot: slot))
        }
        .frame(height: barHeight)
        .liquidGlass(
            .regular,
            cornerStyle: .capsule,
            isInteractive: true,
            castsShadow: true
        )
    }

    /// 玻璃内部的冷色光斑。跟着选中位置轻微游走，让"拖动"这件事在视觉上成立。
    private var aurora: some View {
        GeometryReader { geo in
            let slot = geo.size.width / CGFloat(max(tabs.count, 1))
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.16))
                    .frame(width: slot * 1.5, height: barHeight * 0.9)
                    .blur(radius: 16)
                    .offset(x: slot * CGFloat(activeIndex) + dragOffset / max(slot, 1) * slot * 0.5)

                Circle()
                    .fill(Theme.Palette.violet.opacity(0.12))
                    .frame(width: slot * 1.1, height: barHeight * 0.7)
                    .blur(radius: 18)
                    .offset(x: slot * CGFloat(activeIndex) - slot * 0.4)
            }
            .frame(width: geo.size.width, height: barHeight, alignment: .leading)
            .animation(isDragging ? nil : Theme.Motion.standard, value: activeIndex)
        }
        .allowsHitTesting(false)
    }

    /// 选中指示器：实色打底 + 系统玻璃封面。
    ///
    /// 拖动时会**横向拉伸、纵向压扁**（stretch/squash），这是参考实现里
    /// 那颗被拖动的导航胶囊最关键的一笔：真实的软物体被横向拽时会变长变薄，
    /// 只做位移不形变，看起来就是"一块贴纸在滑动"。
    /// 形变量按位移占一格的比例算，最多拉长 10pt、压扁 6%，
    /// 到达半格（切换点）时形变最大，切换后基准重置，立刻回到 1.0。
    private func indicator(slot: CGFloat, width: CGFloat) -> some View {
        let progress = min(abs(dragOffset) / max(slot, 1), 1)
        let stretch = progress * 10
        let squash = 1 - progress * 0.06

        return Capsule(style: .continuous)
            .fill(Theme.Palette.accent)
            .frame(width: width + stretch, height: (barHeight - indicatorInset * 2) * squash)
            .overlay(
                // 两层叠加，职责不同：
                //   · TabThumbGlass：iOS 26 的系统折射（低版本为空）；
                //   · 1px 渐变描边：透镜边界。没有它，纯色胶囊在玻璃底座上
                //     就是一块蓝色，拖动时看不出厚度。
                ZStack {
                    TabThumbGlass()

                    Capsule(style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.42), Color.white.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
                .allowsHitTesting(false)
            )
            .shadow(
                color: Theme.Palette.accent.opacity(0.30),
                radius: isDragging ? 14 : 8,
                x: 0,
                y: isDragging ? 6 : 3
            )
            .scaleEffect(isDragging ? 1.02 : 1.0)
            .offset(x: slot * CGFloat(activeIndex) + indicatorInset + dragOffset)
            // 拖动态不给动画：跟手要 1:1，有动画就会"追手指"。
            // 松手（dragOffset 归零）和点击切换才走 spring。
            .animation(isDragging ? nil : Theme.Motion.standard, value: activeIndex)
            .animation(isDragging ? nil : Theme.Motion.standard, value: dragOffset)
            .allowsHitTesting(false)
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
            VStack(spacing: 3) {
                Image(systemName: isSelected ? tab.selectedSymbol : tab.symbol)
                    .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                    // 选中时图标放大 6%：切换瞬间有一次可见的"弹一下"，
                    // 光靠换 symbol（实心/空心）在 19pt 上几乎看不出来。
                    .scaleEffect(isSelected ? 1.06 : 1.0)
                    .animation(GlassMotion.settle, value: isSelected)
                    .frame(height: 22)

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
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                isDragging = true
                // 边界阻尼：第一个 tab 不能再往右，最后一个不能再往左。
                let minOffset = -slot * CGFloat(activeIndex)
                let maxOffset = slot * CGFloat(max(tabs.count - 1 - activeIndex, 0))
                let clamped = min(max(value.translation.width, minOffset), maxOffset)
                dragOffset = clamped

                // 越过半格即切换：手感上是"拖着这颗胶囊换位置"，
                // 而不是"拖到一半松手才跳"。切换后重置基准，避免累积位移。
                let moved = clamped / max(slot, 1)
                if moved > 0.5, activeIndex < tabs.count - 1 {
                    Haptics.selection()
                    selection = tabs[activeIndex + 1]
                    dragOffset = clamped - slot
                } else if moved < -0.5, activeIndex > 0 {
                    Haptics.selection()
                    selection = tabs[activeIndex - 1]
                    dragOffset = clamped + slot
                }
            }
            .onEnded { _ in
                isDragging = false
                // 松手吸附：位移不足半格就弹回原位。
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
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(Theme.Palette.onAccent)
                .frame(width: 62, height: 62)
                .contentShape(Circle())
        }
        .buttonStyle(HomeTabFABButtonStyle())
        .accessibilityLabel("发起会议")
    }
}

// MARK: - 指示器封面玻璃

/// 盖在实色 accent 上的系统玻璃。
///
/// 存在的意义只有一条：拿到 iOS 26 的折射与边缘色散。
/// 它必须**不参与命中测试**——否则拖动指示器时手势会被它吃掉。
private struct TabThumbGlass: View {
    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(Color.clear)
                .glassEffect(
                    Glass.regular.tint(Theme.Palette.accent.opacity(0.55)),
                    in: Capsule(style: .continuous)
                )
                .allowsHitTesting(false)
        } else {
            EmptyView()
        }
        #else
        EmptyView()
        #endif
    }
}

// MARK: - 样式

/// tab 的按压缩放。玻璃在底座上，这里只管手感，不再叠第二层玻璃。
///
/// 用 GlassMotion 的欠阻尼曲线（0.62）而不是 Theme.Motion.snappy（0.9）：
/// 松手时那一下过冲正是"胶囊被捏了一下"的来源，用高阻尼会变成软塌塌的收缩。
private struct TabPressStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(
                configuration.isPressed ? GlassMotion.press : GlassMotion.settle,
                value: configuration.isPressed
            )
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
