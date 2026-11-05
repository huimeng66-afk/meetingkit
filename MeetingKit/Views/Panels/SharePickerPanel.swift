//
//  SharePickerPanel.swift
//  MeetingKit
//
//  共享选择面板。这个面板只负责"发起系统弹窗"，不能自己把 isScreenSharing 置为 true。
//  ReplayKit 广播是否真的开始，由用户在系统弹窗里点"开始直播"决定，
//  状态会由扩展写进 App Group，再由 ScreenShareBridge 流回来。
//
//  停止共享同样不做乐观置值（H-2）：只调用 viewModel.stopScreenShare()，
//  红色按钮与计时会一直留到系统真正确认结束。
//

import SwiftUI
import UIKit

struct SharePickerPanel: View {

    @ObservedObject var viewModel: MeetingViewModel

    @State private var selectsScreenSource: Bool = true

    /// 签名是否真的给了 App Group 能力。
    ///
    /// 只在这里求值一次：`containerURL` 是系统调用，放进 body 会在每次
    /// 状态刷新时都跑一遍；而签名能力在一次进程生命周期内不会变。
    @State private var isSystemShareAvailable: Bool = AppGroupConfig.isAvailable

    var body: some View {
        VStack(spacing: 0) {
            header

            if isSystemShareAvailable {
                sourceCards
                infoCard
                diagnosticsCard
            } else {
                // 不可用时不再摆两张点不动的来源卡：
                // 用户点"共享屏幕"是来解决问题的，不是来看一个灰掉的界面。
                compatibilityNotice
                webSteps
            }

            Spacer(minLength: Theme.Metrics.space3)

            primaryAction
        }
    }

    // MARK: - 签名能力提示

    private var compatibilityNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: 0xFBBF24))

                Text("当前安装包无法回传共享画面")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Palette.textPrimary)
            }

            Text("签名证书没有授予 App Group 权限。系统广播可以启动，但画面传不回这场会议。")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Metrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Color(hex: 0xFBBF24).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .stroke(Color(hex: 0xFBBF24).opacity(0.28), lineWidth: 1)
        )
        .padding(.horizontal, Theme.Metrics.horizontal)
    }

    private var webSteps: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.space2) {
            HStack(spacing: 6) {
                Image(systemName: SymbolCompat.name("safari.fill", "safari"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Palette.accent)

                Text("用网页版共享屏幕")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Palette.textPrimary)
            }

            stepRow(index: 1, text: "复制下方的会议链接")
            stepRow(index: 2, text: "在 Safari 或 Chrome 中打开")
            stepRow(index: 3, text: "进入会议后点底部的「共享屏幕」")
        }
        .padding(Theme.Metrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Theme.Palette.surfaceSubtle)
        )
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space3)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("共享内容")
                .font(Theme.Typography.sectionTitle)
                .foregroundColor(Theme.Palette.textPrimary)

            Text("iOS 只能共享整个屏幕，不能只投某一个 App")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space1)
        .padding(.bottom, Theme.Metrics.space3)
    }

    // MARK: - 来源卡片

    private var sourceCards: some View {
        HStack(spacing: Theme.Metrics.space3) {
            sourceCard(
                title: "共享屏幕",
                subtitle: "整屏 · 你切到哪个 App 就播哪个",
                systemImage: SymbolCompat.name(
                    "rectangle.inset.filled.and.person.filled",
                    "rectangle.on.rectangle",
                    "rectangle.fill.on.rectangle.fill"
                ),
                isSelected: selectsScreenSource,
                isEnabled: true
            ) {
                selectsScreenSource = true
            }

            sourceCard(
                title: "共享白板",
                subtitle: "即将上线",
                systemImage: SymbolCompat.name("pencil.and.outline", "pencil.tip", "square.and.pencil"),
                isSelected: false,
                isEnabled: false
            ) {
                // 禁用态，点不动；保留结构是为了让两张卡片的间距与高度一致。
            }
        }
        .padding(.horizontal, Theme.Metrics.horizontal)
    }

    private func sourceCard(
        title: String,
        subtitle: String,
        systemImage: String,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            VStack(spacing: Theme.Metrics.space2) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundColor(
                        isEnabled
                            ? (isSelected ? Theme.Palette.accent : Theme.Palette.textSecondary)
                            : Theme.Palette.textTertiary
                    )
                    .frame(height: 26)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isEnabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)

                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .fill(
                        isSelected && isEnabled
                            ? Theme.Palette.accent.opacity(0.14)
                            : Color.white.opacity(0.05)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .stroke(
                        isSelected && isEnabled
                            ? Theme.Palette.accent
                            : Theme.Palette.glassStroke,
                        lineWidth: isSelected && isEnabled ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
        }
        .buttonStyle(ControlButtonPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.55)
        .accessibilityLabel("\(title)，\(subtitle)")
    }

    // MARK: - 三步说明

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.space2) {
            HStack(spacing: 6) {
                Image(systemName: SymbolCompat.name("info.circle.fill", "info.circle"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Palette.accent)

                Text("如何开始共享")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Palette.textPrimary)
            }

            stepRow(index: 1, text: "点击下方「开始共享屏幕」")
            stepRow(index: 2, text: "在系统弹窗中选择「\(AppGroupConfig.displayName) 屏幕共享」")
            stepRow(index: 3, text: "点击「开始直播」，共享画面会出现在会议里")
            stepRow(index: 4, text: "回到桌面、切到要展示的 App —— 你切到哪儿，对面就看到哪儿（包括通知和横竖屏切换）")
        }
        .padding(Theme.Metrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Theme.Palette.surfaceSubtle)
        )
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space3)
    }

    // MARK: - 共享诊断

    /// 一条链路四段的计数（出帧 / 落盘 / 读帧 / 推 RTC）。
    ///
    /// 做成常驻的小卡片而不是隐藏入口：这个 App 的共享失败在用户侧永远只有
    /// "对方看不见"一个现象，没有分阶段计数就只能靠猜。展开一次、截个图，
    /// 就能定位断在哪一段。
    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: SymbolCompat.name("waveform.path.ecg", "waveform.path"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink3)

                Text("共享诊断")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Palette.textSecondary)

                Spacer(minLength: 0)

                Button {
                    UIPasteboard.general.string = viewModel.shareDiagnosticsReport
                    Haptics.impact(.light)
                    viewModel.showToast(
                        ToastMessage(
                            text: "诊断信息已复制",
                            systemImage: "doc.on.doc.fill",
                            style: .success
                        )
                    )
                } label: {
                    Text("复制")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.Palette.accent)
                }
                .buttonStyle(PlainButtonStyle())
            }

            Text(viewModel.shareDiagnosticsReport)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let failure = viewModel.shareFailure, !failure.isEmpty {
                Text(failure)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Metrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Theme.Palette.surfaceSubtle)
        )
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space2)
    }

    private func stepRow(index: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 15, height: 15)
                .background(Circle().fill(Theme.Palette.accent))

            Text(text)
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
    // MARK: - 主按钮

    @ViewBuilder
    private var primaryAction: some View {
        if !isSystemShareAvailable {
            // 不可用时不摆一个注定打不开系统面板的"开始共享"。
            // 主按钮直接就是唯一有结果的路径：复制链接去网页版。
            Button {
                copyWebLink()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: SymbolCompat.name("doc.on.doc.fill", "doc.on.doc"))
                        .font(.system(size: 14, weight: .semibold))

                    Text("复制链接，用网页版共享")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                        .fill(Theme.Palette.brandGradient)
                )
            }
            .buttonStyle(ControlButtonPressStyle())
            .padding(.horizontal, Theme.Metrics.horizontal)
            .padding(.bottom, Theme.Metrics.space2)
            .accessibilityLabel("复制链接，用网页版共享")
        } else if viewModel.isScreenSharing {
            Button {
                Haptics.impact(.light)
                // H-2：只发停止请求，绝不在此处把 isScreenSharing 置 false。
                viewModel.stopScreenShare()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: SymbolCompat.name("stop.fill", "stop.circle.fill"))
                        .font(.system(size: 13, weight: .bold))

                    Text("停止共享")
                        .font(.system(size: 16, weight: .semibold))

                    Text(viewModel.shareDurationText)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .opacity(0.85)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                        .fill(Theme.Palette.danger)
                )
            }
            .buttonStyle(ControlButtonPressStyle())
            .padding(.horizontal, Theme.Metrics.horizontal)
            .padding(.bottom, Theme.Metrics.space2)
            .accessibilityLabel("停止共享屏幕")
        } else {
            Button {
                startSharing()
            } label: {
                Text("开始共享屏幕")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                            .fill(Theme.Palette.brandGradient)
                    )
            }
            .buttonStyle(ControlButtonPressStyle())
            .padding(.horizontal, Theme.Metrics.horizontal)
            .padding(.bottom, Theme.Metrics.space2)
            .accessibilityLabel("开始共享屏幕")
        }
    }

    // MARK: - 网页版兜底

    private func copyWebLink() {
        let number = viewModel.meetingNumber
        guard !number.isEmpty else {
            viewModel.showToast(
                ToastMessage(
                    text: "会议号还没准备好，请稍后再试",
                    systemImage: "exclamationmark.triangle.fill",
                    style: .warning
                )
            )
            return
        }

        let link = TianqiongAPI.roomLink(number: number)
        UIPasteboard.general.string = link
        Haptics.impact(.light)
        viewModel.showToast(
            ToastMessage(
                text: "链接已复制，在浏览器打开即可共享",
                systemImage: "doc.on.doc.fill",
                style: .success
            )
        )
        viewModel.closePanel()
    }

    // MARK: - 动作

    private func startSharing() {
        // 先清旧帧、写本次会话的 requestedAt，再弹系统面板。
        // 顺序不能反：第一帧可能比面板点击更早落盘，晚写 requestedAt
        // 会把它误判成"上一场的旧帧"。
        viewModel.prepareForScreenShare()

        // 再弹系统面板再收自己的面板：系统的「屏幕录制」是独立 window，
        // 但我们的抽屉如果还开着，用户会以为界面卡住没反应。
        let didPresent = BroadcastPickerPresenter.present()

        guard didPresent else {
            // 失败时**不要**关面板：关掉之后用户只剩一条转瞬即逝的 Toast，
            // 体感就是"点了没反应"，还得重新点一次共享才能回到这里。
            // 保留面板，用户可以直接改走下面的网页版链接。
            viewModel.showToast(
                ToastMessage(
                    text: "系统共享面板未能打开，可改用网页版共享",
                    systemImage: "exclamationmark.triangle.fill",
                    style: .warning
                )
            )
            return
        }

        // 只有系统面板真的弹出来了才收自己的抽屉，否则两层界面会互相抢焦点。
        viewModel.closePanel()

        // 这里刻意什么都不做：真正的开始状态由 ScreenShareBridge 从 App Group 读回来，
        // 用户若在系统弹窗里点取消，界面不该留下"正在共享"的假状态。
    }
}

struct SharePickerPanel_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.background
            SharePickerPanel(viewModel: MeetingViewModel())
        }
        .preferredColorScheme(.dark)
    }
}
