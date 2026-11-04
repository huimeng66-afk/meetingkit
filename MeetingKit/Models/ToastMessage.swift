//
//  ToastMessage.swift
//  MeetingKit
//
//  轻提示模型。会议中几乎所有反馈（"已静音""网络不稳定""已举手"）都走 Toast，
//  用一个统一模型 + 一个渲染组件，避免每个页面各写一套浮层。
//

import Foundation

/// Toast 语义类型。具体配色由主题层决定，模型层只表达"这条提示有多严重"。
enum ToastStyle: Equatable {
    case info
    case success
    case warning
    case danger
}

struct ToastMessage: Identifiable, Equatable {

    /// 每次创建都是新 id：同一个文案连续弹出两次也会被 ForEach 当作两条，
    /// 从而重新播放进入动画（否则用户会以为第二次点击没生效）。
    let id = UUID()
    let text: String
    /// SF Symbols 名称，如 "mic.slash.fill"。
    let systemImage: String
    let style: ToastStyle
}

extension ToastMessage {

    // 常用文案的便捷构造。放在扩展里，避免影响结构体的 memberwise init。

    static func micMuted(_ muted: Bool) -> ToastMessage {
        ToastMessage(
            text: muted ? "已静音" : "已取消静音",
            systemImage: muted ? "mic.slash.fill" : "mic.fill",
            style: .info
        )
    }

    static func cameraToggled(_ on: Bool) -> ToastMessage {
        ToastMessage(
            text: on ? "摄像头已开启" : "摄像头已关闭",
            systemImage: on ? "video.fill" : "video.slash.fill",
            style: .info
        )
    }

    static func handRaised(_ raised: Bool) -> ToastMessage {
        ToastMessage(
            text: raised ? "已举手" : "已取消举手",
            systemImage: raised ? "hand.raised.fill" : "hand.raised.slash.fill",
            style: .info
        )
    }

    static func screenShareStarted() -> ToastMessage {
        ToastMessage(
            text: "屏幕共享已开始",
            systemImage: "rectangle.on.rectangle",
            style: .success
        )
    }

    static func screenShareStopped() -> ToastMessage {
        ToastMessage(
            text: "屏幕共享已结束",
            systemImage: "rectangle.slash",
            style: .info
        )
    }

    static func networkPoor() -> ToastMessage {
        ToastMessage(
            text: "网络不稳定，画质已自动降低",
            systemImage: "wifi.exclamationmark",
            style: .warning
        )
    }
}
