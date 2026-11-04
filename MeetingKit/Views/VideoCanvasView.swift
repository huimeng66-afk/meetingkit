//
//  VideoCanvasView.swift
//  MeetingKit
//
//  视频画布。四种形态按优先级互斥：
//    1. 空态（未入会 / 无人 / 已断开）
//    2. 屏幕共享（共享优先于一切，因为这是全场唯一需要看清的内容）
//    3. 演讲者模式（一人主画面 + 顶部缩略图条）
//    4. 宫格模式（<=4 两列，5~9 三列，>9 九宫格分页）
//
//  画布本身铺满全屏（包括刘海区），视频可以真正顶到屏幕边；
//  所有"内容"（缩略图条、宫格、角标、字幕）再按 contentTop/contentBottom 手工避让，
//  避免被顶栏和底栏压住。
//

import SwiftUI
import UIKit

struct VideoCanvasView: View {

    @ObservedObject var viewModel: MeetingViewModel

    /// 根视图 `GeometryReader.safeAreaInsets.top`。
    var topInset: CGFloat = 0

    /// 根视图 `GeometryReader.safeAreaInsets.bottom`。
    var bottomInset: CGFloat = 0

    @State private var gridPage = 0

    /// 顶栏总高（52 + 安全区 + 共享条）。与 TopStatusBar.totalHeight 保持一致。
    private var chromeTop: CGFloat {
        topInset + 52 + (viewModel.isScreenSharing ? 32 : 0)
    }

    /// 内容区从顶栏下 8pt 开始，缩略图条不贴死在玻璃边上。
    private var contentTop: CGFloat {
        chromeTop + 8
    }

    /// 底栏 64 + home indicator + 12pt 呼吸。
    private var contentBottom: CGFloat {
        bottomInset + 84
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                canvasContent(size: proxy.size)
            }
        }
    }

    // MARK: - 形态分发

    @ViewBuilder
    private func canvasContent(size: CGSize) -> some View {
        if showsEmptyState {
            emptyState
        } else if isSharingActive {
            screenShareLayer
        } else if viewModel.participants.isEmpty {
            // 连接中（.connecting / .reconnecting）且还没拿到参会者：统一走连接占位。
            // 不能交给下面的布局分发：宫格模式对空数组只会画出一片纯黑，像卡死。
            connectingPlaceholder
        } else if case .speaker = viewModel.layoutMode {
            speakerLayer
        } else {
            gridLayer(size: size)
        }
    }

    /// 共享态 = 本机在共享，或某个远端在共享（真实链路）。
    private var isSharingActive: Bool {
        viewModel.isScreenSharing || viewModel.remoteScreenPeerID != nil
    }

    /// 空态只在"确实没有会议可看"时出现：已断开，或已连上但一个人都没有。
    ///
    /// `.connecting` / `.reconnecting` 一律不算空态：入会握手的前 350ms 里
    /// participants 还是空的，如果按空列表判空态，首屏会先闪一下
    /// "等待参会人加入"，用户会以为会议已经开始了却没人进来。
    private var showsEmptyState: Bool {
        switch viewModel.connectionState {
        case .connecting, .reconnecting:
            return false
        case .disconnected:
            return true
        case .connected:
            return viewModel.participants.isEmpty
        }
    }

    // MARK: - 1. 屏幕共享

    private var screenShareLayer: some View {
        ZStack {
            Color.black

            shareContent

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    sharingBadge
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .padding(.top, contentTop)

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var shareContent: some View {
        if viewModel.isScreenSharing, viewModel.remoteScreenPeerID == nil {
            // 自己共享时不再回显自己的画面：一块屏幕上看自己正在共享的屏幕没有意义，
            // 还会让人误以为画面卡住。这里只给状态与"停止共享"入口（与网页端一致）。
            selfShareCard
        } else if let peerID = viewModel.remoteScreenPeerID,
           let screenView = viewModel.remoteScreenViews[peerID] {
            RemoteVideoViewRepresentable(view: screenView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, contentTop)
                .padding(.bottom, contentBottom)
        } else if let frame = viewModel.sharedFrame {
            // 本机共享（Broadcast 扩展的帧）。
            Image(uiImage: frame)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 8)
                .padding(.top, contentTop)
                .padding(.bottom, contentBottom)
        } else {
            VStack(spacing: Theme.Metrics.space3) {
                LoadingDotsView(tint: Theme.Palette.textSecondary)
                Text("正在获取共享画面…")
                    .font(Theme.Typography.bodySmall)
                    .foregroundColor(Theme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, contentTop)
            .padding(.bottom, contentBottom)
        }
    }

    /// 本机共享时的状态卡。停止动作走 ViewModel → ScreenShareBridge，
    /// 真正的"停止"由扩展进程确认后再回写 isScreenSharing。
    private var selfShareCard: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.14))
                    .frame(width: 68, height: 68)

                Image(systemName: SymbolCompat.name("rectangle.on.rectangle", "rectangle.on.rectangle"))
                    .font(.system(size: 25, weight: .medium))
                    .foregroundColor(Theme.Palette.accent)
            }

            VStack(spacing: 6) {
                Text("正在共享屏幕中")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.Palette.textPrimary)

                Text("参会成员可以看到你的屏幕")
                    .font(Theme.Typography.bodySmall)
                    .foregroundColor(Theme.Palette.textSecondary)
            }

            Button {
                Haptics.impact(.light)
                viewModel.stopScreenShare()
            } label: {
                Text("停止共享")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .frame(height: 40)
                    .background(Capsule().fill(Theme.Palette.danger))
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("停止共享屏幕")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, contentTop)
        .padding(.bottom, contentBottom)
    }

    private var sharingBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.Palette.success)
                .frame(width: 6, height: 6)

            Text("正在共享")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.Palette.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .liquidGlass(.clear, cornerStyle: .capsule)
    }

    // MARK: - 2. 演讲者模式

    private var speakerLayer: some View {
        ZStack {
            if let speaker = viewModel.speakerUser {
                if let video = videoView(for: speaker) {
                    // 真实视频：主画面直接渲染，不裁切。
                    RemoteVideoViewRepresentable(view: video)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    // 占位画面本身就是铺满的渐变，这里用 clipped 保证不越界。
                    UserVideoBackdrop(user: speaker)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            } else {
                connectingPlaceholder
            }

            // 顶部 0.45 → 中部透明 → 底部 0.65：保证在任何画面上叠白字都读得清。
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.45), location: 0.0),
                    .init(color: Color.clear, location: 0.42),
                    .init(color: Color.black.opacity(0.65), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                thumbnailStrip
                    .padding(.top, contentTop)

                Spacer(minLength: 0)
            }
        }
    }

    /// 顶部缩略图条：104×96，当前 2pt #007FFF 描边，其余 1px 玻璃描边。
    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.participants) { user in
                    Button {
                        Haptics.selection()
                        // 再点同一个人 = 取消固定，回到跟随发言人。
                        viewModel.pinSpeaker(user.id)
                    } label: {
                        ParticipantTile(
                            user: user,
                            videoView: videoView(for: user),
                            cornerRadius: 10,
                            isActiveSpeaker: false,
                            showsBorder: false
                        )
                        .frame(width: 104, height: 96)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    isCurrentSpeaker(user)
                                        ? Color(hex: 0x007FFF)
                                        : Theme.Palette.glassStroke,
                                    lineWidth: isCurrentSpeaker(user) ? 2 : 1
                                )
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("固定 \(user.name) 为主画面")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
        .frame(height: 100)
    }

    private var connectingPlaceholder: some View {
        VStack(spacing: Theme.Metrics.space3) {
            LoadingDotsView()
            Text("正在连接会议…")
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 3. 宫格模式

    private func gridLayer(size: CGSize) -> some View {
        let columns = gridColumnCount
        let pages = gridPages
        let dotsHeight: CGFloat = pages.count > 1 ? 22 : 0
        let gridHeight = max(120, size.height - contentTop - contentBottom - dotsHeight)

        return VStack(spacing: 0) {
            if pages.count <= 1 {
                gridPageView(users: pages.first ?? [], columns: columns)
                    .frame(height: gridHeight)
            } else {
                TabView(selection: $gridPage) {
                    ForEach(pages.indices, id: \.self) { index in
                        gridPageView(users: pages[index], columns: columns)
                            .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .frame(height: gridHeight)

                pageDots(count: pages.count)
                    .frame(height: dotsHeight)
            }
        }
        .padding(.top, contentTop)
        .padding(.bottom, contentBottom)
        .onChange(of: viewModel.participants.count) { _ in
            // 有人退出导致页数变少时，把当前页夹回合法范围，否则会停在空白页。
            if gridPage >= gridPages.count {
                gridPage = max(0, gridPages.count - 1)
            }
        }
    }

    private func gridPageView(users: [MeetingUser], columns: Int) -> some View {
        let spacing: CGFloat = 6
        let gridItems = Array(
            repeating: GridItem(.flexible(), spacing: spacing),
            count: columns
        )

        return VStack(spacing: 0) {
            Spacer(minLength: 0)

            LazyVGrid(columns: gridItems, spacing: spacing) {
                ForEach(users) { user in
                    Button {
                        focus(user)
                    } label: {
                        ParticipantTile(
                            user: user,
                            videoView: videoView(for: user),
                            cornerRadius: Theme.Metrics.tileRadius,
                            isActiveSpeaker: isSpeaking(user),
                            showsBorder: false,
                            showsSharingBadge: user.isLocal && viewModel.isScreenSharing
                        )
                        .aspectRatio(CGFloat(3.0 / 4.0), contentMode: .fill)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("将 \(user.name) 设为主画面")
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 0)
        }
    }

    private func pageDots(count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == gridPage ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 4. 空态

    private var emptyState: some View {
        ZStack {
            BrandBackground()

            VStack(spacing: Theme.Metrics.space4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.Palette.brandGradient)
                        .frame(width: 64, height: 64)

                    Image(systemName: SymbolCompat.name("video.fill", "video"))
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)
                }
                .shadow(color: Theme.Palette.accent.opacity(0.35), radius: 18, y: 8)

                VStack(spacing: 6) {
                    Text("等待参会人加入")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.Palette.textPrimary)

                    Text("会议号 \(viewModel.formattedMeetingNumber)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(Theme.Palette.textTertiary)
                }

                Button {
                    copyInvite()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: SymbolCompat.name("doc.on.doc.fill", "doc.on.doc"))
                            .font(.system(size: 12, weight: .semibold))
                        Text("复制邀请")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(Theme.Palette.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .liquidGlass(.clear, cornerStyle: .capsule, isInteractive: true)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("复制会议邀请")
            }
            .padding(.horizontal, Theme.Metrics.space6)
        }
    }

    // MARK: - 计算

    /// 参会者对应的真实视频视图：远端取 RTCMTLVideoView。
    /// 本机画面由 LocalVideoFloatingView 独占渲染：一个 UIView 只能有一个 superview，
    /// 再共享给宫格/缩略图会被后挂载的一方抢走，出现主画面/浮窗/宫格中一处黑屏。
    /// 因此宫格与缩略图对本机一律显示占位卡（UserVideoBackdrop）。
    private func videoView(for user: MeetingUser) -> UIView? {
        if user.isLocal {
            return nil
        }
        return viewModel.remoteVideoViews[user.id]
    }

    private var gridColumnCount: Int {
        viewModel.participantCount <= 4 ? 2 : 3
    }

    /// 每页 9 格。人数少于一页时只有一页，此时不挂 TabView（省掉一整套手势与布局开销）。
    private var gridPages: [[MeetingUser]] {
        let users = viewModel.participants
        let perPage = 9
        guard users.count > perPage else { return [users] }

        return stride(from: 0, to: users.count, by: perPage).map { start in
            let end = min(start + perPage, users.count)
            return Array(users[start..<end])
        }
    }

    private func isCurrentSpeaker(_ user: MeetingUser) -> Bool {
        viewModel.speakerUser?.id == user.id
    }

    /// 宫格里的说话高亮跟随 RTC 的 activeSpeaker，而不是每个用户自己的 isSpeaking：
    /// 两者理论上一致，但 activeSpeaker 是"全局唯一"的权威值，不会出现多人同时高亮。
    private func isSpeaking(_ user: MeetingUser) -> Bool {
        viewModel.activeSpeakerID == user.id
    }

    /// 点宫格 = 切到演讲者模式并固定这个人。
    private func focus(_ user: MeetingUser) {
        Haptics.selection()
        viewModel.pinnedSpeakerID = user.id
        viewModel.layoutMode = .speaker
    }

    private func copyInvite() {
        let number = viewModel.formattedMeetingNumber
        let link = "tianqiong://join/\(viewModel.meetingNumber)"
        UIPasteboard.general.string = "天穹会议邀请你加入\n会议号：\(number)\n点击加入：\(link)"
        Haptics.impact(.light)
        viewModel.showToast(
            ToastMessage(
                text: "邀请信息已复制",
                systemImage: "doc.on.doc.fill",
                style: .success
            )
        )
    }
}

// MARK: - 加载指示

/// 三点呼吸。共享画面还没到、会议还在连接时用它，
/// 比转菊花更"轻"，不会让画面看起来像卡死。
struct LoadingDotsView: View {

    var tint: Color = Theme.Palette.textSecondary

    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .opacity(isAnimating ? 1.0 : 0.25)
                    .animationCompat(
                        Theme.Motion.blink.delay(Double(index) * 0.18),
                        value: isAnimating
                    )
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                isAnimating = true
            }
        }
    }
}

struct VideoCanvasView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            VideoCanvasView(viewModel: MeetingViewModel(), topInset: 47, bottomInset: 34)
        }
        .preferredColorScheme(.dark)
    }
}
