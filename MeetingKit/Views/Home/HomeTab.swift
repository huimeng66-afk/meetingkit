//
//  HomeTab.swift
//  MeetingKit
//
//  首页的四个一级目的地。
//
//  为什么单独成文件：侧边栏与底部 Dock 都要读同一份标题/图标/顺序，
//  写在 HomeView 里做成 private enum 时，侧边栏只能复制一份字符串常量——
//  两处一旦不同步，就会出现"侧边栏叫企业、Dock 叫企业空间"这种低级不一致。
//
//  为什么是四个：会议、通讯录、企业、设置正好覆盖网页端侧栏的高频项，
//  又不超过 iOS 底部导航"3~5 个"的舒适区。再多人均触控宽度就会低于 44pt。
//

import Foundation

enum HomeTab: String, CaseIterable, Identifiable {

    case meetings
    case contacts
    case enterprise
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetings:
            return "会议"
        case .contacts:
            return "通讯录"
        case .enterprise:
            return "企业"
        case .settings:
            return "设置"
        }
    }

    /// 底部导航条上的短标签。
    ///
    /// 只有设置不同名：侧边栏里它是"设置"（一个功能名），底部通栏里它是"我的"
    /// （第一人称，和网页端 `.mobile-tabbar` 完全一致）。两个位置语境不同，
    /// 强行统一反而会让其中一处别扭。
    var tabBarTitle: String {
        switch self {
        case .settings:
            return "我的"
        default:
            return title
        }
    }

    /// 未选中图标。都选了 iOS 15 就存在的基线符号，不依赖 SF Symbols 5。
    var symbol: String {
        switch self {
        case .meetings:
            return SymbolCompat.name("video", "calendar")
        case .contacts:
            return SymbolCompat.name("person.2", "person.crop.circle")
        case .enterprise:
            return SymbolCompat.name("building.2", "building")
        case .settings:
            return SymbolCompat.name("gearshape", "gear")
        }
    }

    /// 选中图标。实心版本在深色玻璃上比线性图标更"亮"，一眼能看出当前位置。
    var selectedSymbol: String {
        switch self {
        case .meetings:
            return SymbolCompat.name("video.fill", "video")
        case .contacts:
            return SymbolCompat.name("person.2.fill", "person.2")
        case .enterprise:
            return SymbolCompat.name("building.2.fill", "building.2")
        case .settings:
            return SymbolCompat.name("gearshape.fill", "gearshape")
        }
    }
}
