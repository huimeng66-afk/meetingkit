//
//  BroadcastPickerView.swift
//  MeetingKit
//
//  系统屏幕共享入口。iOS 不允许 App 自行发起 ReplayKit 广播，
//  必须由系统的 RPSystemBroadcastPickerView 弹出「屏幕录制」面板，用户手动点开始。
//  这是唯一合规的接入方式，任何绕过它的私有 API 都会被审核拒绝。
//

import ReplayKit
import SwiftUI
import UIKit

/// 把 `RPSystemBroadcastPickerView` 包成 SwiftUI 视图。
/// 该视图由系统绘制（浅色描边 + 圆点），不跟随 App 的外观设置，属于预期行为。
struct BroadcastPickerView: UIViewRepresentable {

    /// 限定只列出本 App 的广播扩展，避免用户在面板里选到别的 App 的录制扩展。
    var preferredExtension: String = AppGroupConfig.broadcastExtensionBundleIdentifier

    /// 是否显示麦克风开关。默认关闭：会议音频由主 App 的 RTC 通道采集，
    /// 这里再录一份会出现双份音轨和回声。
    var showsMicrophoneButton: Bool = false

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        // 必须给非零初始尺寸，否则在部分布局路径下系统会画出一个空白的 0x0 视图。
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = preferredExtension
        picker.showsMicrophoneButton = showsMicrophoneButton
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        // 属性可能随 SwiftUI 状态变化，这里同步一次；重复赋值是幂等的。
        uiView.preferredExtension = preferredExtension
        uiView.showsMicrophoneButton = showsMicrophoneButton
    }
}

/// 以编程方式触发系统面板。
///
/// 场景：会议界面自己画了一个"共享屏幕"按钮，想复用系统面板而不是嵌一个系统样式的圆点。
/// 做法是先在视图层级里挂一个 `BroadcastPickerView`（可以是 0 尺寸或隐藏的），
/// 再调用 `present()` 找到它内部的 UIButton 并模拟点击。
@MainActor
enum BroadcastPickerPresenter {

    /// 找到当前界面里的系统广播选择器并点击它的内部按钮。
    /// - Returns: 找到了并已触发返回 true；找不到（例如阶段 2 忘了挂载 picker）返回 false。
    @discardableResult
    static func present() -> Bool {
        guard let rootView = keyWindow()?.rootViewController?.view else { return false }
        guard let picker = findPicker(in: rootView) else { return false }
        guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else { return false }

        Haptics.impact(.medium)
        // 系统没有暴露点击 API，只能向内部按钮派发触摸事件；这是业界通行做法。
        button.sendActions(for: .allTouchEvents)
        return true
    }

    // MARK: - 私有

    /// iOS 15 起 `UIApplication.shared.windows` 已废弃，必须走 connectedScenes。
    private static func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            // 兜底：某些时刻（如转场动画中）isKeyWindow 可能全为 false。
            if let first = windowScene.windows.first {
                return first
            }
        }
        return nil
    }

    private static func findPicker(in view: UIView) -> RPSystemBroadcastPickerView? {
        if let picker = view as? RPSystemBroadcastPickerView {
            return picker
        }
        for subview in view.subviews {
            if let found = findPicker(in: subview) {
                return found
            }
        }
        return nil
    }
}
