//
//  MeetingHistoryItem.swift
//  MeetingKit
//
//  历史会议。只记录"我真实进入过并离开"的会议：
//  记录动作发生在 AppRouter.leaveRoom()，而不是点"加入会议"的瞬间，
//  否则入会失败、在预览页返回都会留下一条并不存在的历史。
//

import Foundation

struct MeetingHistoryItem: Identifiable, Codable {

    /// UUID。会议号不能当主键：同一个会议号可以反复加入，每次都是一条独立记录。
    let id: String
    let title: String
    let number: String
    let startedAt: Date
    let duration: TimeInterval

    /// 列表右侧的时长文案。
    var durationText: String {
        // 产品约定：不足一分钟也显示"1 分钟"，比"0 分钟"更符合直觉。
        let totalMinutes = max(1, Int(duration / 60))
        if totalMinutes < 60 {
            return "\(totalMinutes) 分钟"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分钟"
    }
}

/// JSON 存 UserDefaults，**按账号分键**。
///
/// 之前所有账号共用 `tianqiong.meetingHistory`：单设备登录下，
/// A 退出、B 登录后，B 在首页就能看到 A 开过的会和会议号。
/// 历史里包含"谁在什么时候和谁开会"，属于账号数据，不能跨账号泄漏。
///
/// 访客记录单独一档：访客页不展示历史，登录后也不该把访客记录混进账号历史。
enum MeetingHistoryStore {

    private static let storageKey = "tianqiong.meetingHistory"
    private static let limit = 20

    static func load(account: String) -> [MeetingHistoryItem] {
        let storageKeyForAccount = key(for: account)
        migrateLegacyIfNeeded(to: storageKeyForAccount, account: account)

        guard let data = UserDefaults.standard.data(forKey: storageKeyForAccount) else { return [] }
        return (try? JSONDecoder().decode([MeetingHistoryItem].self, from: data)) ?? []
    }

    /// 新记录置顶；同 id 先移除，保证重复调用不会产生重复行。
    static func add(_ item: MeetingHistoryItem, account: String) {
        var items = load(account: account)
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        persist(items, account: account)
    }

    static func remove(id: String, account: String) {
        var items = load(account: account)
        items.removeAll { $0.id == id }
        persist(items, account: account)
    }

    static func clear(account: String) {
        UserDefaults.standard.removeObject(forKey: key(for: account))
    }

    // MARK: - 私有

    /// 旧版本只有一个全局键。升级后首次以登录账号进入时，
    /// 把这份数据迁到该账号名下，避免用户以为"历史全没了"。
    ///
    /// 只在 account 非空时迁移：访客先打开 App 的话，
    /// 把旧数据落到 guest 档会让真正的主人登录后看不到。
    private static func migrateLegacyIfNeeded(to key: String, account: String) {
        guard !account.isEmpty else { return }
        guard UserDefaults.standard.data(forKey: key) == nil else { return }
        guard let legacy = UserDefaults.standard.data(forKey: storageKey) else { return }

        UserDefaults.standard.set(legacy, forKey: key)
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private static func key(for account: String) -> String {
        let normalized = account
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return storageKey + ".guest" }
        return storageKey + "." + normalized
    }

    private static func persist(_ items: [MeetingHistoryItem], account: String) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key(for: account))
    }
}
