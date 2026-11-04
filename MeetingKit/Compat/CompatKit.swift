//
//  CompatKit.swift
//  MeetingKit
//
//  iOS 14 兼容层。baseline 从 15.0 降到 14.0 之后，所有"15 才有"的便利 API
//  都在这里给出 13/14 就存在的等价写法，业务代码只允许调用本文件的封装，
//  不允许直接写 `.animation(_:value:)` / `@FocusState` / `.confirmationDialog` 等。
//
//  为什么集中一个文件：降版本时最容易出现的不是崩溃、而是"某个系统版本上静默失效"
//  （例如 SF Symbol 名字在该系统上不存在时渲染成空白），集中一处才能一眼看出
//  当前项目到底依赖了哪些新 API。
//
//  本文件依赖 UIKit，因此只能放在主 App target 的 Compat/ 下，
//  绝不能进 Shared/（Broadcast Extension 会跟着编译，且扩展里 UIApplication 不可用）。
//

import Foundation
import SwiftUI
import UIKit

// MARK: - 动画

extension View {

    /// iOS 15 才有 `.animation(_:value:)`。
    ///
    /// 14 上退化成 `.animation(_:)`：代价是"整个子树的任意变化都会走这段动画"。
    /// 本项目里这 9 处都是单标量驱动的开关/呼吸/进出场，退化后行为一致；
    /// 只有在同一棵子树里同时跑两套不同节奏的动画时才需要小心。
    @ViewBuilder
    func animationCompat<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        if #available(iOS 15.0, *) {
            self.animation(animation, value: value)
        } else {
            self.animation(animation)
        }
    }
}

// MARK: - 键盘

/// iOS 14 没有 `@FocusState`，需要主动收键盘时只能走响应者链。
enum Keyboard {

    /// 让当前第一响应者放弃焦点，即收起键盘。
    ///
    /// `sendAction` 会沿响应者链找第一个能处理 `resignFirstResponder` 的对象，
    /// 找到的往往就是正在编辑的 `UITextField`；找不到时什么都不发生，不会崩。
    static func dismiss() {
        // 显式丢弃返回值：14/15 的 SDK 对 sendAction 的可丢弃性标注不一致，
        // 写 `_ =` 在两种 SDK 上都不会有告警。
        _ = UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    /// 键盘当前高度（不含安全区）。没有键盘时为 0。
    ///
    /// 面板自己已经在按 `keyboardWillShow/Hide` 做位移，这个值只给"需要知道键盘占了多高
    /// 但又不参与自动避让"的场景用（例如把浮层临时抬到键盘上方）。
    /// 注意不要和父视图的自动避让叠加，否则会移两次。
    static var height: CGFloat {
        startObservingIfNeeded()
        return cachedHeight
    }

    // MARK: 私有

    /// 只从主线程读写（UI 通知都在主队列投递）。
    private static var cachedHeight: CGFloat = 0
    private static var observerTokens: [NSObjectProtocol] = []
    private static var isObserving: Bool = false

    private static func startObservingIfNeeded() {
        guard !isObserving else { return }
        isObserving = true

        let center = NotificationCenter.default

        let willShow = center.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            cachedHeight = frame?.height ?? 0
        }

        let willHide = center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { _ in
            cachedHeight = 0
        }

        observerTokens = [willShow, willHide]
    }
}

// MARK: - SF Symbols

/// SF Symbols 不是所有名字都在 iOS 14 存在。
///
/// 不存在的名字不会崩，但会渲染成一块空白——界面看起来像坏了，而且这种问题
/// 只在老系统上复现，模拟器和真机新系统都测不出来。所以所有符号名统一走这里：
/// 传入候选名（新 → 旧），返回当前系统真实存在的第一个。
enum SymbolCompat {

    /// 所有候选都不存在时的兜底。这个符号 iOS 13 就有，且语义中性。
    static let fallbackName = "questionmark.circle"

    /// 判定结果缓存。`UIImage(systemName:)` 本身不贵，但它在每个 body 求值里都会调用，
    /// 底栏 6 个按钮 × 每秒多次刷新，没必要重复查表。
    /// 只在主线程访问（SwiftUI body 都在主线程）。
    private static var availabilityCache: [String: Bool] = [:]

    /// 传入候选名（新 → 旧），返回当前系统真实可用的第一个。
    ///
    /// - Parameter candidates: 从新到旧排列的 SF Symbol 名称。
    /// - Returns: 当前系统可用的第一个名字；全都不存在时返回 `fallbackName`。
    static func name(_ candidates: String...) -> String {
        for candidate in candidates where isAvailable(candidate) {
            return candidate
        }
        return fallbackName
    }

    /// 单个符号是否可用。`UIImage(systemName:)` 返回 nil 即代表当前系统没有这个符号。
    private static func isAvailable(_ symbolName: String) -> Bool {
        if let cached = availabilityCache[symbolName] {
            return cached
        }
        let available = UIImage(systemName: symbolName) != nil
        availabilityCache[symbolName] = available
        return available
    }
}

// MARK: - 确认弹窗

/// 自绘确认弹窗，替代 iOS 15 的 `.confirmationDialog`。
///
/// 为什么不用系统 API：`confirmationDialog` 是 15 起，14 上会静默不弹（用户点了结束会议
/// 什么都不发生，比弹窗难看严重得多）；而且系统弹窗是浅色 action sheet，
/// 与整屏深色的会议界面割裂。自绘还能保证 14~26 的观感完全一致。
///
/// 形态：全屏 0.5 黑遮罩 + 居中玻璃卡片（宽 300、圆角 22、上下分栏）。
struct GlassConfirmDialog: View {

    let title: String
    let message: String
    let confirmTitle: String

    /// 危险操作（结束会议、移出会议）时确认按钮用红色，否则用强调蓝。
    var isDestructive: Bool = true

    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// 0.94 → 1 的 spring 缩放进场。首帧缩小、onAppear 再放大，
    /// 这样弹窗出现时是"从中间弹出来"而不是原地淡入。
    @State private var hasAppeared: Bool = false

    private let cardWidth: CGFloat = 300
    private let cardRadius: CGFloat = 22

    var body: some View {
        ZStack {
            scrim
            card
        }
    }

    // MARK: - 遮罩

    private var scrim: some View {
        Color.black.opacity(0.5)
            .ignoresSafeArea()
            // 只让"看得见的黑色区域"参与命中：否则全屏 Color 会把下面的点击吞掉。
            .contentShape(Rectangle())
            .onTapGesture {
                // 点遮罩 = 取消，这是 iOS 上模态弹窗的既定预期。
                dismissCancel()
            }
    }

    // MARK: - 卡片

    private var card: some View {
        VStack(spacing: 0) {
            textBlock
            hairline
            buttonRow
        }
        .frame(width: cardWidth)
        .liquidGlass(
            .regular,
            cornerStyle: .continuous(cardRadius),
            isInteractive: false,
            castsShadow: true
        )
        // 卡片自己吞掉点击，避免点在标题/正文空白处被遮罩当成"取消"。
        // 子级的两个按钮优先级更高，不受影响。
        .contentShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .onTapGesture {
            // 有意留空：只拦截事件，不做任何事。
        }
        .scaleEffect(hasAppeared ? 1.0 : 0.94)
        .opacity(hasAppeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(Theme.Motion.standard) {
                hasAppeared = true
            }
        }
    }

    private var textBlock: some View {
        VStack(spacing: Theme.Metrics.space2) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.system(size: 12.5))
                .foregroundColor(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                // 多行文本在 VStack 里默认会被压成一行省略，必须显式允许纵向扩展。
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Metrics.space4)
        .padding(.top, Theme.Metrics.space5)
        .padding(.bottom, Theme.Metrics.space4)
        .frame(maxWidth: .infinity)
    }

    /// 1px 分隔线。用 Rectangle 而不是 Divider：Divider 在深色下的灰度不可控。
    private var hairline: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 1)
    }

    private var buttonRow: some View {
        HStack(spacing: 0) {
            Button {
                dismissCancel()
            } label: {
                Text("取消")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.Palette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(width: 1, height: 48)

            Button {
                Haptics.impact(.medium)
                onConfirm()
            } label: {
                Text(confirmTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isDestructive ? Theme.Palette.danger : Theme.Palette.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - 动作

    private func dismissCancel() {
        Haptics.impact(.light)
        onCancel()
    }
}

// MARK: - 预览

struct GlassConfirmDialog_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.tileBackground
            GlassConfirmDialog(
                title: "确定要结束会议吗？",
                message: "会议将立即结束，所有参会人会被移出。",
                confirmTitle: "结束会议",
                isDestructive: true,
                onConfirm: {},
                onCancel: {}
            )
        }
        .preferredColorScheme(.dark)
    }
}
