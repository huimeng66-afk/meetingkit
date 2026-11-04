//
//  MeetingRoomView.swift
//  MeetingKit
//
//  主界面装配。只做三件事：叠层顺序、安全区注入、生命周期转发。
//  任何业务判断都不写在这里——所有状态都在 MeetingViewModel。
//
//  叠层顺序（自下而上）：
//    1. 页面底色          —— 铺满全屏，防止任何层的边缘漏出白底
//    2. 视频画布          —— 铺满全屏（含刘海区），视频才能真正顶到边
//    3. 顶栏 / 底栏       —— 由 topInset / bottomInset 手工补白
//    4. 本地小窗          —— 可拖拽，必须盖在画布和控制栏之上
//    5. Toast             —— 盖在顶栏之上（大厂常见的"提示压住顶栏"处理）
//    6. 底部抽屉          —— 最上层，连 Toast 一起压住
//    7. 隐藏的系统广播选择器 —— 只为了能被 BroadcastPickerPresenter 找到
//

import SwiftUI

struct MeetingRoomView: View {

    /// 本次入会的上下文。会议室内部视图不直接读它，
    /// 全部经 `viewModel` 暴露的 @Published 展示，保持单一状态源。
    let join: JoinInfo

    /// 离会后返回首页。由路由层注入，会议室自己不知道路由的存在。
    var onExit: () -> Void

    /// 真正连上会议后回调（路由层用于判断"是否留下参会历史"）。
    var onJoined: (() -> Void)?

    @StateObject private var viewModel: MeetingViewModel

    /// 结束会议的确认状态由房间层持有。
    /// 不能在 MorePanel 里弹：面板被 GlassSheet 裁成圆角抽屉，
    /// 在里面画的"全屏遮罩"只能盖住下半屏。
    @State private var isConfirmingEndMeeting = false

    /// 已向路由确认过"连上了"：断线重连反复横跳时只报一次。
    @State private var hasNotifiedJoined = false

    /// 无参构造保留：预览与旧调用点（`MeetingRoomView()`）继续可用。
    init(
        join: JoinInfo = .demo,
        onExit: @escaping () -> Void = {},
        onJoined: (() -> Void)? = nil
    ) {
        self.join = join
        self.onExit = onExit
        self.onJoined = onJoined
        _viewModel = StateObject(wrappedValue: MeetingViewModel(join: join))
    }

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets

            ZStack {
                Theme.Palette.background
                    .ignoresSafeArea()

                VideoCanvasView(
                    viewModel: viewModel,
                    topInset: insets.top,
                    bottomInset: insets.bottom
                )
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    // 点画布切换控件显隐，这是全屏视频会议的标准交互。
                    withAnimation(Theme.Motion.standard) {
                        viewModel.isChromeVisible.toggle()
                    }
                }

                chromeLayer(insets: insets)

                quickChatLayer(insets: insets)

                // topInset / bottomInset 必须传进去：小窗的上边界是"顶栏底部 + 8"，
                // 下边界是"底栏顶部 - 12"，写死常量在刘海/无刘海机型上会盖住按钮或浪费行程（H-7）。
                LocalVideoFloatingView(
                    viewModel: viewModel,
                    containerSize: geo.size,
                    topInset: insets.top,
                    bottomInset: insets.bottom
                )
                .zIndex(2)

                toastLayer(insets: insets)

                panelLayer(bottomInset: insets.bottom)

                endMeetingDialog

                // 离会后遮罩：zIndex 让位给 Toast（4），这样"会议已结束"的提示还是看得见。
                endedOverlay

                broadcastPickerAnchor
            }
        }
        // 键盘由 GlassSheet 自己按通知上移；关掉系统的自动避让，避免"移两次"。
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
        }
        .onChange(of: viewModel.connectionState) { state in
            // 真正连上会议后通知路由一次：入会失败（密码错误/网络失败）不产生参会历史。
            if case .connected = state, !hasNotifiedJoined {
                hasNotifiedJoined = true
                onJoined?()
            }
        }
    }

    // MARK: - 顶栏 + 底栏

    private func chromeLayer(insets: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            TopStatusBar(
                viewModel: viewModel,
                topInset: insets.top,
                onEndMeetingRequest: {
                    withAnimation(Theme.Motion.standard) {
                        isConfirmingEndMeeting = true
                    }
                },
                onLeaveRequest: {
                    Haptics.impact(.medium)
                    onExit()
                }
            )

            Spacer(minLength: 0)

            BottomControlBar(viewModel: viewModel, bottomInset: insets.bottom)
        }
        // 顶栏要让红色警示条铺到刘海区、底栏要贴到屏幕最下沿，
        // 所以这一层整体忽略上下安全区，再由两个子视图各自补白。
        .ignoresSafeArea(edges: [.top, .bottom])
        .opacity(viewModel.isChromeVisible ? 1 : 0)
        .allowsHitTesting(viewModel.isChromeVisible)
        .animationCompat(Theme.Motion.standard, value: viewModel.isChromeVisible)
        .zIndex(1)
    }

    // MARK: - 快捷聊天

    /// 左下浮动聊天入口。
    ///
    /// 底栏按设计规范固定为 7 键，聊天不能占其中一个位置；但聊天面板又必须可达。
    /// 网页参考里对应的是左侧浮动的快捷胶囊（`#rQuickChat`），这里保留同一结构，
    /// 只做聊天一项——没有表情业务就不放一个点了没反应的假按钮。
    private func quickChatLayer(insets: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(spacing: 0) {
                Button {
                    Haptics.impact(.light)
                    if viewModel.activePanel == .chat {
                        viewModel.closePanel()
                    } else {
                        viewModel.openPanel(.chat)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: SymbolCompat.name(
                            "bubble.left.and.bubble.right.fill",
                            "bubble.left.and.bubble.right"
                        ))
                            .font(.system(size: 14, weight: .medium))

                        Text("聊天")
                            .font(.system(size: 12, weight: .medium))

                        if viewModel.unreadCount > 0 {
                            Text(viewModel.unreadCount >= 100 ? "99+" : "\(viewModel.unreadCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(Theme.Palette.danger))
                        }
                    }
                    .foregroundColor(Theme.Palette.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .liquidGlass(.clear, cornerStyle: .capsule, isInteractive: true)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("打开聊天")

                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .padding(.bottom, insets.bottom + 64 + 10)
        }
        .opacity(viewModel.isChromeVisible ? 1 : 0)
        .allowsHitTesting(viewModel.isChromeVisible)
        .animationCompat(Theme.Motion.standard, value: viewModel.isChromeVisible)
        .zIndex(1.5)
    }

    // MARK: - Toast

    private func toastLayer(insets: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            if let toast = viewModel.toast {
                ToastView(message: toast)
                    .padding(.horizontal, Theme.Metrics.horizontal)
                    .padding(.top, insets.top + 52 + (viewModel.isShareBannerVisible ? 32 : 0) + 8)
                    // id 变化会重建视图，从而重播进入动画：
                    // 连续两次同样的提示（例如连点两次静音）用户才看得出"又触发了一次"。
                    .id(toast.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer(minLength: 0)
        }
        .animationCompat(Theme.Motion.standard, value: viewModel.toast?.id)
        .allowsHitTesting(false)
        .zIndex(4)
    }

    // MARK: - 底部抽屉

    private func panelLayer(bottomInset: CGFloat) -> some View {
        ZStack {
            if let panel = viewModel.activePanel {
                GlassSheet(
                    detent: detent(for: panel),
                    bottomInset: bottomInset,
                    onClose: {
                        viewModel.closePanel()
                    }
                ) {
                    panelContent(panel)
                }
                .transition(.opacity)
                // 换面板时重建抽屉，让档位回到该面板的默认值（聊天/参会人=大，更多=中）。
                .id(panel.rawValue)
            }
        }
        .animationCompat(Theme.Motion.standard, value: viewModel.activePanel)
        .zIndex(5)
    }

    private func detent(for panel: MeetingViewModel.MeetingPanel) -> GlassSheetDetent {
        switch panel {
        // 参会人列表要能一屏看全 8 个人 + 搜索框 + 底部工具条；
        // 聊天需要尽量高的输入区，两者都走大档。
        case .participants, .chat:
            return .large
        case .more, .sharePicker, .invite, .safety, .settings:
            return .medium
        }
    }

    @ViewBuilder
    private func panelContent(_ panel: MeetingViewModel.MeetingPanel) -> some View {
        switch panel {
        case .participants:
            ParticipantsPanel(viewModel: viewModel)
        case .chat:
            ChatPanel(viewModel: viewModel)
        case .more:
            MorePanel(
                viewModel: viewModel,
                onEndMeetingRequest: {
                    // 必须包 withAnimation：弹窗的出场是 `.transition(.opacity)` +
                    // 卡片内部 0.94→1 的 spring，只有把状态变更放进入场事务里，
                    // 插入/移除才会走 Theme.Motion.standard，否则是硬切。
                    withAnimation(Theme.Motion.standard) {
                        isConfirmingEndMeeting = true
                    }
                },
                onLeaveRequest: {
                    onExit()
                }
            )
        case .sharePicker:
            SharePickerPanel(viewModel: viewModel)
        case .invite:
            InvitePanel(viewModel: viewModel)
        case .safety:
            SafetyPanel(viewModel: viewModel)
        case .settings:
            SettingsPanel(viewModel: viewModel)
        }
    }

    // MARK: - 结束会议确认

    /// 替代 iOS 15 的 `.confirmationDialog`：14 上那个 API 不存在，
    /// 调用点会静默不弹（用户点了"结束会议"却什么都不发生），这是最不能接受的退化。
    /// 层级压在抽屉（5）与 Toast（4）之上，保证确认框永远在最前。
    @ViewBuilder
    private var endMeetingDialog: some View {
        if isConfirmingEndMeeting {
            GlassConfirmDialog(
                title: "确定要结束会议吗？",
                message: "会议将立即结束，所有参会人会被移出。",
                confirmTitle: "结束会议",
                isDestructive: true,
                onConfirm: {
                    withAnimation(Theme.Motion.standard) {
                        isConfirmingEndMeeting = false
                    }
                    viewModel.endMeeting()
                    viewModel.closePanel()
                },
                onCancel: {
                    withAnimation(Theme.Motion.standard) {
                        isConfirmingEndMeeting = false
                    }
                }
            )
            .transition(.opacity)
            .zIndex(6)
        }
    }

    // MARK: - 离会后遮罩

    /// 会议真正结束后盖住整屏，避免用户对着一个"还在跑但其实已经离会"的界面操作。
    /// 必须给"重新入会"出口：否则演示环境里结束会议等于把 App 弄死。
    @ViewBuilder
    private var endedOverlay: some View {
        if case .disconnected = viewModel.connectionState {
            ZStack {
                Color.black.opacity(0.86)
                    .ignoresSafeArea()

                VStack(spacing: Theme.Metrics.space3) {
                    Image(systemName: SymbolCompat.name("phone.down.fill", "phone.down"))
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(Theme.Palette.danger)
                        .padding(.bottom, Theme.Metrics.space1)

                    Text(viewModel.endTitle)
                        .font(Theme.Typography.sectionTitle)
                        .foregroundColor(Theme.Palette.textPrimary)

                    Text(viewModel.endText)
                        .font(Theme.Typography.bodySmall)
                        .foregroundColor(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)

                    if viewModel.endCanRejoin {
                        Button {
                            Haptics.impact(.medium)
                            viewModel.rejoin()
                        } label: {
                            Text("重新入会")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(
                                    RoundedRectangle(
                                        cornerRadius: Theme.Metrics.buttonRadius,
                                        style: .continuous
                                    )
                                    .fill(Theme.Palette.accent)
                                )
                        }
                        .buttonStyle(ControlButtonPressStyle())
                        .padding(.top, Theme.Metrics.space2)
                        .frame(maxWidth: 220)
                        .accessibilityLabel("重新入会")
                    }

                    Button {
                        Haptics.impact(.light)
                        onExit()
                    } label: {
                        Text("返回首页")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.Palette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .frame(maxWidth: 220)
                    .accessibilityLabel("返回首页")
                }
                .padding(.horizontal, Theme.Metrics.space6)
            }
            .transition(.opacity)
            .zIndex(3)
        }
    }

    // MARK: - 系统广播选择器

    /// RPSystemBroadcastPickerView 必须真实存在于视图层级里，
    /// `BroadcastPickerPresenter.present()` 才能找到它内部的按钮并派发点击。
    /// 这里把它缩到 0.001 透明度、关掉命中测试，用户看不到也点不到。
    private var broadcastPickerAnchor: some View {
        BroadcastPickerView()
            .frame(width: 44, height: 44)
            .opacity(0.001)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(0)
    }
}

struct MeetingRoomView_Previews: PreviewProvider {
    static var previews: some View {
        MeetingRoomView()
            .preferredColorScheme(.dark)
    }
}
