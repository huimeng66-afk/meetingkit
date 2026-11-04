//
//  ChatMessage.swift
//  MeetingKit
//
//  聊天消息模型。系统消息（"XX 加入了会议"）与普通消息共用一张表，
//  由 `kind` 区分渲染样式，避免 UI 维护两个数据源还要保证时序交错正确。
//

import Foundation

/// 消息类型。显式 Equatable，保证 `ChatMessage` 的 Equatable 合成稳定。
enum ChatKind: Equatable {
    case text
    case system
}

struct ChatMessage: Identifiable, Equatable {

    let id: String
    let senderID: String
    let senderName: String
    let text: String
    let date: Date
    let kind: ChatKind

    /// 系统消息不显示头像与昵称，UI 直接读这个判断，避免各处重复写 `kind == .system`。
    var isSystem: Bool {
        kind == .system
    }

    /// 带默认值的设计：`id` 由发送侧生成（Mock 阶段用 UUID，真实实现换成服务端消息号），
    /// `date` 默认取当前时间，`kind` 默认文本消息 —— 绝大多数调用点只需传四个参数。
    init(
        id: String = UUID().uuidString,
        senderID: String,
        senderName: String,
        text: String,
        date: Date = Date(),
        kind: ChatKind = .text
    ) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.text = text
        self.date = date
        self.kind = kind
    }
}
