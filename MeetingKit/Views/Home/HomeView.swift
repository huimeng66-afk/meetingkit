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

    @State private var tab: HomeTab = .meetings
    @State private var isEditingProfile = false
    @State private var draftName = ""
    @State private var draftColor = 0

    // MARK: 首页入会表单（对齐网页端 hero 的 join-card）

    /// 加入 / 发起。网页端是两枚 tab，App 端保持同一套心智，不另发明入口。
    @State private var joinMode: HomeJoinMode = .join
    @State private var meetingNumber = ""
    /// 选填名称。空串时以「访客」入会，与网页端 placeholder 语义一致。
    @State private var guestName = ""
    @State private var isMicOn = true
    @State private var isCameraOn = true
    @State private var isLoginPresented = false
    /// 登录态只在进入首页 / 关闭登录页时读一次，避免每帧读 Keychain。
    @State private var session: AuthSession? = AuthStore.load()

    /// Dock 两块玻璃的融合域。iOS 26 上同 namespace 的玻璃会互相吸附。
    @Namespace private var dockNamespace

    @State private var toast: ToastMessage?
    @State private var toastWork: DispatchWorkItem?

    /// GeometryReader 不会为键盘自动上移，资料卡的昵称输入需要自己抬起来。
    @State private var keyboardHeight: CGFloat = 0

    /// 设计稿页面边距 20（比会议室内部的 16 更接近 iOS 阅读习惯）。
    private let pagePadding: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets

            ZStack(alignment: .bottom) {
                BrandBackground()

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
                    // 悬浮 Dock 实际占位 56 + 10，再留 20 呼吸位，
                    // 保证最后一行历史记录滚到底时不会被胶囊压住。
                    //
                    // 首页现在有两个输入框，键盘弹起时必须能把「加入会议」顶上来：
                    // 根视图整棵忽略了键盘安全区（否则底栏会被顶到键盘上方），
                    // 所以这里手动把键盘高度补进滚动内容底部。
                    .padding(.bottom, 86 + insets.bottom + keyboardHeight)
                }
                // 手动吃安全区：GeometryReader 里的子视图从屏幕原点开始，
                // 不加这一行，滚动内容会钻到刘海下面，而顶部留白已经显式给过了。
                .ignoresSafeArea()

                tabBar(bottomInset: insets.bottom)

                toastLayer(bottomInset: insets.bottom)

                if isEditingProfile {
                    profileEditor(bottomInset: insets.bottom)
                }
            }
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

    // MARK: - 顶部

    /// 品牌头：左 Logo + 应用名，右账号入口。
    /// 对齐网页端 hero 左上角的品牌 bar —— 首页不再堆搜索/通知这类空壳按钮，
    /// 右上角只留一个真正有去处的动作：登录，或已登录时的身份入口。
    private var topBar: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.brandGradient)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: SymbolCompat.name("video.fill", "video"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                )
                .shadow(color: Theme.Palette.accent.opacity(0.5), radius: 10, y: 4)

            Text("天穹会议")
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.2)
                .foregroundColor(Theme.Palette.ink)

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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("一个会议号，")
                    .foregroundColor(Theme.Palette.ink)

                // 渐变只作用于这一行：整段渐变会稀释强调，网页端也只强调后半句。
                gradientText("把会开在屏幕里。")
            }
            // 30pt 是 375pt 宽度下 9 个汉字不折行的上限；SE 上再缩到 0.82，
            // 宁可整体略小，也不要出现「把会开在屏幕 / 里。」这种断句。
            // lineLimit 写在每个 Text 上而不是 VStack 上：环境值虽然会下发，
            // 但 VStack 自身也吃到 lineLimit 时，SwiftUI 会按单行去量它的高度。
            .font(.system(size: 30, weight: .bold))
            .tracking(-0.8)
            .lineLimit(1)
            .minimumScaleFactor(0.82)

            Text("不用装客户端，输个号码就能入会。高清音视频、屏幕共享，手机竖屏也顺手。")
                .font(.system(size: 13.5))
                .foregroundColor(Theme.Palette.ink2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 26)
    }

    /// iOS 14 没有 `foregroundStyle(Gradient)`，用遮罩实现同样的渐变文字。
    private func gradientText(_ text: String) -> some View {
        Text(text)
            .foregroundColor(.white)
            .overlay(
                LinearGradient(
                    colors: [
                        Color(hex: 0x8FB6FF),
                        Theme.Palette.accent,
                        Color(hex: 0xA98BFF)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .mask(Text(text))
            )
    }

    // MARK: 入会卡

    private var joinCard: some View {
        VStack(spacing: 0) {
            modeSwitcher

            Group {
                if joinMode == .join {
                    joinPanel
                } else {
                    startPanel
                }
            }
            .padding(.top, 18)
        }
        .padding(18)
        .liquidGlass(.regular, cornerStyle: .continuous(26), castsShadow: true)
    }

    private var modeSwitcher: some View {
        HStack(spacing: 4) {
            modeButton(.join, title: "加入会议")
            modeButton(.start, title: "发起会议")
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private func modeButton(_ mode: HomeJoinMode, title: String) -> some View {
        let isSelected = joinMode == mode

        return Button {
            guard joinMode != mode else { return }
            Haptics.selection()
            Keyboard.dismiss()
            withAnimation(Theme.Motion.standard) {
                joinMode = mode
            }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isSelected ? Theme.Palette.ink : Theme.Palette.ink3)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.11) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? Color.white.opacity(0.14) : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: 加入面板

    private var joinPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            fieldLabel("会议号")
            numberField

            fieldLabel("你的名称", optional: true)
            nameField

            deviceRow

            joinButton

            privacyNote
        }
    }

    private func fieldLabel(_ text: String, optional: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.Palette.ink2)

            if optional {
                Text("选填")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.Palette.ink3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.white.opacity(0.06))
                    )
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, -6)
    }

    private var numberField: some View {
        HStack(spacing: 10) {
            Image(systemName: SymbolCompat.name("number", "number"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(meetingNumber.isEmpty ? Theme.Palette.ink3 : Theme.Palette.accent)

            TextField("输入 7 位会议号", text: $meetingNumber)
                .keyboardType(.numberPad)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.Palette.ink)
                .tracking(1.5)
                // 会议号只可能是数字：输入法粘贴进来的连字符、空格直接剔掉，
                // 长度按 9 位截断（服务端最多 9 位，留一位余量比截断成 7 位更安全）。
                .onChange(of: meetingNumber) { value in
                    let digits = String(value.filter { $0.isNumber }.prefix(9))
                    if digits != value {
                        meetingNumber = digits
                    }
                }

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
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    meetingNumber.isEmpty
                        ? Color.white.opacity(0.10)
                        : Theme.Palette.accent.opacity(0.55),
                    lineWidth: 1
                )
        )
    }

    private var nameField: some View {
        HStack(spacing: 10) {
            Image(systemName: SymbolCompat.name("person", "person.fill"))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.Palette.ink3)

            TextField("不填写将以「访客」身份入会", text: $guestName)
                .font(.system(size: 15))
                .foregroundColor(Theme.Palette.ink)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onChange(of: guestName) { value in
                    if value.count > 24 {
                        guestName = String(value.prefix(24))
                    }
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
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

            Text("入会后可调整")
                .font(.system(size: 10.5))
                .foregroundColor(Theme.Palette.ink3)
        }
        .padding(.top, 2)
    }

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
            // 关闭态用红：与会议室底栏同一套语义，颜色之外还有斜杠图标兜底。
            .foregroundColor(isOn ? Theme.Palette.ink2 : Theme.Palette.danger)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                Capsule().fill(
                    isOn
                        ? Color.white.opacity(0.06)
                        : Theme.Palette.danger.opacity(0.14)
                )
            )
            .overlay(
                Capsule().stroke(
                    isOn
                        ? Color.white.opacity(0.08)
                        : Theme.Palette.danger.opacity(0.34),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(BrandPressStyle())
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
                // 染色玻璃会把 accent 稀释一层，纯白字直接压上去在亮处偏薄，
                // 一点暗投影把字从折射里拎出来。
                .shadow(color: Color.black.opacity(0.28), radius: 6, y: 1)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
        // 主 CTA 走原生染色玻璃：iOS 26 上是系统 `.tint` 玻璃（自带你按下时的
        // 形变与高光），14~25 退回同色系的着色合成，两条路径同一个调用点。
        .liquidGlass(
            .tinted(Theme.Palette.accent),
            cornerStyle: .continuous(16),
            isInteractive: true,
            castsShadow: true
        )
        .opacity(canJoin ? 1.0 : 0.52)
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
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Theme.Palette.accent.opacity(0.28),
                            Theme.Palette.violet.opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 96)
                .overlay(
                    Image(systemName: SymbolCompat.name("video.badge.plus", "video.fill"))
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            Text("立即发起一场会议")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.Palette.ink)

            Text("系统会分配一个会议号，把链接发给同事即可入会。")
                .font(.system(size: 12.5))
                .foregroundColor(Theme.Palette.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Haptics.impact(.medium)
                startMeetingFromHome()
            } label: {
                Text("发起即时会议")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(color: Color.black.opacity(0.28), radius: 6, y: 1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .liquidGlass(
                .tinted(Theme.Palette.accent),
                cornerStyle: .continuous(16),
                isInteractive: true,
                castsShadow: true
            )
            .padding(.top, 4)
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
                VStack(spacing: 12) {
                    ForEach(router.history) { item in
                        historyRow(item)
                    }
                }
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
            .padding(.horizontal, 12)
            .frame(height: 68)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
            // 玻璃画在 label 内部：按下时 BrandPressStyle 的 0.96 才能带着玻璃一起缩，
            // 否则会出现"内容缩了、卡片没缩"的割裂感。
            .liquidGlass(
                .regular,
                cornerStyle: .continuous(Theme.Metrics.cardRadius),
                castsShadow: false
            )
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
                Text("联系人")
                    .font(.system(size: 28, weight: .bold))
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
                        .foregroundColor(Theme.Palette.accent)
                        .padding(.horizontal, 22)
                        .frame(height: 44)
                        .background(
                            Capsule().fill(Theme.Palette.accent.opacity(0.12))
                        )
                        .overlay(
                            Capsule().stroke(Theme.Palette.accent.opacity(0.32), lineWidth: 1)
                        )
                }
                .buttonStyle(BrandPressStyle())
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

    // MARK: - 底部 Dock

    /// 悬浮胶囊 Dock。
    ///
    /// iOS 26 上走 `GlassEffectContainer` + 每个 tab 独立玻璃：
    /// 两块玻璃靠近时会像水珠一样吸附、点选后液化成选中态 —— 这是系统
    /// Liquid Glass 与自绘模糊最本质的差别，用一整块玻璃包住两颗按钮是做不出来的。
    /// 14~25 上容器退化为普通 HStack，视觉仍是两颗胶囊，布局完全一致。
    private func tabBar(bottomInset: CGFloat) -> some View {
        LiquidGlassContainer(spacing: 12) {
            HStack(spacing: 8) {
                tabButton(.meetings)
                tabButton(.contacts)
            }
        }
        .padding(.bottom, bottomInset + 10)
    }

    private func tabButton(_ item: HomeTab) -> some View {
        let isSelected = tab == item

        return Button {
            guard tab != item else { return }
            Haptics.selection()
            withAnimation(Theme.Motion.standard) {
                tab = item
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? item.selectedSymbol : item.symbol)
                    .font(.system(size: 16, weight: .semibold))

                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : Theme.Palette.ink2)
            .padding(.horizontal, 20)
            .frame(height: 48)
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        // 选中态用染色玻璃而不是实心色块：染色仍然保留折射与高光，
        // 实心填充会把 Dock 变成两颗普通按钮。
        .liquidGlass(
            isSelected ? .tinted(Theme.Palette.accent) : .regular,
            cornerStyle: .capsule,
            isInteractive: true,
            castsShadow: true
        )
        // 同一个 namespace 下的玻璃才会互相吸附；去掉这行就退回两团独立模糊。
        .liquidGlassID(item.title, in: dockNamespace)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                    .padding(.bottom, 86 + bottomInset)
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

// MARK: - Tab 枚举

private enum HomeTab {
    case meetings
    case contacts

    var title: String {
        switch self {
        case .meetings:
            return "会议"
        case .contacts:
            return "联系人"
        }
    }

    var symbol: String {
        switch self {
        case .meetings:
            return SymbolCompat.name("video", "calendar")
        case .contacts:
            return SymbolCompat.name("person.2", "person.2.fill")
        }
    }

    var selectedSymbol: String {
        switch self {
        case .meetings:
            return SymbolCompat.name("video.fill", "video")
        case .contacts:
            return SymbolCompat.name("person.2.fill", "person.2")
        }
    }
}

// MARK: - 首页入会模式

/// 首页入会卡的两种模式。
///
/// 单独一个类型而不是 Bool，是为了后续加「预约会议」时不至于变成
/// `isJoin / !isJoin` 的二态泥潭；case 名字直接对应网页端的两枚 tab。
enum HomeJoinMode: Equatable {
    case join
    case start
}
