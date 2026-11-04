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

struct SharePickerPanel: View {

    @ObservedObject var viewModel: MeetingViewModel

    @State private var selectsScreenSource: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            sourceCards
            infoCard

            Spacer(minLength: Theme.Metrics.space3)

            primaryAction
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("共享内容")
                .font(Theme.Typography.sectionTitle)
                .foregroundColor(Theme.Palette.textPrimary)

            Text("选择要共享的内容，系统会请求录屏权限")
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
                subtitle: "整个屏幕或某个 App",
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
        }
        .padding(Theme.Metrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space3)
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
        if viewModel.isScreenSharing {
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

    // MARK: - 动作

    private func startSharing() {
        // 先弹系统面板再收自己的面板：系统的「屏幕录制」是独立 window，
        // 但我们的抽屉如果还开着，用户会以为界面卡住没反应。
        let didPresent = BroadcastPickerPresenter.present()
        viewModel.closePanel()

        guard didPresent else {
            viewModel.showToast(
                ToastMessage(
                    text: "未找到屏幕共享扩展",
                    systemImage: "exclamationmark.triangle.fill",
                    style: .warning
                )
            )
            return
        }

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
