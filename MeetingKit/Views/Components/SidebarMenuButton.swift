//
//  SidebarMenuButton.swift
//  MeetingKit
//
//  一级页面右上角的侧边栏入口。
//
//  为什么不做成全局悬浮按钮：企业空间与设置页都有自己的大标题与页内动作
//  （刷新、编辑），悬浮按钮会和它们抢位置。把入口放进页头的右上角，
//  既符合 iOS "导航动作在右上"的惯例，也不会挡住内容。
//
//  为什么图标用 sidebar.left 而不是三条横线：HIG 明确不推荐汉堡图标，
//  它能表达的只有"这里有菜单"，不能表达"从左侧滑出"。sidebar.left 是
//  系统自带的侧栏语义图标，VoiceOver 读出来也是 "sidebar"。
//

import SwiftUI

struct SidebarMenuButton: View {

    var action: () -> Void

    var body: some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Image(systemName: SymbolCompat.name("sidebar.left", "rectangle.lefthalf.inset.filled"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.Palette.ink2)
                .frame(width: 36, height: 36)
                .liquidGlass(.regular, cornerStyle: .circle, isInteractive: true, castsShadow: false)
                // 视觉 36、命中 44：右上角紧邻刷新按钮，太小的命中区容易误触。
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(LiquidPressStyle(pressedScale: 0.985, highlight: 0))
        .accessibilityLabel("打开导航菜单")
    }
}
