//
//  MorePanel.swift
//  MeetingKit
//
//  "更多"面板：4×2 功能网格 + 结束会议。
//
//  状态型功能（举手/录制/虚拟背景/美颜/降噪）必须能看出开还是关，
//  否则用户点完不知道有没有生效——会议里没有旁白提示，只有界面和 Toast。
//  因此每个格子都做了两件事：开启时 44pt 圆钮变蓝、右上角亮一个绿点。
//

import SwiftUI

struct MorePanel: View {

    @ObservedObject var viewModel: MeetingViewModel

    /// 结束会议的确认由房间层弹出，而不是在本面板里弹。
    ///
    /// 原因：本面板活在 GlassSheet 里，而抽屉会把内容裁成圆角面板，
    /// 在这里画的"全屏 0.5 黑遮罩"只能盖住下半屏，看起来像一块贴纸。
    var onEndMeetingRequest: () -> Void = {}

    /// 非主持人点"离开会议"：直接回首页，不结束整场会议。
    var onLeaveRequest: () -> Void = {}

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            LazyVGrid(columns: columns, spacing: Theme.Metrics.space4) {
                MoreActionTile(
                    title: "成员",
                    systemImage: SymbolCompat.name("person.2.fill", "person.2"),
                    isOn: nil
                ) {
                    viewModel.openPanel(.participants)
                }

                MoreActionTile(
                    title: "邀请",
                    systemImage: SymbolCompat.name(
                        "person.badge.plus",
                        "person.crop.circle.badge.plus",
                        "person.fill"
                    ),
                    isOn: nil
                ) {
                    viewModel.openPanel(.invite)
                }

                MoreActionTile(
                    title: "安全",
                    systemImage: SymbolCompat.name(
                        "checkmark.shield.fill",
                        "checkmark.shield",
                        "shield.fill"
                    ),
                    isOn: nil
                ) {
                    viewModel.openPanel(.safety)
                }

                MoreActionTile(
                    title: "举手",
                    systemImage: SymbolCompat.name("hand.raised.fill", "hand.raised"),
                    isOn: viewModel.isHandRaised
                ) {
                    viewModel.toggleHandRaise()
                }

                MoreActionTile(
                    title: "虚拟背景",
                    systemImage: SymbolCompat.name("person.crop.rectangle", "person.crop.square"),
                    isOn: viewModel.isVirtualBackgroundOn
                ) {
                    viewModel.toggleVirtualBackground()
                }

                MoreActionTile(
                    title: "美颜",
                    systemImage: SymbolCompat.name("wand.and.stars", "sparkles"),
                    isOn: viewModel.isBeautyOn
                ) {
                    viewModel.toggleBeauty()
                }

                MoreActionTile(
                    title: "降噪",
                    systemImage: SymbolCompat.name("waveform", "waveform.path"),
                    isOn: viewModel.isNoiseSuppressionOn
                ) {
                    viewModel.toggleNoiseSuppression()
                }

                MoreActionTile(
                    title: "翻转",
                    systemImage: SymbolCompat.name("arrow.triangle.2.circlepath", "arrow.clockwise"),
                    isOn: nil
                ) {
                    viewModel.switchCamera()
                }

                MoreActionTile(
                    title: "设置",
                    systemImage: SymbolCompat.name("gearshape", "gear"),
                    isOn: nil
                ) {
                    viewModel.openPanel(.settings)
                }

                MoreActionTile(
                    title: "录制",
                    systemImage: SymbolCompat.name("record.circle", "smallcircle.filled.circle"),
                    isOn: viewModel.isRecording,
                    isDisabled: true
                ) {
                    // 云录制尚未接入服务端，禁用并标注"即将上线"，避免假开关误导用户。
                }
            }
            .padding(.horizontal, Theme.Metrics.horizontal)

            Spacer(minLength: Theme.Metrics.space3)

            endMeetingButton
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Metrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("更多")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundColor(Theme.Palette.textPrimary)

                Text("会议工具与设置")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Palette.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space1)
        .padding(.bottom, Theme.Metrics.space4)
    }

    // MARK: - 结束会议

    private var endMeetingButton: some View {
        Button {
            Haptics.impact(.medium)
            if viewModel.isCurrentUserHost {
                onEndMeetingRequest()
            } else {
                onLeaveRequest()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: SymbolCompat.name("phone.down.fill", "phone.down"))
                    .font(.system(size: 13, weight: .semibold))

                Text(viewModel.isCurrentUserHost ? "结束会议" : "离开会议")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(Theme.Palette.danger)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                    .fill(Theme.Palette.danger.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                    .stroke(Theme.Palette.danger.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(ControlButtonPressStyle())
        .disabled(!viewModel.canEndMeeting)
        .opacity(viewModel.canEndMeeting ? 1.0 : 0.4)
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.bottom, Theme.Metrics.space2)
        .accessibilityLabel("结束会议")
    }
}

// MARK: - 功能格子

struct MoreActionTile: View {

    let title: String
    let systemImage: String

    /// nil 表示纯动作项（翻转/邀请/设置），不展示开关状态。
    var isOn: Bool? = nil

    /// 未接入的功能（录制等）置灰禁用。
    var isDisabled: Bool = false

    var action: () -> Void

    var body: some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(isOn == true
                            ? Theme.Palette.accent
                            : Color.white.opacity(0.10))
                        .frame(width: 44, height: 44)

                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(isOn == true ? .white : Theme.Palette.textPrimary)
                        .frame(width: 44, height: 44)

                    if isOn == true {
                        Circle()
                            .fill(Theme.Palette.success)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Theme.Palette.background, lineWidth: 1.5))
                            .offset(x: 1, y: 0)
                    }
                }

                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlButtonPressStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1.0)
        .accessibilityLabel(title)
    }
}

struct MorePanel_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.background
            MorePanel(viewModel: MeetingViewModel())
        }
        .preferredColorScheme(.dark)
    }
}
