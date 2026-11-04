//
//  HomeView.swift
//  MeetingKit
//
//  首页。结构对齐 docs/design-tianqiong.md 3.2：
//  头像 + 昵称 / 搜索 / 通知 → 标题 → 发起·加入双卡 → 历史会议 → 底部 Tab。
//
//  联系人页在本轮只做空态：没有通讯录数据源时不能编造联系人，
//  "邀请参会人"退化为复制最近一场会议的会议号，这是无数据时唯一真实可做的事。
//

import Combine
import Foundation
import SwiftUI
import UIKit

struct HomeView: View {

    @ObservedObject var router: AppRouter

    /// 全局设置。首页需要读"默认麦克风/摄像头"，设置页需要写同一份对象；
    /// 用注入而不是在页面里再取一次单例，是为了让预览也能塞一份内存态。
    @ObservedObject var settings: AppSettings

    @State private var tab: HomeTab = .meetings
    @State private var isEditingProfile = false
    @State private var draftName = ""
    @State private var draftColor = 0

    // MARK: 侧边栏

    @State private var isSidebarOpen = false
    /// 关闭手势的跟手位移（恒 ≤ 0）。与 isSidebarOpen 分开：打开动画由 transition 负责，
    /// 手势只负责"往回推"这一段，两者叠加不会互相覆盖。
    @State private var sidebarDragOffset: CGFloat = 0

    /// 重选当前 tab 时自增，驱动列表滚回顶部。
    @State private var scrollTopToken = 0

    // MARK: 首页入会表单（对齐网页端 hero 的 join-card）

    /// 加入 / 发起。网页端是两枚 tab，App 端保持同一套心智，不另发明入口。
    @State private var joinMode: HomeJoinMode = .join
    @State private var meetingNumber = ""
    /// 选填名称。空串时以「访客」入会，与网页端 placeholder 语义一致。
    @State private var guestName = ""
    @State private var isMicOn: Bool
    @State private var isCameraOn: Bool
    @State private var isLoginPresented = false
    /// 登录态只在进入首页 / 关闭登录页时读一次，避免每帧读 Keychain。
    @State private var session: AuthSession? = AuthStore.load()

    @State private var toast: ToastMessage?
    @State private var toastWork: DispatchWorkItem?

    /// GeometryReader 不会为键盘自动上移，资料卡的昵称输入需要自己抬起来。
    @State private var keyboardHeight: CGFloat = 0

    /// 设计稿页面边距 20（比会议室内部的 16 更接近 iOS 阅读习惯）。
    private let pagePadding: CGFloat = 20

    /// 入会页的两个开关从设置里取初值。
    ///
    /// 用同步快照而不是在 onAppear 里读：首帧如果先画默认值再跳到用户设置，
    /// 会看到两个开关"闪一下"。`AppSettings.mediaDefaultsSnapshot` 是 nonisolated 的，
    /// 正是为了能在 View init 里安全调用。
    init(router: AppRouter, settings: AppSettings) {
        _router = ObservedObject(wrappedValue: router)
        _settings = ObservedObject(wrappedValue: settings)

        let defaults = AppSettings.mediaDefaultsSnapshot
        _isMicOn = State(initialValue: defaults.mic)
        _isCameraOn = State(initialValue: defaults.camera)
    }

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let drawerWidth = sidebarWidth(for: geo.size.width)

            ZStack(alignment: .bottom) {
                BrandBackground()

                tabContent(insets: insets)

                HomeDock(
                    selection: $tab,
                    bottomInset: insets.bottom,
                    onReselect: { _ in
                        scrollTopToken += 1
                    }
                )

                toastLayer(bottomInset: insets.bottom)

                if isEditingProfile {
                    profileEditor(bottomInset: insets.bottom)
                }

                sidebarLayer(insets: insets, width: drawerWidth)
            }
            // 从左边缘向右滑打开抽屉。用 simultaneousGesture 而不是 gesture：
            // 抽屉内容本身是 ScrollView，独占手势会让竖直滚动被外层吞掉。
            .simultaneousGesture(edgeOpenGesture())
        }
        // 整个首页屏蔽键盘安全区：否则底栏会被顶到键盘上方，
        // 而资料卡又会被再抬一次。键盘只影响资料卡的显式 offset。
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            guard
                let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            else { return }
            withAnimation(Theme.Motion.standard) {
                keyboardHeight = frame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(Theme.Motion.standard) {
                keyboardHeight = 0
            }
        }
        .onAppear {
            // 从会议室返回、或刚从登录页回来时，账号可能变了。
            session = AuthStore.load()
        }
        // 设置页改了默认音视频后同步到入会卡：两处都叫"麦克风"，
        // 如果设置里关了、首页还亮着，用户没有理由相信任何一处。
        .onChange(of: settings.defaultMicOn) { value in
            isMicOn = value
        }
        .onChange(of: settings.defaultCameraOn) { value in
            isCameraOn = value
        }
        .sheet(isPresented: $isLoginPresented, onDismiss: {
            // 登录成功后 LoginView 会把昵称回填 guestName，这里同步账号态，
            // 让右上角从「登录」切换成头像胶囊。
            session = AuthStore.load()
            if session != nil, !guestName.isEmpty {
                router.updateProfile(
                    displayName: guestName,
                    avatarColorIndex: router.profile.avatarColorIndex
                )
            }
        }) {
            LoginView(displayName: $guestName)
        }
        .onDisappear {
            toastWork?.cancel()
        }
    }

    // MARK: - 页面容器

    /// 四个 tab 的容器。
    ///
    /// 会议/通讯录共用一条首页滚动轴（品牌头 + 内容），企业/设置各自带滚动容器：
    /// 把它们塞进外层 ScrollView 会变成"滚动里再套滚动"，在 iPhone 上会出现
    /// 内层滚到底后手势不传递给外层、以及内容高度塌陷这两类问题。
    @ViewBuilder
    private func tabContent(insets: EdgeInsets) -> some View {
        switch tab {
        case .meetings, .contacts:
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        topBar

                        if tab == .meetings {
                            meetingsBody
                        } else {
                            contactsBody
                        }
                    }
                    .padding(.horizontal, pagePadding)
                    .padding(.top, insets.top + 8)
                    // 悬浮 Dock 实际占位 50 + 10，再留 26 呼吸位，
                    // 保证最后一行历史记录滚到底时不会被胶囊压住。
                    //
                    // 首页有两个输入框，键盘弹起时必须能把「加入会议」顶上来：
                    // 根视图整棵忽略了键盘安全区（否则底栏会被顶到键盘上方），
                    // 所以这里手动把键盘高度补进滚动内容底部。
                    .padding(.bottom, 96 + insets.bottom + keyboardHeight)
                    .id(Self.scrollTopID)
                }
                // 手动吃安全区：GeometryReader 里的子视图从屏幕原点开始，
                // 不加这一行，滚动内容会钻到刘海下面，而顶部留白已经显式给过了。
                .ignoresSafeArea()
                .onChange(of: scrollTopToken) { _ in
                    // 重选当前 tab = 回到顶部。用 snappy 而不是 standard：
                    // 这是一次"归位"，不是页面切换，回弹太久会显得拖沓。
                    withAnimation(Theme.Motion.snappy) {
                        proxy.scrollTo(Self.scrollTopID, anchor: .top)
                    }
                }
            }
            .transition(.opacity)

        case .enterprise:
            EnterpriseView(
                router: router,
                onEnterRoom: { info in
                    Haptics.impact(.medium)
                    router.openPreJoin(info)
                },
                onRequestLogin: {
                    presentLogin()
                },
                onToast: { text, style in
                    showToast(text, icon: toastIcon(for: style), style: style)
                },
                onOpenSidebar: {
                    openSidebar()
                }
            )
            .ignoresSafeArea()
            .transition(.opacity)

        case .settings:
            SettingsView(
                router: router,
                settings: settings,
                onRequestLogin: {
                    presentLogin()
                },
                onEditProfile: {
                    openProfileEditor()
                },
                onToast: { text, style in
                    showToast(text, icon: toastIcon(for: style), style: style)
                },
                topInset: insets.top,
                bottomInset: insets.bottom,
                onOpenSidebar: {
                    openSidebar()
                }
            )
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    private static let scrollTopID = "home-scroll-top"

    // MARK: - 侧边栏

    /// min(320, 84%)：SE 上留 16% 让用户还能看到"后面还有页面"，
    /// Pro Max 上封顶 320，避免抽屉宽到像第二列布局。
    private func sidebarWidth(for containerWidth: CGFloat) -> CGFloat {
        min(320, max(268, containerWidth * 0.84))
    }

    @ViewBuilder
    private func sidebarLayer(insets: EdgeInsets, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            if isSidebarOpen {
                Color.black
                    .opacity(sidebarBackdropOpacity(width: width))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closeSidebar()
                    }
                    .transition(.opacity)

                HomeSidebar(
                    router: router,
                    currentTab: tab,
                    topInset: insets.top,
                    bottomInset: insets.bottom,
                    onSelectTab: { target in
                        selectTab(target)
                        closeSidebar()
                    },
                    onStartMeeting: {
                        closeSidebar()
                        // 侧边栏里的"发起会议"与首页发起是同一个动作：
                        // 需要登录、需要服务端分配会议号，不能在抽屉里另写一套。
                        selectTab(.meetings)
                        startMeetingFromHome()
                    },
                    onLogin: {
                        closeSidebar()
                        presentLogin()
                    },
                    onEditProfile: {
                        closeSidebar()
                        openProfileEditor()
                    },
                    onClose: {
                        closeSidebar()
                    },
                    onToast: { text, style in
                        closeSidebar()
                        showToast(text, icon: toastIcon(for: style), style: style)
                    }
                )
                .frame(width: width)
                .offset(x: sidebarDragOffset)
                .transition(.move(edge: .leading))
                .simultaneousGesture(sidebarDragGesture(width: width))
            }
        }
        // 必须盖住 Dock 与 Toast：抽屉是模态的，底下的任何入口都不该还能点。
        .zIndex(30)
    }

    /// 拖动时遮罩跟着变淡，松手回弹时才不会"啪"地跳一下。
    private func sidebarBackdropOpacity(width: CGFloat) -> Double {
        let progress = min(1, abs(sidebarDragOffset) / max(width, 1))
        return 0.46 * (1 - progress)
    }

    private func sidebarDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                // 只处理水平向左的位移；竖直方向交给抽屉里的 ScrollView。
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                sidebarDragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                let passedThreshold = value.translation.width < -width * 0.26
                let willPass = value.predictedEndTranslation.width < -width * 0.5
                if passedThreshold || willPass {
                    closeSidebar()
                } else {
                    withAnimation(Theme.Motion.sheet) {
                        sidebarDragOffset = 0
                    }
                }
            }
    }

    private func edgeOpenGesture() -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !isSidebarOpen else { return }
                // 起点必须在左边缘 32pt 内，且以水平位移为主。
                // 不加这两条，宫格/历史列表的横向滑动会误开抽屉。
                guard value.startLocation.x < 32 else { return }
                guard value.translation.width > 72 else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                openSidebar()
            }
    }

    private func openSidebar() {
        Keyboard.dismiss()
        Haptics.impact(.light)
        sidebarDragOffset = 0
        withAnimation(Theme.Motion.sheet) {
            isSidebarOpen = true
        }
    }

    private func closeSidebar() {
        withAnimation(Theme.Motion.sheet) {
            isSidebarOpen = false
            sidebarDragOffset = 0
        }
    }

    private func selectTab(_ target: HomeTab) {
        guard tab != target else { return }
        Keyboard.dismiss()
        withAnimation(Theme.Motion.standard) {
            tab = target
        }
    }

    private func presentLogin() {
        Keyboard.dismiss()
        isLoginPresented = true
    }

    /// toast 只有文案和样式，图标按语义给一个默认值。
    /// 让上层传图标会让每个调用点多一个必填参数，收益远小于噪音。
    private func toastIcon(for style: ToastStyle) -> String {
        switch style {
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .danger:
            return "xmark.octagon.fill"
        case .info:
            return "info.circle.fill"
        }
    }

    // MARK: - 顶部

    /// 品牌头：左 Logo + 应用名，右账号入口。
    /// 对齐网页端 hero 左上角的品牌 bar —— 首页不再堆搜索/通知这类空壳按钮，
    /// 右上角只留一个真正有去处的动作：登录，或已登录时的身份入口。
    private var topBar: some View {
        HStack(spacing: 10) {
            // 品牌区就是侧边栏入口。
            //
            // HIG 不推荐汉堡菜单，但抽屉仍然需要一个随时可达的打开方式；
            // "点应用名 / Logo 打开导航"是系统里已有的心智（邮件、备忘录都是这样）。
            // 右侧小箭头给出可点的暗示，否则它看起来只是一行标题。
            Button {
                openSidebar()
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.Palette.brandGradient)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: SymbolCompat.name("video.fill", "video"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                        )

                    Text("天穹会议")
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundColor(Theme.Palette.ink)

                    Image(systemName: SymbolCompat.name("chevron.right", "chevron.forward"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.Palette.ink3)
                        .padding(.leading, -3)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("打开导航菜单")

            Spacer(minLength: 8)

            accountEntry
        }
        .frame(height: 44)
    }

    /// 右上角账号入口。游客态就是网页端那颗「登录」，已登录收敛成头像胶囊，
    /// 点开仍是同一个资料面板，不额外造一个"账号中心"。
    @ViewBuilder
    private var accountEntry: some View {
        if session != nil {
            Button {
                openProfileEditor()
            } label: {
                HStack(spacing: 7) {
                    AvatarView(user: profileUser, size: 24, showsSpeakingRing: false)

                    Text(router.profile.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.Palette.ink)
                        .lineLimit(1)
                        .frame(maxWidth: 96, alignment: .leading)
                }
                .padding(.leading, 5)
                .padding(.trailing, 12)
                .frame(height: 34)
                .liquidGlass(.clear, cornerStyle: .capsule, isInteractive: true, castsShadow: false)
                .contentShape(Capsule())
            }
            .buttonStyle(BrandPressStyle())
            .accessibilityLabel("账号与个人资料")
        } else {
            Button {
                Haptics.impact(.light)
                Keyboard.dismiss()
                isLoginPresented = true
            } label: {
                Text("登录")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)
                    .padding(.horizontal, 18)
                    .frame(height: 34)
                    .liquidGlass(.clear, cornerStyle: .capsule, isInteractive: true, castsShadow: false)
                    .contentShape(Capsule())
            }
            .buttonStyle(BrandPressStyle())
            .accessibilityLabel("登录账号")
        }
    }

    // MARK: - 会议 Tab

    /// 首页主体 = 网页端 hero 的手机版：一句标题 → 一张入会卡 → 最近会议。
    /// 顺序与信息密度都照网页来，不做"两个大方块"那种 App 自创布局。
    private var meetingsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            joinCard
                .padding(.top, 22)
            historySection
                .padding(.top, 28)
        }
    }

    // MARK: 标题

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("一个会议号，")
                    .foregroundColor(Theme.Palette.ink)

                // 第二行用实色强调，不做渐变。
                //
                // 渐变文字是"AI 生成感"最重的一处：它没有品牌含义，只是为了让画面
                // 显得热闹，而且在小字号下会让笔画发灰。苹果自己的大标题从来是单色。
                Text("把会开在屏幕里。")
                    .foregroundColor(Theme.Palette.accent)
            }
            .font(.system(size: 28, weight: .semibold))
            .tracking(-0.3)
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            Text("输入会议号即可入会，支持屏幕共享与实时字幕。")
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.ink2)
        }
        .padding(.top, 24)
    }

    // MARK: 入会卡

    /// 入会卡：原生玻璃面板 + 系统分段控件。
    ///
    /// 之前的分段是自绘的（两层圆角 + 两道描边 + 选中填充），叠起来之后边缘发亮，
    /// 正是"塑料感"的来源之一。这里直接用系统 `Picker(.segmented)`：
    /// iOS 26 上它本身就是玻璃材质，选中态由系统做液态过渡，和卡片是同一套材质语言。
    private var joinCard: some View {
        VStack(spacing: 16) {
            Picker("入会方式", selection: $joinMode) {
                Text("加入会议").tag(HomeJoinMode.join)
                Text("发起会议").tag(HomeJoinMode.start)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                if joinMode == .join {
                    joinPanel
                } else {
                    startPanel
                }
            }
        }
        .padding(16)
        .liquidGlass(.regular, cornerStyle: .continuous(24), castsShadow: false)
        .animationCompat(Theme.Motion.standard, value: joinMode)
    }

    // MARK: 加入面板

    private var joinPanel: some View {
        VStack(spacing: 14) {
            fieldGroup
            deviceRow
            joinButton
            privacyNote
        }
    }

    /// 两个输入框合成一组，中间一条 1px 分隔线。
    ///
    /// 原来的写法是"每个输入框各自一个圆角块 + 各自一圈描边"，两个块并排时
    /// 会出现四条平行亮边，看起来像塑料拼装件。系统设置的做法是**一组**：
    /// 一个浅底容器，行与行之间一条发丝线，容器本身没有边框。
    private var fieldGroup: some View {
        VStack(spacing: 0) {
            numberRow

            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(height: 1)
                .padding(.leading, 46)

            nameRow
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var numberRow: some View {
        HStack(spacing: 10) {
            Image(systemName: SymbolCompat.name("number", "number"))
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(meetingNumber.isEmpty ? Theme.Palette.ink3 : Theme.Palette.accent)
                .frame(width: 22)

            TextField("会议号", text: $meetingNumber)
                .keyboardType(.numberPad)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundColor(Theme.Palette.ink)
                .tracking(1.2)
                // 会议号只可能是数字：输入法粘贴进来的连字符、空格直接剔掉，
                // 长度按 9 位截断（服务端最多 9 位，留一位余量比截断成 7 位更安全）。
                .onChange(of: meetingNumber) { value in
                    let digits = String(value.filter { $0.isNumber }.prefix(9))
                    if digits != value {
                        meetingNumber = digits
                    }
                }
                .accessibilityLabel("会议号")

            if !meetingNumber.isEmpty {
                Button {
                    Haptics.selection()
                    meetingNumber = ""
                } label: {
                    Image(systemName: SymbolCompat.name("xmark.circle.fill", "xmark.circle"))
                        .font(.system(size: 16))
                        .foregroundColor(Theme.Palette.ink3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("清空会议号")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private var nameRow: some View {
        HStack(spacing: 10) {
            Image(systemName: SymbolCompat.name("person", "person.fill"))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.Palette.ink3)
                .frame(width: 22)

            TextField("你的名称（选填）", text: $guestName)
                .font(.system(size: 15))
                .foregroundColor(Theme.Palette.ink)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onChange(of: guestName) { value in
                    if value.count > 24 {
                        guestName = String(value.prefix(24))
                    }
                }
                .accessibilityLabel("你的名称，选填")

            if !guestName.isEmpty {
                Button {
                    Haptics.selection()
                    guestName = ""
                } label: {
                    Image(systemName: SymbolCompat.name("xmark.circle.fill", "xmark.circle"))
                        .font(.system(size: 15))
                        .foregroundColor(Theme.Palette.ink3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("清空名称")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    /// 麦克风 / 摄像头预置。和网页端一样只做「入会前最后一次检查」，
    /// 不冒充设备选择器——真正的切换在会议室里。
    private var deviceRow: some View {
        HStack(spacing: 8) {
            deviceChip(
                isOn: isMicOn,
                onSymbol: "mic.fill",
                offSymbol: "mic.slash.fill",
                title: "麦克风"
            ) {
                isMicOn.toggle()
            }

            deviceChip(
                isOn: isCameraOn,
                onSymbol: "video.fill",
                offSymbol: "video.slash.fill",
                title: "摄像头"
            ) {
                isCameraOn.toggle()
            }

            Spacer(minLength: 0)
        }
    }

    /// 胶囊玻璃芯片：常态是系统玻璃，关闭态是红色染色玻璃。
    /// 不再自己画底色 + 描边——两圈边叠在一起就是塑料感的来源。
    private func deviceChip(
        isOn: Bool,
        onSymbol: String,
        offSymbol: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: SymbolCompat.name(isOn ? onSymbol : offSymbol, "questionmark.circle"))
                    .font(.system(size: 12, weight: .semibold))

                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isOn ? Theme.Palette.ink2 : Color(hex: 0xFCA5A5))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .liquidGlass(
                isOn ? .regular : .tinted(Theme.Palette.danger),
                cornerStyle: .capsule,
                isInteractive: true,
                castsShadow: false
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(isOn ? "关闭\(title)" : "开启\(title)")
        .accessibilityValue(isOn ? "已开启" : "已关闭")
    }

    private var canJoin: Bool {
        !meetingNumber.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var joinButton: some View {
        Button {
            Haptics.impact(.medium)
            joinFromHome()
        } label: {
            Text("加入会议")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
        // 染色玻璃 + 白字，就是系统 `.glassProminent` 的成色。
        // 之前给文字加暗投影是多余的一层：投影会压在玻璃折射之上，字看着发脏。
        .liquidGlass(
            .tinted(Theme.Palette.accent),
            cornerStyle: .continuous(14),
            isInteractive: true,
            castsShadow: false
        )
        .opacity(canJoin ? 1.0 : 0.5)
        .disabled(!canJoin)
        .accessibilityLabel("加入会议")
    }

    private var privacyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: SymbolCompat.name("lock.shield", "lock.fill"))
                .font(.system(size: 10.5))

            Text("会议内容仅在参会者之间传输，不经过第三方服务。")
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(Theme.Palette.ink3)
        .padding(.top, 2)
    }

    // MARK: 发起面板

    private var startPanel: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("立即发起一场会议")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)

                Text("系统会分配一个会议号，把号码发给同事即可入会。")
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.Palette.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            Button {
                Haptics.impact(.medium)
                startMeetingFromHome()
            } label: {
                Text("发起即时会议")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .liquidGlass(
                .tinted(Theme.Palette.accent),
                cornerStyle: .continuous(14),
                isInteractive: true,
                castsShadow: false
            )
            .accessibilityLabel("发起即时会议")

            VStack(alignment: .leading, spacing: 7) {
                startTip("支持屏幕共享与全员静音")
                startTip("企业账号可预约会议并邀请成员")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    private func startTip(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: SymbolCompat.name("checkmark", "checkmark"))
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.Palette.success)

            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(Theme.Palette.ink3)
        }
    }

    // MARK: 入会动作

    private func joinFromHome() {
        Keyboard.dismiss()

        let trimmed = meetingNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast("请先输入会议号", icon: "number", style: .warning)
            return
        }

        // 名称留空 = 访客。已登录用户没填时沿用账号昵称，避免"登了录还叫访客"。
        let typed = guestName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if !typed.isEmpty {
            name = typed
        } else if session != nil {
            name = router.profile.displayName
        } else {
            name = "访客"
        }

        router.openPreJoin(
            JoinInfo(
                meetingNumber: trimmed,
                title: "会议 \(trimmed)",
                displayName: name,
                isHost: false,
                avatarColorIndex: router.profile.avatarColorIndex,
                // 首页的两个开关必须一路带到入会页与会议室。
                // 之前这里用的是 JoinInfo 的默认值，导致"在首页关了麦，进会还是开着"——
                // 用户唯一能做的入会前检查，结果完全没生效。
                micOn: isMicOn,
                cameraOn: isCameraOn,
                token: AuthStore.load()?.token ?? ""
            )
        )
    }

    // MARK: 历史会议

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("历史会议")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)

                Spacer(minLength: 8)

                Button {
                    clearHistory()
                } label: {
                    Text("清空")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.ink3)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(router.history.isEmpty)
                .opacity(router.history.isEmpty ? 0.4 : 1.0)
                .accessibilityLabel("清空历史会议")
            }

            if router.history.isEmpty {
                historyEmptyState
                    .padding(.top, 8)
            } else {
                // 历史记录合成一张玻璃卡，行间用发丝线分隔。
                // 每条记录单独包一层玻璃的做法，会让 5 条记录变成 5 块各自反光的
                // 卡片，视觉噪音大，也不像系统列表。
                VStack(spacing: 0) {
                    ForEach(Array(router.history.enumerated()), id: \.element.id) { index, item in
                        historyRow(item)

                        if index < router.history.count - 1 {
                            Rectangle()
                                .fill(Theme.Palette.hairline)
                                .frame(height: 1)
                                .padding(.leading, 68)
                        }
                    }
                }
                .liquidGlass(.regular, cornerStyle: .continuous(18), castsShadow: false)
                .padding(.top, 10)
            }
        }
    }

    private var historyEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: SymbolCompat.name("calendar.badge.clock", "calendar"))
                .font(.system(size: 30, weight: .light))
                .foregroundColor(Theme.Palette.ink3)

            Text("暂无历史会议")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.Palette.ink2)

            Text("发起或加入一个会议后会自动记录")
                .font(.system(size: 12))
                .foregroundColor(Theme.Palette.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .liquidGlass(
            .regular,
            cornerStyle: .continuous(Theme.Metrics.cardRadius),
            castsShadow: false
        )
    }

    private func historyRow(_ item: MeetingHistoryItem) -> some View {
        Button {
            Haptics.impact(.light)
            router.openPreJoin(
                JoinInfo(
                    meetingNumber: item.number,
                    title: item.title,
                    displayName: router.profile.displayName,
                    isHost: false
                )
            )
        } label: {
            HStack(spacing: 12) {
                dateBlock(item.startedAt)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(JoinInfo.groupDigits(item.number))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(Theme.Palette.ink3)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(item.durationText)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.ink2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 64)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(BrandPressStyle())
        // 长按删除。iOS 14 的 Button 没有 role 参数，用普通 Button + 红色图标表达危险语义。
        .contextMenu {
            Button {
                Haptics.impact(.medium)
                router.removeHistory(id: item.id)
            } label: {
                Label("删除记录", systemImage: "trash")
            }
        }
    }

    private func dateBlock(_ date: Date) -> some View {
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        let day = components.day ?? 1
        let month = components.month ?? 1

        return VStack(spacing: 0) {
            Text("\(day)")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Theme.Palette.ink)

            Text("\(month)月")
                .font(.system(size: 9))
                .foregroundColor(Theme.Palette.ink3)
        }
        .frame(width: 44, height: 44)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                .fill(Theme.Palette.accent.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                .stroke(Theme.Palette.glassStroke, lineWidth: 1)
        )
    }

    // MARK: - 联系人 Tab

    private var contactsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("通讯录")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)

                Text("邀请同事加入你的会议")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Palette.ink2)
            }
            .padding(.top, 24)

            VStack(spacing: 12) {
                Image(systemName: SymbolCompat.name("person.2", "person.2.fill"))
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(Theme.Palette.ink3)

                Text("还没有参会人")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)

                Text("把会议号或邀请链接发给同事，对方打开就能入会")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.ink3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    inviteFromContacts()
                } label: {
                    Text("邀请参会人")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink)
                        .padding(.horizontal, 22)
                        .frame(height: 44)
                        .liquidGlass(
                            .regular,
                            cornerStyle: .capsule,
                            isInteractive: true,
                            castsShadow: false
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, 6)
                .accessibilityLabel("邀请参会人")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .padding(.horizontal, 20)
            .liquidGlass(
                .regular,
                cornerStyle: .continuous(Theme.Metrics.cardRadius),
                castsShadow: false
            )
            .padding(.top, 20)
        }
    }

    // MARK: - Toast

    private func toastLayer(bottomInset: CGFloat) -> some View {
        VStack {
            Spacer(minLength: 0)

            if let message = toast {
                ToastView(message: message)
                    // id 变化时重建，让连续两条提示都能重播进入动画。
                    .id(message.id)
                    .padding(.horizontal, pagePadding)
                    .padding(.bottom, 96 + bottomInset)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animationCompat(Theme.Motion.standard, value: toast?.id)
        .allowsHitTesting(false)
    }

    private func showToast(
        _ text: String,
        icon: String,
        style: ToastStyle = .info
    ) {
        let message = ToastMessage(text: text, systemImage: icon, style: style)
        withAnimation(Theme.Motion.standard) {
            toast = message
        }

        toastWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(Theme.Motion.standard) {
                if toast?.id == message.id {
                    toast = nil
                }
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - 发起会议（真实链路）

    /// 首页"发起会议"：真实链路向服务端创建即时会议（需要登录），
    /// 拿到会议号后进入入会页，主持人身份沿用。
    private func startMeetingFromHome() {
        guard AuthStore.load() != nil else {
            showToast("发起会议需要先登录", icon: "person.crop.circle.badge.exclamationmark", style: .warning)
            return
        }

        let name = router.profile.displayName
        APIClient.createMeeting(title: "\(name)的会议", instant: true) { result in
            switch result {
            case .success(let meeting):
                self.router.openPreJoin(
                    JoinInfo(
                        meetingNumber: meeting.no,
                        title: meeting.title,
                        displayName: name,
                        isHost: true,
                        avatarColorIndex: self.router.profile.avatarColorIndex,
                        micOn: self.isMicOn,
                        cameraOn: self.isCameraOn,
                        token: AuthStore.load()?.token ?? ""
                    )
                )
            case .failure(let error):
                self.showToast(
                    (error as? APIClient.APIError)?.message ?? "创建会议失败，请稍后重试",
                    icon: "exclamationmark.triangle.fill",
                    style: .danger
                )
            }
        }
    }

    // MARK: - 个人资料

    private func openProfileEditor() {
        Haptics.impact(.light)
        draftName = router.profile.displayName
        draftColor = router.profile.avatarColorIndex
        withAnimation(Theme.Motion.standard) {
            isEditingProfile = true
        }
    }

    private func dismissProfileEditor() {
        Keyboard.dismiss()
        withAnimation(Theme.Motion.standard) {
            isEditingProfile = false
        }
    }

    private func profileEditor(bottomInset: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissProfileEditor()
                }

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("编辑资料")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink)

                    Spacer(minLength: 8)

                    Button {
                        dismissProfileEditor()
                    } label: {
                        Image(systemName: SymbolCompat.name("xmark"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.Palette.ink2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("关闭资料编辑")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("昵称")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.ink3)

                    TextField("请输入昵称", text: $draftName)
                        .font(.system(size: 15))
                        .foregroundColor(Theme.Palette.ink)
                        .accentColor(Theme.Palette.accent)
                        .padding(.horizontal, 16)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Theme.Palette.glassStroke, lineWidth: 1)
                        )
                        .onChange(of: draftName) { value in
                            if value.count > 30 {
                                draftName = String(value.prefix(30))
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("头像颜色")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.ink3)

                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 12),
                            count: 4
                        ),
                        spacing: 12
                    ) {
                        ForEach(
                            Array(0..<UserProfileStore.avatarColorCount),
                            id: \.self
                        ) { index in
                            colorSwatch(index)
                        }
                    }
                }

                Button {
                    saveProfile()
                } label: {
                    Text("保存")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                                .fill(Theme.Palette.brandGradient)
                        )
                }
                .buttonStyle(BrandPressStyle())
                .padding(.top, 2)
            }
            .padding(.horizontal, pagePadding)
            .padding(.top, 20)
            .padding(.bottom, max(max(bottomInset, keyboardHeight), 12) + 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.panelRadius, style: .continuous)
                    .fill(Theme.Palette.backgroundElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.panelRadius, style: .continuous)
                            .stroke(Theme.Palette.glassStroke, lineWidth: 1)
                    )
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    private func colorSwatch(_ index: Int) -> some View {
        let isSelected = draftColor == index

        return Button {
            Haptics.selection()
            withAnimation(Theme.Motion.standard) {
                draftColor = index
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.avatarGradient(index: index))
                    .frame(width: 36, height: 36)

                if isSelected {
                    Circle()
                        .stroke(Theme.Palette.accent, lineWidth: 2)
                        .frame(width: 42, height: 42)

                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("头像颜色 \(index + 1)")
    }

    private func saveProfile() {
        router.updateProfile(displayName: draftName, avatarColorIndex: draftColor)
        dismissProfileEditor()
        showToast("资料已保存", icon: "checkmark.circle.fill", style: .success)
    }

    // MARK: - 动作

    private func clearHistory() {
        guard !router.history.isEmpty else { return }
        Haptics.impact(.medium)
        router.clearHistory()
        showToast("历史记录已清空", icon: "trash", style: .info)
    }

    private func inviteFromContacts() {
        guard let latest = router.history.first else {
            showToast("请先发起或加入一个会议", icon: "calendar")
            return
        }
        UIPasteboard.general.string = latest.number
        showToast("会议号已复制", icon: "doc.on.doc.fill", style: .success)
    }

    // MARK: - 派生

    private var profileUser: MeetingUser {
        MeetingUser(
            id: "local-me",
            name: router.profile.displayName,
            role: .participant,
            isMicOn: false,
            isCameraOn: false,
            isHandRaised: false,
            isSpeaking: false,
            isLocal: true,
            avatarColorIndex: router.profile.avatarColorIndex
        )
    }
}

// MARK: - 首页入会模式

/// 首页入会卡的两种模式。
///
/// 单独一个类型而不是 Bool，是为了后续加「预约会议」时不至于变成
/// `isJoin / !isJoin` 的二态泥潭；case 名字直接对应网页端的两枚 tab。
enum HomeJoinMode: Hashable {
    case join
    case start
}
