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

/// JSON 存 UserDefaults。最多 20 条：首页只展示最近一小段，
/// 更早的记录对用户没有价值，反而让首次解码变慢。
enum MeetingHistoryStore {

    private static let storageKey = "tianqiong.meetingHistory"
    private static let limit = 20

    static func load() -> [MeetingHistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([MeetingHistoryItem].self, from: data)) ?? []
    }

    /// 新记录置顶；同 id 先移除，保证重复调用不会产生重复行。
    static func add(_ item: MeetingHistoryItem) {
        var items = load()
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        persist(items)
    }

    static func remove(id: String) {
        var items = load()
        items.removeAll { $0.id == id }
        persist(items)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private static func persist(_ items: [MeetingHistoryItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
