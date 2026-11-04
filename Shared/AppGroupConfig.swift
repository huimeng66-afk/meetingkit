//
//  AppGroupConfig.swift
//  Shared
//
//  主 App 与广播扩展唯一共享的"常量真相"。两个 Target 都编译这一份文件，
//  任何一处 bundle id 写错都会导致扩展写进去的帧主 App 读不到，
//  所以全部集中在这里，禁止在别处硬编码。
//

import Foundation

enum AppGroupConfig {

    /// App Group 标识。主 App 与扩展的 entitlements 必须与这里完全一致。
    static let identifier = "group.com.example.meetingkit"

    /// 主 App 的 Bundle Identifier（RPSystemBroadcastPickerView 用它确认宿主）。
    static let bundleIdentifier = "com.example.MeetingKit"

    /// 广播扩展的 Bundle Identifier，即 RPSystemBroadcastPickerView.preferredExtension 的取值。
    static let broadcastExtensionBundleIdentifier = "com.example.MeetingKit.Broadcast"

    /// 产品展示名，UI 与系统弹窗复用同一份，避免多语言阶段各处改名漏改。
    static let displayName = "MeetingKit"

    /// App Group 的共享容器目录。扩展没有写权限之外的特殊限制，
    /// 但容器 URL 拿不到时说明 entitlements 配错了，调用方必须按 nil 处理。
    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// App Group 共享的 UserDefaults。
    /// 跨进程可见性由 cfprefsd 保证，写入后不需要手动 synchronize()。
    static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}
