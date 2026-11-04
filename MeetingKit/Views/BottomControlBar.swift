//
//  BottomControlBar.swift
//  MeetingKit
//
//  会议室底栏：7 键 + 悬浮玻璃 Dock。
//
//  ── 为什么从"通栏"改成"悬浮胶囊" ─────────────────────────────────
//  通栏贴底是 Web / Android 的做法，玻璃只能铺成一条横带，看不出厚度。
//  改成悬浮胶囊后：左右各留 12pt、离安全区 8pt，视频画面从胶囊四周透出来，
//  模糊层才有内容可折射，7 个按键也不再被压到屏幕上缘。
//
//  宽度约束：iPhone 14 Pro 逻辑宽 393，减掉 12×2 边距与 2×2 内边距，
//  每键约 52pt，48pt 圆盘 + 10pt 标签仍有余量；SE（375）上每键约 49.6pt，
//  圆盘不变、标签靠 minimumScaleFactor 收缩，不会换行。
//
//  安全区由房间层注入 bottomInset：本视图所在层 ignoresSafeArea，
//  底栏自己把 home indicator 的高度垫在胶囊外面，胶囊才真正浮起来。
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
        .padding(.horizontal, 2)
        .liquidGlass(
            .regular,
            cornerStyle: .continuous(34),
            castsShadow: true
        )
        .padding(.horizontal, 12)
        // +8 是胶囊与 home indicator 之间的呼吸位；没有这一档，
        // 胶囊会紧贴手势条，滑动返回时容易误触到「更多」。
        .padding(.bottom, bottomInset + 8)
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
