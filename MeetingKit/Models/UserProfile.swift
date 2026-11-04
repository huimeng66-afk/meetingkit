//
//  UserProfile.swift
//  MeetingKit
//
//  本机资料。首轮交付只承载"显示名 + 头像色"两个字段：
//  昵称会出现在入会预览、会议室本机行和邀请文案里，头像色必须与会议室一致，
//  所以它不能散落在各页的 @State 里，否则改名后会议室还显示旧名字。
//

import Foundation

struct UserProfile: Equatable {
    var displayName: String
    /// Theme 头像调色板的索引（0...7）。
    var avatarColorIndex: Int
}

/// 轻量持久化。用 UserDefaults 而不是 CoreData：两条标量，读取必须在
/// 首页首帧之前完成，任何异步存储方案都会让首屏闪一下默认名。
enum UserProfileStore {

    private static let nameKey = "tianqiong.profile.displayName"
    private static let colorKey = "tianqiong.profile.avatarColorIndex"

    /// 头像色卡的数量。模型层不依赖 Theme，但要与调色板保持同一个上限。
    static let avatarColorCount = 8

    static func load() -> UserProfile {
        let rawName = UserDefaults.standard.string(forKey: nameKey) ?? ""
        let name = sanitizeName(rawName)
        let color = clampColor(UserDefaults.standard.integer(forKey: colorKey))
        return UserProfile(displayName: name, avatarColorIndex: color)
    }

    static func save(_ profile: UserProfile) {
        UserDefaults.standard.set(sanitizeName(profile.displayName), forKey: nameKey)
        UserDefaults.standard.set(clampColor(profile.avatarColorIndex), forKey: colorKey)
    }

    /// 空名字会让头像只剩一个 "?"，也会议里无法点名。统一收敛成"我"。
    static func sanitizeName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "我" }
        // 与入会页输入上限一致，避免旧数据里的超长名字撑破会议室顶栏。
        return String(trimmed.prefix(30))
    }

    static func clampColor(_ index: Int) -> Int {
        min(max(index, 0), avatarColorCount - 1)
    }
}
