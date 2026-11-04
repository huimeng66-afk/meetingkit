//
//  HomeSidebar.swift
//  MeetingKit
//
//  首页侧边栏。定位是"完整导航 + 身份出口"，不是第二个首页。
//
//  ── 为什么在已经有 Dock 的情况下还要侧边栏 ────────────────────────────
//  Dock 只能放四个高频入口，而"发起会议 / 帮助 / 退出登录 / 账号资料"这些
//  低频但必要的动作必须有个去处。网页端用的是左侧抽屉，App 端保留同一套
//  信息架构，用户在两端之间切换不需要重新学一遍。
//
//  ── 为什么不用汉堡图标 ────────────────────────────────────────────────
//  HIG 明确不推荐汉堡菜单：它把导航藏起来，且无法表达"当前在哪"。
//  这里由左上角的品牌标打开（点 Logo 看菜单是系统里的常见心智），
//  侧边栏每次打开都会高亮当前 tab，补上"我在哪"这一信息。
//
//  ── 视觉 ──────────────────────────────────────────────────────────────
//  侧边栏压住首页内容，必须是一层"实体"：超薄深色材质 + 压暗底，
//  保证任何光斑滚到下面时，白字仍然可读。右侧只留一条 1px 高光边，
//  不加圆角——圆角会让它看起来像一张浮在页面上的卡，而不是抽屉。
//

import SwiftUI

struct HomeSidebar: View {

    @ObservedObject var router: AppRouter

    /// 当前选中的一级目的地，用来画左侧的强调条。
    var currentTab: HomeTab

    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    var onSelectTab: (HomeTab) -> Void
    var onStartMeeting: () -> Void
    var onLogin: () -> Void
    var onEditProfile: () -> Void
    var onClose: () -> Void
    var onToast: (String, ToastStyle) -> Void

    /// 登录态在这里只读一次：侧边栏每次打开都会重建，重建即刷新。
    @State private var session: AuthSession? = AuthStore.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    startButton
                        .padding(.horizontal, 14)
                        .padding(.top, 6)

                    sectionTitle("工作台")
                        .padding(.top, 22)

                    navRow(.meetings)
                    navRow(.contacts)
                    navRow(.enterprise)

                    sectionTitle("系统")
                        .padding(.top, 20)

                    navRow(.settings)

                    plainRow(
                        symbol: SymbolCompat.name("questionmark.circle", "questionmark.circle.fill"),
                        title: "帮助与反馈"
                    ) {
                        Haptics.impact(.light)
                        onToast("遇到问题可在网页端「帮助」里提交", .info)
                    }

                    plainRow(
                        symbol: SymbolCompat.name("shield.lefthalf.filled", "lock.shield"),
                        title: "隐私与安全"
                    ) {
                        Haptics.impact(.light)
                        onToast("会议内容仅在参会者之间传输", .info)
                    }
                }
                .padding(.bottom, 18)
            }

            Spacer(minLength: 0)

            accountCard
                .padding(.horizontal, 14)
                .padding(.bottom, max(bottomInset, 12) + 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background)
        .onAppear {
            session = AuthStore.load()
        }
    }

    // MARK: - 背景

    private var background: some View {
        ZStack(alignment: .trailing) {
            VisualEffectBlur(effectStyle: .systemUltraThinMaterialDark)

            // 压暗层：超薄材质在首页的蓝色光斑上仍然偏亮，
            // 不压这一层，白字在"企业空间"这种长标签上会掉对比度。
            Theme.Palette.background.opacity(0.72)

            // 右侧 1px 高光。没有它，抽屉和背后的深色页面会糊在一起。
            LinearGradient(
                colors: [
                    Color.white.opacity(0.18),
                    Color.white.opacity(0.04),
                    Color.white.opacity(0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 1)
        }
        .ignoresSafeArea()
    }

    // MARK: - 顶部

    private var header: some View {
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

            Spacer(minLength: 8)

            Button {
                Haptics.impact(.light)
                onClose()
            } label: {
                Image(systemName: SymbolCompat.name("xmark"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink2)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.06)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("关闭侧边栏")
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset + 10)
        .padding(.bottom, 8)
    }

    // MARK: - 发起会议

    private var startButton: some View {
        Button {
            Haptics.impact(.medium)
            onStartMeeting()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: SymbolCompat.name("video.badge.plus", "video.fill"))
                    .font(.system(size: 15, weight: .semibold))

                Text("发起会议")
                    .font(.system(size: 15, weight: .semibold))

                Spacer(minLength: 0)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .liquidGlass(
                .tinted(Theme.Palette.accent),
                cornerStyle: .continuous(14),
                isInteractive: true,
                castsShadow: false
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("发起会议")
    }

    // MARK: - 分组

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.Palette.ink3)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    /// 一级目的地行。当前 tab 用"左侧 3pt 强调条 + 轻底"表达，不用整行填色：
    /// 整行填色会和 Dock 的选中态抢注意力，也不像系统设置的分组列表。
    private func navRow(_ tab: HomeTab) -> some View {
        let isSelected = currentTab == tab

        return Button {
            Haptics.selection()
            onSelectTab(tab)
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isSelected ? Theme.Palette.accent : Color.clear)
                        .frame(width: 3, height: 18)
                        .offset(x: -10)

                    Image(systemName: isSelected ? tab.selectedSymbol : tab.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isSelected ? Theme.Palette.accent : Theme.Palette.ink2)
                        .frame(width: 24)
                }

                Text(tab.title)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Theme.Palette.ink : Theme.Palette.ink2)

                Spacer(minLength: 8)

                if isSelected {
                    Text("当前")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.Palette.accent)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(Theme.Palette.accent.opacity(0.14)))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.055) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowPressStyle())
        .padding(.horizontal, 8)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func plainRow(
        symbol: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.Palette.ink2)
                    .frame(width: 24)

                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.Palette.ink2)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowPressStyle())
        .padding(.horizontal, 8)
    }

    // MARK: - 账号卡

    @ViewBuilder
    private var accountCard: some View {
        if let session = session {
            Button {
                Haptics.impact(.light)
                onEditProfile()
            } label: {
                HStack(spacing: 10) {
                    AvatarView(user: profileUser, size: 34, showsSpeakingRing: false)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(router.profile.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.Palette.ink)
                            .lineLimit(1)

                        Text(roleText(session))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Palette.ink3)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: SymbolCompat.name("chevron.right", "chevron.forward"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink3)
                }
                .padding(.horizontal, 12)
                .frame(height: 58)
                .liquidGlass(.clear, cornerStyle: .continuous(16), isInteractive: true, castsShadow: false)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("账号与个人资料")
        } else {
            Button {
                Haptics.impact(.light)
                onLogin()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 34, height: 34)

                        Image(systemName: SymbolCompat.name("person.fill", "person"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.Palette.ink2)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录账号")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.Palette.ink)

                        Text("同步会议记录与企业空间")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Palette.ink3)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: SymbolCompat.name("chevron.right", "chevron.forward"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink3)
                }
                .padding(.horizontal, 12)
                .frame(height: 58)
                .liquidGlass(.clear, cornerStyle: .continuous(16), isInteractive: true, castsShadow: false)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("登录账号")
        }
    }

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

    private func roleText(_ session: AuthSession) -> String {
        if !session.account.isEmpty {
            return session.account
        }
        switch session.role {
        case "ent_admin":
            return "企业管理员"
        case "super_admin":
            return "超级管理员"
        default:
            return "成员"
        }
    }
}

// MARK: - 行按压反馈

/// 抽屉里的行没有玻璃底，按压反馈只能靠底色。
/// 0.045 → 0.075 的变化足够"按得动"，又不至于让整行闪一下。
private struct SidebarRowPressStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.075 : 0))
            )
            .animationCompat(Theme.Motion.standard, value: configuration.isPressed)
    }
}
