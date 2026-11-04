//
//  HomeTabBar.swift
//  MeetingKit
//
//  首页底部 Dock —— 对齐系统「电话」App 的悬浮玻璃胶囊。
//
//  ── 结构（按用户提供的系统截图复刻）────────────────────────────────
//  左侧是一整块连续玻璃胶囊，四个目的地等分排在内部；
//  选中项不是"变个颜色"，而是在胶囊内部浮起一枚更亮的子胶囊，
//  图标与文字同时变蓝 —— 这样一眼能看出"我在哪"，也不需要额外的选中色块。
//  右侧是独立的圆形按钮，承载"发起会议"这个主操作。
//
//  ── 为什么不是通栏 ──────────────────────────────────────────────────
//  上一版做成了贴着屏幕底边的通栏 tab bar，理由是"和网页端一致"。
//  但用户给的参考是 iOS 系统电话 App：悬浮、离底边有间距、内容从玻璃下面穿过。
//  悬浮胶囊还有一个实际好处——它不吞掉底部 56pt 的整条区域，
//  列表最后一行可以滚到胶囊下面，而不是被一条不透明横条永远挡住。
//
//  ── 尺寸 ────────────────────────────────────────────────────────────
//  胶囊高 62（内容 52 + 上下 5），FAB 直径 60。
//  iPhone 393pt：393 - 28(边距) - 10(间距) - 60(FAB) = 295，四等分每项 73pt，
//  远高于 44pt 的触控下限；SE 375pt 上每项仍有 69pt。
//

import SwiftUI

struct HomeTabBar: View {

    @Binding var selection: HomeTab

    /// 根视图安全区底部。Dock 自己补这一段，才能浮在 home indicator 上方。
    var bottomInset: CGFloat = 0

    /// 重复点击当前 tab：宿主用它把列表滚回顶部（系统 tab bar 的既定行为）。
    var onReselect: (HomeTab) -> Void = { _ in }

    /// 右侧圆形主操作。
    var onStartMeeting: () -> Void = {}

    /// 选中子胶囊在四个位置之间滑动，而不是淡入淡出。
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 10) {
            tabCluster
            startMeetingButton
        }
        .padding(.horizontal, 14)
        .padding(.bottom, bottomInset + 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
    }

    // MARK: - 胶囊

    private var tabCluster: some View {
        HStack(spacing: 0) {
            ForEach(HomeTab.allCases) { tab in
                item(tab)
            }
        }
        .padding(5)
        // 一整块玻璃，而不是四块各自带玻璃。
        // 四块独立玻璃在深色底上会互相折射出一圈灰边，看起来像四个按钮贴在一起；
        // 一整块才符合系统电话 App 的"一个容器 + 内部选中项"的层级。
        .liquidGlass(.regular, cornerStyle: .capsule, castsShadow: true)
    }

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
            VStack(spacing: 3) {
                Image(systemName: isSelected ? tab.selectedSymbol : tab.symbol)
                    .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                    .frame(height: 23)

                Text(tab.tabBarTitle)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(isSelected ? Theme.Palette.accent : Theme.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background {
                if isSelected {
                    // 选中子胶囊。白色 0.14 在深色玻璃上刚好是"比周围亮一档"，
                    // 再高会变成实心白块，再低则看不出边界。
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.14))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                        )
                        .matchedGeometryEffect(id: "tab.selection", in: selectionNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
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
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Theme.Palette.brandGradient))
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.34), radius: 12, x: 0, y: 6)
                .contentShape(Circle())
        }
        .buttonStyle(ControlButtonPressStyle())
        .accessibilityLabel("发起会议")
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
