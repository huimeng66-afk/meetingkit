//
//  BottomControlBar.swift
//  MeetingKit
//
//  会议室底栏：7 键等宽 + 玻璃通栏 + 顶部 1px 描边。
//
//  为什么从"浮起的圆角胶囊"改成通栏：
//  设计规范 3.3 要求 7 个等宽键 + 64pt 内容高度，浮起胶囊在 375pt 宽度下
//  7 个 56pt 圆钮已经贴边，再加左右留白会把标签压到 9pt 以下。
//  通栏之后每键 53pt 宽，48pt 圆盘与 10pt 标签都还有呼吸空间。
//
//  安全区由房间层注入 bottomInset：本视图所在层 ignoresSafeArea，
//  底栏自己把 home indicator 的高度垫在玻璃里面，玻璃才能一直铺到屏幕底。
//

import SwiftUI

struct BottomControlBar: View {

    @ObservedObject var viewModel: MeetingViewModel

    /// 根视图 `GeometryReader.safeAreaInsets.bottom`。
    var bottomInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            micButton
            cameraButton
            safetyButton
            inviteButton
            membersButton
            shareButton
            moreButton
        }
        .frame(height: 64)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity)
        .liquidGlass(.regular, in: Rectangle())
        .overlay(topHairline, alignment: .top)
    }

    // MARK: - 顶边

    private var topHairline: some View {
        Rectangle()
            .fill(Theme.Palette.glassStroke)
            .frame(height: 1)
    }

    // MARK: - 七个键

    private var micButton: some View {
        ControlButton(
            systemImage: viewModel.isMicOn
                ? SymbolCompat.name("mic.fill")
                : SymbolCompat.name("mic.slash.fill", "mic.slash"),
            title: viewModel.isMicOn ? "静音" : "取消静音",
            appearance: viewModel.isMicOn ? .neutral : .off,
            accessibilityText: viewModel.isMicOn ? "静音" : "取消静音"
        ) {
            viewModel.toggleMic()
        }
    }

    private var cameraButton: some View {
        ControlButton(
            systemImage: viewModel.isCameraOn
                ? SymbolCompat.name("video.fill")
                : SymbolCompat.name("video.slash.fill", "video.slash"),
            title: viewModel.isCameraOn ? "摄像头" : "开启摄像头",
            appearance: viewModel.isCameraOn ? .neutral : .off,
            accessibilityText: viewModel.isCameraOn ? "关闭摄像头" : "开启摄像头"
        ) {
            viewModel.toggleCamera()
        }
    }

    private var safetyButton: some View {
        ControlButton(
            systemImage: SymbolCompat.name("checkmark.shield.fill", "checkmark.shield", "shield.fill"),
            title: "安全",
            accessibilityText: "安全设置"
        ) {
            togglePanel(.safety)
        }
    }

    private var inviteButton: some View {
        ControlButton(
            systemImage: SymbolCompat.name(
                "person.badge.plus",
                "person.crop.circle.badge.plus",
                "person.fill"
            ),
            title: "邀请",
            accessibilityText: "邀请参会人"
        ) {
            togglePanel(.invite)
        }
    }

    private var membersButton: some View {
        ControlButton(
            systemImage: SymbolCompat.name("person.2.fill", "person.2"),
            title: "成员",
            badgeText: memberBadgeText,
            accessibilityText: "参会人，共 \(viewModel.participantCount) 人"
        ) {
            togglePanel(.participants)
        }
    }

    /// ≥100 时显示 99+：底栏圆盘右上角只有 18pt，再多一位就会压到图标。
    private var memberBadgeText: String? {
        let count = viewModel.participantCount
        guard count > 0 else { return nil }
        return count >= 100 ? "99+" : "\(count)"
    }

    private var shareButton: some View {
        ControlButton(
            systemImage: SymbolCompat.name(
                "rectangle.inset.filled.and.person.filled",
                "rectangle.on.rectangle",
                "rectangle.fill.on.rectangle.fill"
            ),
            title: viewModel.isScreenSharing ? "停止共享" : "共享",
            appearance: viewModel.isScreenSharing ? .broadcast : .neutral,
            accessibilityText: viewModel.isScreenSharing ? "停止共享屏幕" : "共享屏幕"
        ) {
            if viewModel.isScreenSharing {
                viewModel.stopScreenShare()
            } else {
                viewModel.toggleScreenShare()
            }
        }
    }

    private var moreButton: some View {
        ControlButton(
            systemImage: SymbolCompat.name("ellipsis", "ellipsis.circle"),
            title: "更多",
            badgeSymbol: viewModel.isHandRaised ? "hand.raised.fill" : nil,
            badgeDot: !viewModel.isHandRaised && viewModel.isRecording,
            accessibilityText: "更多功能"
        ) {
            togglePanel(.more)
        }
    }

    /// 同一个面板按钮再点一次就是关闭，这是底栏按钮的既定交互。
    private func togglePanel(_ panel: MeetingViewModel.MeetingPanel) {
        if viewModel.activePanel == panel {
            viewModel.closePanel()
        } else {
            viewModel.openPanel(panel)
        }
    }
}

struct BottomControlBar_Previews: PreviewProvider {
    static var previews: some View {
        ZStack(alignment: .bottom) {
            Theme.Palette.tileBackground
            VStack {
                Spacer()
                BottomControlBar(viewModel: MeetingViewModel(), bottomInset: 34)
            }
        }
        .preferredColorScheme(.dark)
    }
}
