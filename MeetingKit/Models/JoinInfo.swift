//
//  JoinInfo.swift
//  MeetingKit
//
//  一次入会所需要的全部上下文。
//
//  为什么单独建模：首页、入会页、会议室三处都要传"会议号 / 标题 / 我是谁 / 是不是主持人"。
//  如果各自拼参数，入会页改了会议号、会议室却还拿着旧值，这类问题很难在 UI 层发现。
//  用一个值类型贯穿路由，任何一页的修改都是显式的新值。
//

import Foundation

struct JoinInfo: Equatable {

    /// 纯数字，7 位。展示一律走 `formattedNumber`。
    var meetingNumber: String
    var title: String
    var displayName: String
    /// 主持人决定会议室里是否有"结束会议"的语义。
    var isHost: Bool
    /// 头像底色在 Theme 调色板中的索引。
    /// 和 displayName 一样属于"我是谁"的一部分，必须跟着 JoinInfo 一路传到会议室，
    /// 否则用户在首页选的头像色进去就变回 0 号色。
    var avatarColorIndex: Int = 0

    /// 入会前预览页上的两个开关。
    /// 麦克风默认开启（进会即可说话）；摄像头默认关闭——大多数会议里用户先听再说，
    /// 默认不开摄像头可以少一次权限弹窗，也避免一进会就"怼脸"。
    var micOn: Bool = true
    var cameraOn: Bool = false

    /// 入会密码（服务端 /meetings/info 下发 hasPassword 时由入会页收集）。
    var password: String = ""
    /// 登录令牌。空串 = 访客入会。由入会页从 AuthStore 带入。
    var token: String = ""

    /// "1234567" → "123 4567"。与 Web 端分组规则一致（前三后四）。
    /// 分组只影响展示，模型里始终存纯数字，复制邀请 / 拨号入会时不需要再清洗。
    var formattedNumber: String {
        Self.groupDigits(meetingNumber)
    }

    /// 发起会议。真实产品这里应该由服务端分配会议号；接入前用本地 7 位随机数占位，
    /// 至少保证同一台设备连续发起两次不会撞号（概率上）。
    static func makeHost(displayName: String) -> JoinInfo {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = name.isEmpty ? "访客" : name
        return JoinInfo(
            meetingNumber: String(Int.random(in: 1_000_000...9_999_999)),
            title: "\(owner)的会议",
            displayName: owner,
            isHost: true
        )
    }

    /// 预览 / 演示用。与旧版会议室默认值保持一致，无参 `MeetingRoomView()` 仍然可用。
    static let demo = JoinInfo(
        meetingNumber: "8624471",
        title: "产品双周会 · MeetingKit 2.0",
        displayName: "陈思远",
        isHost: true
    )

    // MARK: - 数字处理

    /// 只保留数字并截到 7 位。输入框、粘贴、历史记录三条来源都走它。
    static func digitsOnly(_ raw: String) -> String {
        String(raw.filter { $0.isNumber }.prefix(7))
    }

    /// 前三后四一组："1234567" → "123 4567"。不足 7 位时末组原样保留，
    /// 不补零——补零会造出一个不存在的会议号。
    static func groupDigits(_ raw: String) -> String {
        let digits = raw.filter { $0.isNumber }
        guard !digits.isEmpty else { return "" }

        guard digits.count > 3 else { return digits }

        let prefix = digits.prefix(3)
        let suffix = digits.dropFirst(3)
        return prefix + " " + suffix
    }
}
