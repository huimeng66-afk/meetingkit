//
//  VideoCanvasView.swift
//  MeetingKit
//
//  视频画布只负责"选形态"，不负责形态内部：
//    1. 空态（未入会 / 无人 / 已断开）
//    2. 屏幕共享 → 交给 ScreenShareStage（缩放手势、共享者信息、自动收起控件）
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
        topInset + 52 + (viewModel.isShareBannerVisible ? 32 : 0)
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

                // 共享态与非共享态的点击语义不同：共享舞台上单击要交给 UIKit 的
                // 缩放容器（它还要区分双击），外层再挂一个 SwiftUI tap 会把双击吃掉。
                // 因此两条分支各自挂手势，而不是在一个视图上写 guard。
                if isSharingActive {
                    canvasContent(size: proxy.size)
                } else {
                    canvasContent(size: proxy.size)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // 点画布切换控件显隐，这是全屏视频会议的标准交互。
                            withAnimation(Theme.Motion.standard) {
                                viewModel.isChromeVisible.toggle()
                            }
                        }
                }
            }
            // 只在"是否共享"变化时给子树加动画事务，其它更新（参会者进出、说话人切换）
            // 不受影响——`.animation(_:value:)` 的语义就是"value 变化才起动画"。
            .animationCompat(Theme.Motion.standard, value: isSharingActive)
            .overlay(alignment: .bottom) {
                micEvidenceChip
                    .padding(.bottom, contentBottom + 6)
                    .opacity(viewModel.isChromeVisible ? 1 : 0)
            }
        }
    }

    /// 单人会议里的麦克风状态。
    ///
    /// P2P 架构下没有对端就不存在音频发送通道：麦克风已经授权、轨道也建好了，
    /// 但 WebRTC 要等第一条音频发送流才会真正启动采集。这里如实说明
    /// "已就绪、等人进来才开始传"，不做一条永远不动的假波形。
    @ViewBuilder
    private var micEvidenceChip: some View {
        if viewModel.isMicOn, !viewModel.participants.contains(where: { !$0.isLocal }) {
            HStack(spacing: 7) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))

                Text("麦克风已就绪 · 有人加入后自动开始传输")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.58)))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .transition(.opacity)
            .accessibilityLabel("麦克风已就绪，等待参会人加入")
        }
    }

    // MARK: - 形态分发

    @ViewBuilder
    private func canvasContent(size: CGSize) -> some View {
        if showsEmptyState {
            emptyState
        } else if isSharingActive {
            // 共享舞台自己处理全屏铺底、浮层与缩放，画布不再给它补任何 padding。
            // 之前把共享画面塞进 contentTop/contentBottom 之间，等于让 PPT 给顶栏
            // 和底栏让位——共享时最该被让位的恰恰是控件。
            ScreenShareStage(viewModel: viewModel, bottomInset: bottomInset)
                // 共享是大面积画面切换，硬切会像"闪屏"；0.34s 的淡入足以掩盖
                // 从宫格到共享画面的跳变，又不会让用户觉得响应慢。
                .transition(.opacity)
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

    // MARK: - 1. 演讲者模式

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
                    .buttonStyle(LiquidPressStyle(pressedScale: 0.985, highlight: 0))
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

    // MARK: - 2. 宫格模式

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
                    .buttonStyle(LiquidPressStyle(pressedScale: 0.985, highlight: 0))
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

    // MARK: - 3. 空态

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

                    /* P2P 没有对端就没有发送通道。如实说明"已就绪、等人进来"，
                       不让用户把"还没人进会"误读成"麦克风坏了"。 */
                    Text(viewModel.isMicOn
                         ? "麦克风已就绪 · 有人加入后自动开始传输"
                         : "麦克风已静音 · 点底部麦克风可开启")
                        .font(.system(size: 11))
                        .foregroundColor(viewModel.isMicOn ? Theme.Palette.accent : Theme.Palette.textTertiary)
                        .padding(.top, 2)
                        .accessibilityLabel(viewModel.isMicOn ? "麦克风已就绪" : "麦克风已静音")
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
                .buttonStyle(LiquidPressStyle(pressedScale: 0.985, highlight: 0))
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
        // 对方关了摄像头就别再挂旧画面。
        // WebRTC 关摄像头只是停发帧、不断流，view 仍留在字典里；
        // 继续渲染会定格在最后一帧，看起来像"卡住了"而不是"他关了摄像头"。
        guard user.isCameraOn else { return nil }
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
        // 与邀请面板、首页通讯录共用同一个网页地址：
        // 同一个会议出现两种链接，未安装 App 的人扫到 tianqiong:// 只会停在"无法打开"。
        let link = TianqiongAPI.roomLink(number: viewModel.meetingNumber)
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
