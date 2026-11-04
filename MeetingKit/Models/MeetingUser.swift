//
//  MeetingUser.swift
//  MeetingKit
//
//  参会者模型。阶段 2 的宫格、成员列表、发言高亮都以它为唯一数据源，
//  所以这里的字段命名必须与 RTC 抽象层完全对齐，不允许各页面自己派生同名结构。
//

import Foundation

// MARK: - 角色

/// 会议角色。显式声明 Hashable 是为了让 `MeetingUser` 的 Hashable 合成不依赖
/// "简单枚举自动满足 Hashable" 这条隐式规则，避免不同 Swift 版本行为差异。
enum MeetingRole: Hashable {
    case host
    case coHost
    case participant

    /// 头像角标文案，nil 表示普通参会者不展示角标。
    var badge: String? {
        switch self {
        case .host:
            return "主持人"
        case .coHost:
            return "联席主持人"
        case .participant:
            return nil
        }
    }
}

// MARK: - 参会者

struct MeetingUser: Identifiable, Hashable {

    let id: String
    var name: String
    var role: MeetingRole
    var isMicOn: Bool
    var isCameraOn: Bool
    var isHandRaised: Bool
    var isSpeaking: Bool
    /// 是否是本机用户。UI 用它在自己的画面上加"我"的标记、镜像摄像头画面、禁用对自己的一些操作。
    var isLocal: Bool
    /// 头像底色在调色板中的索引。用索引而不是 UIColor，是为了让模型层不依赖 UIKit，
    /// 也方便阶段 2 统一在主题层定义一套深浅两套调色板。
    var avatarColorIndex: Int

    /// 头像占位文字。
    ///
    /// 规则：中文/日文/韩文姓名显示后两字（"陈思远" → "思远"），
    /// 其他（英文等）取前两个词的首字母（"Alex Chen" → "AC"）。
    /// 兜底 "?"：名字为空时 UI 需要一个可见字符，不能留空导致头像看起来像渲染失败。
    var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }

        let containsCJK = trimmed.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,   // 扩展 A
                 0x4E00...0x9FFF,   // 基本汉字
                 0xF900...0xFAFF:   // 兼容汉字
                return true
            default:
                return false
            }
        }

        if containsCJK {
            return String(trimmed.suffix(2))
        }

        // 用空格、点、连字符切词，兼容 "Alex Chen" / "Alex.J.Chen" / "Alex-Chen" 三种写法。
        let words = trimmed.split { character in
            character == " " || character == "." || character == "-"
        }
        let letters = words.compactMap { $0.first }.prefix(2).map { String($0) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
