//
//  Haptics.swift
//  MeetingKit
//
//  触觉反馈的最小封装。会议类 App 的静音、挂断、举手都是"盲操作"场景，
//  触觉是唯一不需要看屏幕就能确认操作成功的反馈。
//
//  注意：UIFeedbackGenerator 必须在主线程调用（内部会操作 UI 服务），
//  调用方需保证在主线程；这里不做断言以避免 Debug 场景下误崩。
//

import UIKit

enum Haptics {

    /// 轻量撞击反馈。用于按钮点击、面板弹出等常规交互。
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let generator = UIImpactFeedbackGenerator(style: style)
        // prepare() 让 Taptic Engine 提前进入就绪态，首次反馈不会延迟。
        generator.prepare()
        generator.impactOccurred()
    }

    /// 选择器滚动 / 选项切换反馈。
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    /// 结果型反馈：成功、警告、错误。
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}
