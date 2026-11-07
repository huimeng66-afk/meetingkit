//
//  ParticipantsPanel.swift
//  MeetingKit
//
//  成员面板：搜索 + 主持人/参会人分组 + 底部三个管理动作。
//
//  列表没有用 `List` + `Section`：自绘抽屉里做深色分组列表，
//  系统 List 的背景与分隔线在 iOS 14 上要全局改 UITableView 外观才干净。
//  这里用 LazyVStack + 自绘分组头，视觉与设计稿一致，也不会和玻璃底打架。
//

import SwiftUI

struct ParticipantsPanel: View {

    @ObservedObject var viewModel: MeetingViewModel

    @State private var query: String = ""

    /// 底部"移出参会人"的选择模式：进入后每行尾部出现选择圈，
    /// 选好人再点一次确认才真正移出。没有选中任何人时确认键禁用，
    /// 不会出现"点了只弹一句请先选择"的死胡同。
    @State private var isSelectingRemoval = false
    @State private var selectedForRemoval: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header

            SearchField(text: $query)
                .padding(.horizontal, Theme.Metrics.horizontal)
                .padding(.bottom, Theme.Metrics.space2)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !hostUsers.isEmpty {
                        groupHeader("主持人")
                        ForEach(hostUsers) { user in
                            row(user)
                        }
                    }

                    if !guestUsers.isEmpty {
                        groupHeader("参会人")
                        ForEach(guestUsers) { user in
                            row(user)
                        }
                    }

                    if hostUsers.isEmpty && guestUsers.isEmpty {
                        emptySearchState
                    }
                }
                .padding(.bottom, Theme.Metrics.space2)
            }

            footer
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Metrics.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("成员")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundColor(Theme.Palette.textPrimary)

                Text("\(viewModel.participantCount) 人 · 会议号 \(viewModel.formattedMeetingNumber)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                Haptics.impact(.light)
                viewModel.openPanel(.invite)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: SymbolCompat.name(
                        "person.badge.plus",
                        "person.crop.circle.badge.plus",
                        "person.fill"
                    ))
                        .font(.system(size: 12, weight: .semibold))

                    Text("邀请")
                        .font(Theme.Typography.control)
                }
                .foregroundColor(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Metrics.space3)
                .frame(height: 30)
                .liquidGlass(.clear, cornerStyle: .capsule, isInteractive: true)
            }
            .buttonStyle(LiquidPressStyle(pressedScale: 0.985, highlight: 0))
            .accessibilityLabel("邀请参会人")
        }
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space1)
        .padding(.bottom, Theme.Metrics.space3)
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.Palette.textTertiary)
            .padding(.horizontal, Theme.Metrics.horizontal)
            .padding(.top, Theme.Metrics.space3)
            .padding(.bottom, 2)
    }

    // MARK: - 行

    @ViewBuilder
    private func row(_ user: MeetingUser) -> some View {
        if isSelectingRemoval, !user.isLocal {
            // 选择模式下整行 = 勾选项：行尾出现选择圈，点一下切换选中。
            // 此时不挂 contextMenu，避免长按菜单与选择手势互相抢事件。
            Button {
                Haptics.selection()
                toggleSelection(user.id)
            } label: {
                HStack(spacing: Theme.Metrics.space2) {
                    ParticipantRow(
                        user: user,
                        showsNetworkWarning: showsNetworkWarning(for: user)
                    )

                    selectionMark(isSelected: selectedForRemoval.contains(user.id))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle(pressedScale: 0.985, highlight: 0))
            .padding(.horizontal, Theme.Metrics.horizontal)
            .accessibilityLabel(
                selectedForRemoval.contains(user.id)
                    ? "取消选择 \(user.name)"
                    : "选择 \(user.name)"
            )
        } else {
            ParticipantRow(
                user: user,
                showsNetworkWarning: showsNetworkWarning(for: user)
            )
            .padding(.horizontal, Theme.Metrics.horizontal)
            .contentShape(Rectangle())
            .contextMenu {
                contextMenuItems(for: user)
            }
        }
    }

    /// 选择模式的圆形勾选框。未选中用空心圆，选中用实心对勾，
    /// 状态不只靠颜色区分。
    private func selectionMark(isSelected: Bool) -> some View {
        Image(systemName: SymbolCompat.name(
            isSelected ? "checkmark.circle.fill" : "circle",
            "circle"
        ))
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(
                isSelected ? Theme.Palette.accent : Theme.Palette.textTertiary
            )
            .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private func contextMenuItems(for user: MeetingUser) -> some View {
        // 只有主持人（本机）能看到管理类操作；非主持人时菜单内容为空，长按不会弹。
        if viewModel.isCurrentUserHost, !user.isLocal {
            Button {
                Haptics.impact(.light)
                viewModel.pinnedSpeakerID = user.id
                viewModel.layoutMode = .speaker
            } label: {
                Label("设为主讲人", systemImage: SymbolCompat.name("pin.fill", "pin"))
            }

            Button {
                Haptics.impact(.light)
                // contextMenu 的点击本身会关闭菜单；但列表在菜单收起的同一帧里重建，
                // iOS 14 上偶发菜单残留在屏幕上。把数据变更推到下一轮主线程任务，
                // 让系统先完成关闭动画，再刷新列表。
                Task { @MainActor in
                    viewModel.setMic(false, for: user.id)
                    viewModel.showToast(
                        ToastMessage(
                            text: "已静音 \(user.name)",
                            systemImage: SymbolCompat.name("mic.slash.fill", "mic.slash"),
                            style: .info
                        )
                    )
                }
            } label: {
                Label("静音", systemImage: SymbolCompat.name("mic.slash.fill", "mic.slash"))
            }

            // `Button(role: .destructive)` 是 iOS 15 起的，14 上不可用。
            // 危险语义改由文字颜色表达：contextMenu 里同样是红字，观感一致。
            Button {
                Haptics.impact(.light)
                Task { @MainActor in
                    viewModel.removeParticipant(user.id)
                    viewModel.showToast(
                        ToastMessage(
                            text: "已将 \(user.name) 移出会议",
                            systemImage: SymbolCompat.name(
                                "person.badge.minus",
                                "person.crop.circle.badge.minus",
                                "person.fill"
                            ),
                            style: .danger
                        )
                    )
                }
            } label: {
                Label(
                    "移出会议",
                    systemImage: SymbolCompat.name(
                        "person.badge.minus",
                        "person.crop.circle.badge.minus",
                        "person.fill"
                    )
                )
                .foregroundColor(Theme.Palette.danger)
            }
        }
    }

    // MARK: - 底部工具条

    /// 管理动作只属于主持人。非主持人整条不渲染：让"全部静音/锁定/移出"
    /// 这些高权限按钮露出却点不动，比没有更糟。
    @ViewBuilder
    private var footer: some View {
        if viewModel.isCurrentUserHost {
            if isSelectingRemoval {
                removalBar
            } else {
                managementBar
            }
        }
    }

    private var managementBar: some View {
        HStack(spacing: Theme.Metrics.space2) {
            footerButton(
                icon: SymbolCompat.name("mic.slash.fill", "mic.slash"),
                title: "全部静音"
            ) {
                viewModel.muteAll()
            }

            footerButton(
                icon: SymbolCompat.name(viewModel.isLocked ? "lock.fill" : "lock.open.fill", "lock"),
                title: viewModel.isLocked ? "取消锁定" : "锁定会议"
            ) {
                toggleLock()
            }

            footerButton(
                icon: SymbolCompat.name("person.badge.minus", "person.crop.circle.badge.minus"),
                title: "移出参会人"
            ) {
                beginRemovalSelection()
            }
        }
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space2)
        .padding(.bottom, Theme.Metrics.space2)
    }

    /// 选择模式下的确认条：左边取消，右边"移出 (n)"。
    /// 没选人时确认键禁用，不会出现"点了只弹一句请先选择"的死胡同。
    private var removalBar: some View {
        HStack(spacing: Theme.Metrics.space2) {
            footerButton(
                icon: SymbolCompat.name("xmark", "xmark.circle"),
                title: "取消"
            ) {
                endRemovalSelection()
            }

            footerButton(
                icon: SymbolCompat.name("person.badge.minus", "person.crop.circle.badge.minus"),
                title: selectedForRemoval.isEmpty
                    ? "移出参会人"
                    : "移出 (\(selectedForRemoval.count))",
                isEnabled: !selectedForRemoval.isEmpty
            ) {
                confirmRemoval()
            }
        }
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space2)
        .padding(.bottom, Theme.Metrics.space2)
    }

    private func footerButton(
        icon: String,
        title: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(Theme.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(Capsule().fill(Theme.Palette.surfaceSubtle))
            .overlay(Capsule().stroke(Theme.Palette.glassStroke, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1.0 : 0.4)
        }
        .buttonStyle(ControlButtonPressStyle())
        .disabled(!isEnabled)
    }

    // MARK: - 空态

    private var emptySearchState: some View {
        VStack(spacing: Theme.Metrics.space2) {
            Image(systemName: SymbolCompat.name("magnifyingglass"))
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Theme.Palette.textTertiary)
            Text("没有匹配的参会人")
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    // MARK: - 数据

    private var filteredUsers: [MeetingUser] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return viewModel.participants }
        return viewModel.participants.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// 主持人 + 联席主持人归一组：都具备管理权限，分成两组会让列表显得碎。
    private var hostUsers: [MeetingUser] {
        filteredUsers.filter { $0.role != .participant }
    }

    private var guestUsers: [MeetingUser] {
        filteredUsers.filter { $0.role == .participant }
    }

    /// 弱网标记只对本机有真实数据（网络质量由 RTC 统计上报）。
    /// 远端需要逐连接 stats 才有真值，固定给某个头像色打标会误导用户。
    private func showsNetworkWarning(for user: MeetingUser) -> Bool {
        guard user.isLocal else { return false }
        if case .poor = viewModel.networkQuality {
            return true
        }
        return false
    }

    // MARK: - 动作

    private func beginRemovalSelection() {
        selectedForRemoval.removeAll()
        withAnimation(Theme.Motion.standard) {
            isSelectingRemoval = true
        }
    }

    private func endRemovalSelection() {
        selectedForRemoval.removeAll()
        withAnimation(Theme.Motion.standard) {
            isSelectingRemoval = false
        }
    }

    private func toggleSelection(_ userID: String) {
        if selectedForRemoval.contains(userID) {
            selectedForRemoval.remove(userID)
        } else {
            selectedForRemoval.insert(userID)
        }
    }

    private func confirmRemoval() {
        let targets = selectedForRemoval
        guard !targets.isEmpty else { return }

        for userID in targets {
            viewModel.removeParticipant(userID)
        }
        endRemovalSelection()

        viewModel.showToast(
            ToastMessage(
                text: "已移出 \(targets.count) 位参会人",
                systemImage: SymbolCompat.name(
                    "person.badge.minus",
                    "person.crop.circle.badge.minus",
                    "person.fill"
                ),
                style: .danger
            )
        )
    }

    private func toggleLock() {
        // 双保险：footer 已经按主持人身份整条隐藏，这里再挡一次，
        // 防止以后有人把入口挪到别处时把门禁丢掉。
        guard viewModel.isCurrentUserHost else { return }

        // 真实链路：转发给 RTC（服务端校验并广播 room:locked，UI 以回执为准）。
        let locked = !viewModel.isLocked
        viewModel.setLocked(locked)
        viewModel.showToast(
            ToastMessage(
                text: locked ? "会议已锁定，新参会人无法加入" : "已取消锁定，新参会人可以加入",
                systemImage: locked ? "lock.fill" : "lock.open.fill",
                style: locked ? .success : .info
            )
        )
    }
}

// MARK: - 参会人行

struct ParticipantRow: View {

    let user: MeetingUser
    var showsNetworkWarning: Bool = false

    var body: some View {
        HStack(spacing: Theme.Metrics.space3) {
            AvatarView(user: user, size: 40, showsSpeakingRing: true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundColor(Theme.Palette.textPrimary)
                        .lineLimit(1)

                    if let badge = user.role.badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(
                                Capsule().fill(
                                    user.role == .host
                                        ? Theme.Palette.accent
                                        : Theme.Palette.coHost
                                )
                            )
                    }
                }

                Text(user.isMicOn ? "麦克风已开启" : "已静音")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.textTertiary)
            }

            Spacer(minLength: Theme.Metrics.space2)

            HStack(spacing: Theme.Metrics.space2) {
                if showsNetworkWarning {
                    Image(systemName: SymbolCompat.name(
                        "wifi.exclamationmark",
                        "wifi.slash",
                        "exclamationmark.triangle.fill"
                    ))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Palette.warning)
                }

                if user.isHandRaised {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Palette.accent)
                }

                if !user.isMicOn {
                    Image(systemName: SymbolCompat.name("mic.slash.fill", "mic.slash"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Palette.danger)
                }
            }
        }
        .frame(height: Theme.Metrics.rowHeight)
    }

    private var displayName: String {
        user.isLocal ? "\(user.name)（我）" : user.name
    }
}

struct ParticipantsPanel_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.background
            ParticipantsPanel(viewModel: MeetingViewModel())
        }
        .preferredColorScheme(.dark)
    }
}
