//
//  MeetingKitApp.swift
//  MeetingKit
//
//  App 入口只做装配：
//  WindowGroup → AppRootView（首页 / 入会页 / 会议室三阶段路由）。
//  全局强制深色——天穹是深空蓝唯一形态，浅色系统设置不能把首页刷成白底。
//

import SwiftUI

@main
struct MeetingKitApp: App {

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .preferredColorScheme(.light)
        }
    }
}
