//
//  BottomControlBar.swift
//  MeetingKit
//
//  会议室底栏：7 颗独立玻璃圆钮，装在一个 GlassEffectContainer 里。
//
//  ── 为什么不是"一条玻璃胶囊里排 7 个图标" ─────────────────────────
//  一整块玻璃包住所有按钮，是 Web 的 toolbar 思路：玻璃只有一层，
//  按下去的时候除了按钮自己的缩放，整块玻璃没有任何反应，看起来就是贴图。
//
//  iOS 26 的正确做法是每颗按钮各自持有玻璃，再把它们放进同一个容器：
//  相邻玻璃会在间距内互相吸附、融合成一条，按下某一个时只有那一片液体形变。
//  这就是系统相机 / 控制中心的质感来源，用一层大玻璃永远做不出来。
//
//  尺寸：7 × 44 + 6 × 5 = 338，加左右 12pt 边距共 362，SE（375）也放得下。
//

import SwiftUI

struct BottomControlBar: View {

    @ObservedObject var viewModel: MeetingViewModel

    /// 根视图 `GeometryReader.safeAreaInsets.bottom`。
    var bottomInset: CGFloat = 0

    /// 圆钮直径。44 是触控目标下限，也是 7 颗并排时的上限。
    private let keySize: CGFloat = 44

    var body: some View {
        LiquidGlassContainer(spacing: 8) {
            HStack(spacing: 5) {
                micButton
                cameraButton
                safetyButton
                inviteButton
                membersButton
                shareButton
                moreButton
            }
        }
        .padding(.horizontal, 12)
        // +8 是圆钮与 home indicator 之间的呼吸位；没有这一档，
        // 按钮会紧贴手势条，滑动返回时容易误触到「更多」。
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
            size: keySize,
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
            size: keySize,
            accessibilityText: viewModel.isCameraOn ? "关闭摄像头" : "开启摄像头"
        ) {
            viewModel.toggleCamera()
        }
    }

    private var safetyButton: some View {
        ControlButton(
            systemImage: SymbolCompat.name("checkmark.shield.fill", "checkmark.shield", "shield.fill"),
            title: "安全",
            size: keySize,
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
            size: keySize,
            accessibilityText: "邀请参会人"
        ) {
            togglePanel(.invite)
        }
    }

    private var membersButton: some View {
        ControlButton(
            systemImage: SymbolCompat.name("person.2.fill", "person.2"),
            title: "成员",
            size: keySize,
            badgeText: memberBadgeText,
            accessibilityText: "参会人，共 \(viewModel.participantCount) 人"
        ) {
            togglePanel(.participants)
        }
    }

    /// ≥100 时显示 99+：角标只有 17pt，再多一位就会压到图标。
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
            size: keySize,
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
            size: keySize,
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
