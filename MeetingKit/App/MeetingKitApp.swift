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

    init() {
        // 屏幕共享的黑匣子要在任何共享代码之前装好：
        // 上一次如果闪退，这里读出来的是"死在哪个调用"，
        // 同时把 NSException 处理器挂上，下一次崩溃能留下原因。
        ShareBreadcrumb.loadAtLaunch()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .preferredColorScheme(.light)
        }
    }
}
