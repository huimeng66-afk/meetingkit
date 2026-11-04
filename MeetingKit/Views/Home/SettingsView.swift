//
//  SettingsView.swift
//  MeetingKit
//
//  App 级「设置」页（挂在首页 tab 里的内容）。
//
//  这一页只做三件事：展示状态、改 AppSettings、把需要宿主动作的事情回调出去
//  （登录、编辑资料、Toast）。登录页、资料编辑弹层、Toast 容器都归首页管，
//  设置页再造一份就会出现"两处状态对不上"的问题，所以签名里全是回调而不是 @State。
//
//  视觉沿用首页语言：玻璃卡 + 发丝线 + ink / ink2 / ink3 三级文字。
//  背景与悬浮 Dock 由宿主提供，这里只负责内容与底部 110pt 的滚动让位——
//  自己再铺一层 BrandBackground 会把两套光斑叠在一起，颜色会发脏。
//

import Foundation
import SwiftUI
import UIKit

struct SettingsView: View {

    @ObservedObject var router: AppRouter
    @ObservedObject var settings: AppSettings

    /// 未登录时点"登录"。登录页由宿主弹出，设置页不持有它的呈现状态。
    var onRequestLogin: () -> Void

    /// 复用首页的资料编辑弹层，保证昵称 / 头像只有一套编辑入口。
    var onEditProfile: () -> Void

    /// 统一走宿主的 Toast，避免设置页再叠一层浮层。
    var onToast: (String, ToastStyle) -> Void = { _, _ in }

    /// 宿主的安全区顶部。设置页自带 ScrollView，在 GeometryReader 里不会自动避让刘海，
    /// 由调用方把值传进来，比在页面内部再套一层 GeometryReader 更省一层布局。
    var topInset: CGFloat = 0

    /// 宿主的安全区底部。内容末尾要多留这一截，否则"恢复默认设置"会压在 home indicator 上。
    var bottomInset: CGFloat = 0

    /// 打开首页侧边栏。与 onToast 一样由宿主提供，页面自己不持有抽屉状态。
    var onOpenSidebar: (() -> Void)? = nil

    /// 登录态只在页面出现时读一次。退出登录后立刻重读一次，本页不会停留在旧身份上；
    /// 其余页面由宿主在 tab 切换时自行读取，这里不去驱动路由。
    @State private var session: AuthSession? = AuthStore.load()

    @State private var pendingConfirm: ConfirmAction?
    @State private var presentedInfo: InfoKind?
    @State private var isChangingPassword = false

    /// 与首页一致：设计稿页面边距 20，比会议室内部的 16 更接近 iOS 阅读习惯。
    private let pagePadding: CGFloat = 20

    var body: some View {
        ZStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    accountCard
                        .padding(.bottom, 24)

                    if session != nil {
                        securitySection
                        deviceSection
                    }

                    meetingSection
                    shareSection
                    generalSection
                    aboutSection

                    resetButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, pagePadding)
                .padding(.top, topInset + 8)
                // 悬浮 Dock 实际占位 56 + 10，再留足呼吸位，
                // 保证"恢复默认设置"滚到底时不会被胶囊压住。
                .padding(.bottom, 150 + bottomInset)
            }

            if let action = pendingConfirm {
                GlassConfirmDialog(
                    title: action.title,
                    message: action.message,
                    confirmTitle: action.confirmTitle,
                    isDestructive: action.isDestructive,
                    onConfirm: { perform(action) },
                    onCancel: { setConfirm(nil) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let kind = presentedInfo {
                infoOverlay(kind)
                    .transition(.opacity)
            }

            if isChangingPassword {
                PasswordChangeSheet(
                    onClose: {
                        withAnimation(Theme.Motion.sheet) {
                            isChangingPassword = false
                        }
                    },
                    onSuccess: { newSession in
                        // 改密会作废旧令牌并换发新的，这里立刻把账号卡切到新会话，
                        // 否则页面还显示着旧身份，用户会以为没改成功。
                        session = newSession
                        withAnimation(Theme.Motion.sheet) {
                            isChangingPassword = false
                        }
                        onToast("密码已更新，其它设备需要重新登录", .success)
                    }
                )
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .onAppear {
            // 从登录页返回、或宿主重建本页时，账号可能已经变了。
            session = AuthStore.load()
        }
        // 登录浮层与"退出登录"都会改 AuthStore，但设置页的 onAppear
        // 在浮层关闭时不会重跑，必须监听通知才能立刻切换账号卡。
        .onReceive(NotificationCenter.default.publisher(for: AuthStore.didChangeNotification)) { _ in
            session = AuthStore.load()
        }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("设置")
                    .font(.system(size: 28, weight: .semibold))
                    .kerning(-0.3)
                    .foregroundColor(Theme.Palette.ink)

                Text("账号、会议与隐私")
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.Palette.ink2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            if let onOpenSidebar = onOpenSidebar {
                SidebarMenuButton(action: onOpenSidebar)
            }
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 账号卡

    private var accountCard: some View {
        VStack(spacing: 0) {
            if let session = session {
                signedInRow(session)
                divider(leading: 14)
                signOutRow
            } else {
                signedOutRow
            }
        }
        .liquidGlass(.regular, cornerStyle: .continuous(20), castsShadow: false)
    }

    private func signedInRow(_ session: AuthSession) -> some View {
        HStack(spacing: 12) {
            AvatarView(user: localUser, size: 48, showsSpeakingRing: false)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(router.profile.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink)
                        .lineLimit(1)

                    rolePill(session.role)
                }

                if !session.account.isEmpty {
                    Text(maskedAccount(session.account))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(Theme.Palette.ink3)
                        .lineLimit(1)
                        .accessibilityLabel("账号 \(maskedAccount(session.account))")
                }
            }

            Spacer(minLength: 8)

            Button {
                tapHaptic()
                onEditProfile()
            } label: {
                Text("编辑")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Palette.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .liquidGlass(
                        .regular,
                        cornerStyle: .capsule,
                        isInteractive: true,
                        castsShadow: false
                    )
                    // 胶囊只有 32 高，外圈补到 44 保证触控区域达标。
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("编辑个人资料")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var signOutRow: some View {
        Button {
            tapHaptic()
            setConfirm(.logout)
        } label: {
            HStack(spacing: 10) {
                Text("退出登录")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.Palette.danger)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("退出登录")
    }

    private var signedOutRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Theme.Palette.accent.opacity(0.12))

                Image(systemName: SymbolCompat.name("person.crop.circle", "person.circle"))
                    .font(.system(size: 21, weight: .regular))
                    .foregroundColor(Theme.Palette.accent)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("未登录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)

                Text("登录后可发起会议、使用企业会议室")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.ink3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                tapHaptic()
                onRequestLogin()
            } label: {
                Text("登录")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .liquidGlass(
                        .tinted(Theme.Palette.accent),
                        cornerStyle: .capsule,
                        isInteractive: true,
                        castsShadow: false
                    )
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("登录")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// 角色胶囊。成员用中性色，管理员才用强调色——人人都是彩色胶囊等于没有层级。
    private func rolePill(_ role: String) -> some View {
        let isAdmin = role == "ent_admin" || role == "super_admin"

        return Text(roleTitle(role))
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(isAdmin ? Theme.Palette.accent : Theme.Palette.ink2)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(
                Capsule()
                    .fill(isAdmin ? Theme.Palette.accent.opacity(0.16) : Color.white.opacity(0.06))
            )
            .accessibilityLabel("角色：\(roleTitle(role))")
    }

    private func roleTitle(_ role: String) -> String {
        switch role {
        case "ent_admin":
            return "企业管理员"
        case "super_admin":
            return "超级管理员"
        default:
            return "成员"
        }
    }

    /// 脱敏：保留前 3 后 2，中间逐字符打 `*`。
    ///
    /// 长度 ≤ 5 时前后两段会重叠，此时整串打码——"保留前 3 后 2"在这类短账号上
    /// 等于把原文完整拼回来，脱敏就失去了意义。
    private func maskedAccount(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        let characters = Array(text)
        guard characters.count > 5 else {
            return String(repeating: "*", count: characters.count)
        }

        let head = String(characters.prefix(3))
        let tail = String(characters.suffix(2))
        return head + String(repeating: "*", count: characters.count - 5) + tail
    }

    // MARK: - 账号与安全

    private var securitySection: some View {
        section("账号与安全") {
            actionRow(
                symbol: SymbolCompat.name("key.fill", "lock.fill"),
                title: "修改密码",
                subtitle: "定期更换可以降低账号被盗风险"
            ) {
                withAnimation(Theme.Motion.sheet) {
                    isChangingPassword = true
                }
            }

            divider(leading: 56)

            if let session = session {
                valueRow(title: "登录账号", value: maskedAccount(session.account))
            }
        }
    }

    // MARK: - 设备与登录

    /// 单设备登录的可见证据。
    ///
    /// 只写一句"一个账号限一台设备"用户是感受不到的：
    /// 他需要看到这台设备叫什么、什么时候登的、编号是多少。
    /// 换设备被踢之后，回到这里就能确认是不是自己。
    private var deviceSection: some View {
        section("设备与登录") {
            currentDeviceRow

            divider(leading: 56)

            valueRow(title: "系统版本", value: DeviceIdentity.systemVersion)

            divider(leading: 56)

            valueRow(title: "登录时间", value: loginTimeText)

            divider(leading: 56)

            valueRow(title: "设备编号", value: deviceNumberText)

            divider(leading: 56)

            singleDeviceNote
        }
    }

    private var currentDeviceRow: some View {
        HStack(spacing: 10) {
            iconBlock(SymbolCompat.name("iphone", "iphone.gen3"))

            VStack(alignment: .leading, spacing: 2) {
                Text("当前设备")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.Palette.ink)

                Text(DeviceIdentity.name)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.ink3)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text("唯一在线")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Theme.Palette.accent)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Theme.Palette.accent.opacity(0.12)))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前设备 \(DeviceIdentity.name)，唯一在线")
    }

    private var singleDeviceNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: SymbolCompat.name("checkmark.shield", "lock.shield"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.Palette.accent)
                .padding(.top, 1)

            Text("一个账号同时只允许一台设备在线。在其它设备登录后，本机会立即退出，需要重新登录。")
                .font(.system(size: 11.5))
                .foregroundColor(Theme.Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 登录时间来自服务端 ISO 时间戳。解析失败就原样显示，
    /// 不为了一个格式化吞掉服务端已经给出的信息。
    private var loginTimeText: String {
        guard let raw = session?.deviceLoginAt, !raw.isEmpty else { return "本次登录" }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var date = withFraction.date(from: raw)
        if date == nil {
            date = ISO8601DateFormatter().date(from: raw)
        }
        guard let parsed = date else { return raw }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM月dd日 HH:mm"
        return formatter.string(from: parsed)
    }

    private var deviceNumberText: String {
        let raw = session?.deviceId ?? ""
        let identifier = raw.isEmpty ? DeviceIdentity.shortId : String(raw.suffix(8)).uppercased()
        return identifier
    }

    // MARK: - 会议

    private var meetingSection: some View {
        section("会议") {
            toggleRow(
                symbol: SymbolCompat.name("mic", "mic.fill"),
                title: "默认麦克风",
                subtitle: "进入会议时自动打开麦克风",
                isOn: boolBinding(\.defaultMicOn)
            )

            divider(leading: 56)

            toggleRow(
                symbol: SymbolCompat.name("video", "video.fill"),
                title: "默认摄像头",
                subtitle: "进入会议时自动打开摄像头",
                isOn: boolBinding(\.defaultCameraOn)
            )

            divider(leading: 56)

            toggleRow(
                symbol: SymbolCompat.name("mic.slash", "mic.slash.fill"),
                title: "入会自动静音",
                subtitle: "进会后保持静音，适合主持人与企业会议",
                isOn: boolBinding(\.autoMuteOnJoin)
            )
        }
    }

    // MARK: - 屏幕共享

    private var shareSection: some View {
        section("屏幕共享") {
            qualityBlock

            divider(leading: 56)

            toggleRow(
                symbol: SymbolCompat.name("eye.slash", "eye.slash.fill"),
                title: "共享时自动收起控件",
                subtitle: "4 秒无操作收起，点击画面可恢复",
                isOn: boolBinding(\.autoHideControlsDuringShare)
            )
        }
    }

    private var qualityBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                iconBlock(SymbolCompat.name("rectangle.on.rectangle", "rectangle.on.rectangle.angled"))

                VStack(alignment: .leading, spacing: 2) {
                    Text("共享画质")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.Palette.ink)

                    Text("决定共享画面偏向流畅还是细节")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.ink3)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .frame(minHeight: 56)

            Picker("共享画质", selection: qualityBinding) {
                ForEach(ShareQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("共享画质")

            Text(settings.shareQuality.hint)
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .animationCompat(Theme.Motion.standard, value: settings.shareQuality)
    }

    // MARK: - 通用

    private var generalSection: some View {
        section("通用") {
            toggleRow(
                symbol: SymbolCompat.name("hand.tap", "hand.point.up.left"),
                title: "触觉反馈",
                subtitle: "开关与选择时提供轻微震动",
                isOn: boolBinding(\.hapticsEnabled)
            )

            divider(leading: 56)

            actionRow(
                symbol: SymbolCompat.name("accessibility", "person.crop.circle"),
                title: "减少动效",
                subtitle: "跟随系统的辅助功能设置",
                trailingText: "跟随系统"
            ) {
                openSystemSettings()
            }

            divider(leading: 56)

            destructiveRow(
                symbol: SymbolCompat.name("trash", "trash.fill"),
                title: "清除历史会议",
                value: historyValue,
                enabled: !router.history.isEmpty
            ) {
                setConfirm(.clearHistory(count: router.history.count))
            }
        }
    }

    private var historyValue: String {
        router.history.isEmpty ? "暂无记录" : "\(router.history.count) 条"
    }

    // MARK: - 关于

    private var aboutSection: some View {
        section("关于") {
            valueRow(title: "版本", value: appVersion)

            divider(leading: 56)

            actionRow(
                symbol: SymbolCompat.name("lock.shield", "lock.fill"),
                title: "隐私说明",
                subtitle: "会议内容的传输与归档方式"
            ) {
                setInfo(.privacy)
            }

            divider(leading: 56)

            actionRow(
                symbol: SymbolCompat.name("shippingbox", "cube.box"),
                title: "开源组件",
                subtitle: "Socket.IO 客户端与 WebRTC"
            ) {
                setInfo(.licenses)
            }
        }
    }

    /// 版本号。两个键都是手写 Info.plist 里的字段，理论上不会缺；
    /// 一旦缺了宁可显示 PROJECT 里约定的 1.0.0，也不要在设置页出现 "(null)"。
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (info?["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let version: String
        if let short = short, !short.isEmpty {
            version = short
        } else {
            version = "1.0.0"
        }

        guard let build = build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    // MARK: - 恢复默认

    private var resetButton: some View {
        Button {
            tapHaptic()
            setConfirm(.resetSettings)
        } label: {
            Text("恢复默认设置")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Palette.ink3)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.top, 2)
        .accessibilityLabel("恢复默认设置")
    }

    // MARK: - 分组骨架

    /// 分组标题 + 一张玻璃卡。标题左移 +4 与卡片内的 14pt 内边距形成视觉对齐，
    /// 这是系统设置页惯用的缩进关系，比标题与卡片完全齐边更像"分组"。
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .kerning(0.2)
                .foregroundColor(Theme.Palette.ink3)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            // 分组不再用玻璃。
            //
            // 设置页有 6 个分组，如果每块都是玻璃，一屏里会出现六层模糊叠加，
            // 滚动时每块都在折射下方的光斑，文字对比度跟着起伏——
            // 这也是"所有组件长得一样"的来源。这里退成实色分组底，
            // 把玻璃只留给顶部那张账号卡（页面唯一需要强调的层级）。
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
        }
        .padding(.bottom, 24)
    }

    /// 发丝线。默认从图标右侧（54 = 14 内边距 + 30 图标 + 10 间距）起画，
    /// 让每一行的文字左缘连成一条看不见的线；账号卡没有图标，单独传 14。
    private func divider(leading: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 1)
            .padding(.leading, leading)
    }

    private func iconBlock(_ symbol: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))

            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.Palette.ink2)
        }
        .frame(width: 30, height: 30)
    }

    // MARK: - 行

    private func toggleRow(
        symbol: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            iconBlock(symbol)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.Palette.ink)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.ink3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Theme.Palette.accent))
                .accessibilityLabel(title)
                .accessibilityValue(isOn.wrappedValue ? "已开启" : "已关闭")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }

    private func actionRow(
        symbol: String,
        title: String,
        subtitle: String,
        trailingText: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            tapHaptic()
            action()
        } label: {
            HStack(spacing: 10) {
                iconBlock(symbol)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.Palette.ink)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.ink3)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let trailingText = trailingText {
                    Text(trailingText)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.ink3)
                        .lineLimit(1)
                }

                Image(systemName: SymbolCompat.name("chevron.right"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink3)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(trailingText ?? subtitle)
    }

    /// 危险行只把文字与图标染红，不铺红底：整行红底会让"清除历史"看起来
    /// 像一个已经被触发的错误状态，而它只是一个可点的操作。
    private func destructiveRow(
        symbol: String,
        title: String,
        value: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            tapHaptic()
            action()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.Palette.danger.opacity(0.12))

                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.Palette.danger)
                }
                .frame(width: 30, height: 30)

                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.Palette.danger)

                Spacer(minLength: 8)

                Text(value)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.ink3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.4)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func valueRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(Theme.Palette.ink)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.Palette.ink3)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 说明浮层

    private func infoOverlay(_ kind: InfoKind) -> some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    setInfo(nil)
                }

            VStack(alignment: .leading, spacing: 0) {
                Text(kind.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                infoBody(kind)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)

                Rectangle()
                    .fill(Theme.Palette.hairline)
                    .frame(height: 1)

                Button {
                    tapHaptic()
                    setInfo(nil)
                } label: {
                    Text("知道了")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.Palette.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("关闭\(kind.title)")
            }
            .frame(maxWidth: 340)
            .liquidGlass(.regular, cornerStyle: .continuous(22), castsShadow: true)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            // 卡片吞掉点击，避免点在正文空白处时落到遮罩上被当成"关闭"。
            .onTapGesture {
                // 有意留空：只拦截事件。
            }
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func infoBody(_ kind: InfoKind) -> some View {
        switch kind {
        case .privacy:
            VStack(alignment: .leading, spacing: 10) {
                infoLine("会议内容仅在参会者之间传输，不经过第三方服务。")
                infoLine("企业会议默认端到端加密，会议内容不做归档。")
            }

        case .licenses:
            VStack(spacing: 0) {
                licenseRow(name: "socket.io-client-swift", license: "MIT 许可证")

                Rectangle()
                    .fill(Theme.Palette.hairline)
                    .frame(height: 1)
                    .padding(.leading, 12)

                licenseRow(name: "WebRTC（stasel 分发）", license: "BSD-3-Clause 许可证")
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
    }

    private func infoLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Theme.Palette.accent)
                .frame(width: 4, height: 4)
                .padding(.top, 6)

            Text(text)
                .font(.system(size: 12.5))
                .foregroundColor(Theme.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func licenseRow(name: String, license: String) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(Theme.Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 8)

            Text(license)
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.ink3)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 动作

    private func perform(_ action: ConfirmAction) {
        switch action {
        case .logout:
            AuthStore.clear()
            // 本页立刻回到未登录态；其他页面由宿主在 tab 切换时重新调用 AuthStore.load()。
            // 不改 AppRouter：登出不是一次路由跳转，也不该由设置页越权清空别人的状态。
            session = AuthStore.load()
            onToast("已退出登录", .success)

        case .clearHistory:
            router.clearHistory()
            onToast("历史会议已清除", .success)

        case .resetSettings:
            settings.resetToDefaults()
            onToast("已恢复默认设置", .success)
        }

        setConfirm(nil)
    }

    private func openSystemSettings() {
        // 减少动效是系统级无障碍开关，App 无法写入。这里只做跳转，不自建开关——
        // 自建开关会和系统设置打架，用户在系统里改完回来看不到变化。
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func setConfirm(_ action: ConfirmAction?) {
        withAnimation(Theme.Motion.standard) {
            pendingConfirm = action
        }
    }

    private func setInfo(_ kind: InfoKind?) {
        withAnimation(Theme.Motion.standard) {
            presentedInfo = kind
        }
    }

    // MARK: - 绑定

    /// Toggle 的统一写入口：先确认值真的变了再写（SwiftUI 有时会回写同值），
    /// 然后按"触觉反馈"开关决定要不要震一下。
    private func boolBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                guard settings[keyPath: keyPath] != newValue else { return }
                settings[keyPath: keyPath] = newValue
                // 关闭"触觉反馈"的那一下不再震动；重新打开时会震一下作为确认。
                if settings.hapticsEnabled {
                    Haptics.selection()
                }
            }
        )
    }

    private var qualityBinding: Binding<ShareQuality> {
        Binding(
            get: { settings.shareQuality },
            set: { newValue in
                guard newValue != settings.shareQuality else { return }
                settings.shareQuality = newValue
                if settings.hapticsEnabled {
                    Haptics.selection()
                }
            }
        )
    }

    // MARK: - 派生

    /// 触觉统一走这里，保证关掉"触觉反馈"后设置页自己也不再震。
    /// 弹窗内部的自带反馈不在此列（GlassConfirmDialog 是共用组件，不在这里改）。
    private func tapHaptic() {
        guard settings.hapticsEnabled else { return }
        Haptics.impact(.light)
    }

    private var localUser: MeetingUser {
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

// MARK: - 确认动作

/// 本页三处二次确认共用一张 GlassConfirmDialog，把文案收进枚举，
/// 避免在视图里散落三份 if / 三份重复的弹窗代码。
private enum ConfirmAction: Equatable {

    case logout
    case clearHistory(count: Int)
    case resetSettings

    var title: String {
        switch self {
        case .logout:
            return "退出登录？"
        case .clearHistory:
            return "清除历史会议？"
        case .resetSettings:
            return "恢复默认设置？"
        }
    }

    var message: String {
        switch self {
        case .logout:
            return "退出后需要重新登录才能发起会议和使用企业会议室。"
        case .clearHistory(let count):
            return "将删除本机保存的 \(count) 条参会记录，此操作不可恢复。"
        case .resetSettings:
            return "会议、共享与通用设置会回到初始值，账号资料与历史记录不受影响。"
        }
    }

    var confirmTitle: String {
        switch self {
        case .logout:
            return "退出登录"
        case .clearHistory:
            return "清除"
        case .resetSettings:
            return "恢复默认"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .logout, .clearHistory:
            return true
        case .resetSettings:
            return false
        }
    }
}

// MARK: - 说明类型

private enum InfoKind {
    case privacy
    case licenses

    var title: String {
        switch self {
        case .privacy:
            return "隐私说明"
        case .licenses:
            return "开源组件"
        }
    }
}
