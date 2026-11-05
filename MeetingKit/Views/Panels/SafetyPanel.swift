//
//  SafetyPanel.swift
//  MeetingKit
//
//  安全面板：四个开关 + 一行权限说明。
//
//  开关状态存在 ViewModel（isLocked / isWaitingRoomOn / muteOnJoin / allowSharing），
//  不放在视图的 @State：锁定状态还要驱动顶栏的小锁，两份状态一定会对不上。
//

import SwiftUI

struct SafetyPanel: View {

    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 0) {
                settingRow(
                    symbol: SymbolCompat.name("lock.fill", "lock"),
                    title: "锁定会议",
                    // 非主持人把开关点来点去也不会生效（ViewModel 里会静默 return），
                    // 直接在界面上禁用并说明原因，比"点了没反应"诚实。
                    subtitle: viewModel.isCurrentUserHost
                        ? "新参会人将无法加入"
                        : "仅主持人可操作",
                    isOn: Binding(
                        get: { viewModel.isLocked },
                        set: { viewModel.setLocked($0) }
                    ),
                    isDisabled: !viewModel.isCurrentUserHost
                )

                rowDivider

                settingRow(
                    symbol: SymbolCompat.name("person.crop.circle.badge.clock", "clock.fill", "clock"),
                    title: "等候室",
                    subtitle: "新参会人需主持人同意后进入（即将上线）",
                    isOn: $viewModel.isWaitingRoomOn,
                    isDisabled: true
                )

                rowDivider

                settingRow(
                    symbol: SymbolCompat.name("mic.slash.fill", "mic.slash"),
                    title: "入会时静音",
                    subtitle: "新参会人默认关闭麦克风（即将上线）",
                    isOn: $viewModel.muteOnJoin,
                    isDisabled: true
                )

                rowDivider

                settingRow(
                    symbol: SymbolCompat.name(
                        "rectangle.inset.filled.and.person.filled",
                        "rectangle.on.rectangle"
                    ),
                    title: "允许共享屏幕",
                    subtitle: "关闭后参会人不能发起共享（即将上线）",
                    isOn: $viewModel.allowSharing,
                    isDisabled: true
                )
            }
            .padding(.horizontal, Theme.Metrics.horizontal)

            Spacer(minLength: Theme.Metrics.space3)

            Text("安全设置仅主持人可修改")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Palette.textTertiary)
                .padding(.bottom, Theme.Metrics.space2)
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("安全")
                .font(Theme.Typography.sectionTitle)
                .foregroundColor(Theme.Palette.textPrimary)

            Text("控制谁可以加入、谁可以发言与共享")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space1)
        .padding(.bottom, Theme.Metrics.space3)
    }

    // MARK: - 行

    private func settingRow(
        symbol: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        isDisabled: Bool = false
    ) -> some View {
        HStack(spacing: Theme.Metrics.space3) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.06))

                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.Palette.textSecondary)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.Palette.textPrimary)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: Theme.Metrics.space2)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Theme.Palette.accent))
                .disabled(isDisabled || !viewModel.isCurrentUserHost)
                .opacity(viewModel.isCurrentUserHost ? 1.0 : 0.45)
                .accessibilityLabel(title)
        }
        .frame(height: 56)
        .contentShape(Rectangle())
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 1)
            .padding(.leading, 44)
    }
}

struct SafetyPanel_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.background
            SafetyPanel(viewModel: MeetingViewModel())
        }
        .preferredColorScheme(.dark)
    }
}
