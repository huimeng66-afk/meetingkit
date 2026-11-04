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
                    .padding(.bottom, 86 + insets.bottom)
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
        .onDisappear {
            toastWork?.cancel()
        }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                openProfileEditor()
            } label: {
                HStack(spacing: 12) {
                    AvatarView(user: profileUser, size: 38, showsSpeakingRing: false)

                    Text(router.profile.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                // 头像 38，但按钮命中区必须补到 44。
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(BrandPressStyle())
            .accessibilityLabel("编辑个人资料")

            Spacer(minLength: 8)

            HomeIconButton(
                systemImage: "magnifyingglass",
                accessibilityLabel: "搜索联系人"
            ) {
                showToast("搜索联系人即将上线", icon: "magnifyingglass")
            }

            HomeIconButton(
                systemImage: "bell",
                accessibilityLabel: "通知",
                showsBadge: true
            ) {
                showToast("暂无新通知", icon: "bell")
            }
        }
        .frame(height: 44)
    }

    // MARK: - 会议 Tab

    private var meetingsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("天穹会议")
                    // 34pt + 收紧字距：这是 iOS 大标题的标准观感，
                    // 28pt bold 在 6.1 寸屏上会显得"没长开"。
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundColor(Theme.Palette.ink)

                Text("高效稳定的企业级视频会议")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Palette.ink2)
            }
            .padding(.top, 22)

            VStack(spacing: 12) {
                PrimaryMeetingCard {
                    Haptics.impact(.light)
                    startMeetingFromHome()
                }

                SecondaryMeetingCard {
                    Haptics.impact(.light)
                    router.openPreJoin(
                        JoinInfo(
                            meetingNumber: "",
                            title: "加入会议",
                            displayName: router.profile.displayName,
                            isHost: false
                        )
                    )
                }
            }
            .padding(.top, 22)

            historySection
                .padding(.top, 26)
        }
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
    /// 从"通栏 + 1px 顶边"改成悬浮胶囊，是这次视觉重做里改动最小、感知最强的一处：
    /// 通栏在观感上属于 Android / Web，悬浮胶囊才是 iOS 26 之后的原生语言，
    /// 而且胶囊四周留出的背景能让玻璃真的"浮"在极光上。
    private func tabBar(bottomInset: CGFloat) -> some View {
        HStack(spacing: 4) {
            tabButton(.meetings)
            tabButton(.contacts)
        }
        .padding(6)
        .liquidGlass(
            .regular,
            cornerStyle: .continuous(30),
            castsShadow: true
        )
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
            .foregroundColor(isSelected ? Theme.Palette.ink : Theme.Palette.ink3)
            // 选中态是一层很薄的着色胶囊，不是实心块：
            // 实心块会把玻璃的折射全挡住，Dock 立刻变成"两个按钮"。
            .background(
                Capsule()
                    .fill(isSelected ? Theme.Palette.accent.opacity(0.20) : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(
                        isSelected ? Theme.Palette.accent.opacity(0.34) : Color.clear,
                        lineWidth: 1
                    )
            )
            .padding(.horizontal, 18)
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
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

// MARK: - 顶部图标钮

/// 视觉 36 / 命中 44。设计稿画的是 36，但 iOS 的触控下限是 44，
/// 多出来的 4pt 透明区不可见，却能把误触率降下来。
private struct HomeIconButton: View {

    let systemImage: String
    let accessibilityLabel: String
    var showsBadge: Bool = false

    let action: () -> Void

    var body: some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Image(systemName: SymbolCompat.name(systemImage, SymbolCompat.fallbackName))
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.Palette.ink2)
                .frame(width: 36, height: 36)
                .liquidGlass(.clear, cornerStyle: .circle, castsShadow: false)
                .overlay(
                    Group {
                        if showsBadge {
                            Circle()
                                .fill(Theme.Palette.danger)
                                .frame(width: 7, height: 7)
                                .overlay(
                                    Circle().stroke(Theme.Palette.background, lineWidth: 1.5)
                                )
                                .offset(x: 1, y: -1)
                        }
                    },
                    alignment: .topTrailing
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(BrandPressStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - 主操作卡

/// 「发起会议」。首页唯一的主动作，所以给它整行宽度、渐变底光和实心渐变圆。
///
/// 为什么不做成两张并排的方块：并排卡在视觉上是"两个入口"，权重相同；
/// 而会议类产品的真实心智是"开一场会"是主路径、"输号加入"是次路径。
/// 拆成一主一次之后，首屏有了明确的视觉落点。
private struct PrimaryMeetingCard: View {

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // 渐变底光：叠在玻璃下面的色层，让这张卡比周围亮一档。
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Theme.Palette.brandGradient)
                    .opacity(0.20)

                // 左上角高光，模拟光线从屏幕外打进玻璃边缘。
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.14), location: 0.0),
                                .init(color: Color.clear, location: 0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("发起会议")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(Theme.Palette.ink)

                        Text("立即开始一场即时会议")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.Palette.ink2)
                    }

                    Spacer(minLength: 8)

                    ZStack {
                        // 图标后面的光晕：比图标大一圈的模糊圆，
                        // 让渐变圆盘看起来在发光，而不是贴上去的一块色。
                        Circle()
                            .fill(Theme.Palette.accent)
                            .frame(width: 44, height: 44)
                            .blur(radius: 16)
                            .opacity(0.75)

                        Circle()
                            .fill(Theme.Palette.brandGradient)
                            .frame(width: 52, height: 52)
                            .overlay(
                                Circle().stroke(Color.white.opacity(0.22), lineWidth: 1)
                            )

                        Image(systemName: SymbolCompat.name("video.fill", "video"))
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(height: 100)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .liquidGlass(
                .regular,
                cornerStyle: .continuous(24),
                castsShadow: true
            )
        }
        .buttonStyle(BrandPressStyle())
        .accessibilityLabel("发起会议")
    }
}

// MARK: - 次操作卡

/// 「加入会议」。刻意压低存在感：小圆、无渐变、无光晕，
/// 只保留一条 chevron 暗示可进入。
private struct SecondaryMeetingCard: View {

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 40, height: 40)
                        .overlay(Circle().stroke(Theme.Palette.glassStroke, lineWidth: 1))

                    Image(systemName: SymbolCompat.name("plus", "plus.circle"))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Theme.Palette.ink)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("加入会议")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink)

                    Text("输入会议号加入")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.ink3)
                }

                Spacer(minLength: 8)

                Image(systemName: SymbolCompat.name("chevron.right", "chevron.right"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink3)
            }
            .padding(.horizontal, 16)
            .frame(height: 76)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .liquidGlass(
                .regular,
                cornerStyle: .continuous(22),
                castsShadow: false
            )
        }
        .buttonStyle(BrandPressStyle())
        .accessibilityLabel("加入会议")
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
