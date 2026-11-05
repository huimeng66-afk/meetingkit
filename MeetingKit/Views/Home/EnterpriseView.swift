//
//  EnterpriseView.swift
//  MeetingKit
//
//  企业空间：企业身份与成员用量、专属会议室（企业版固定入口）、企业会议列表、安全说明。
//
//  关键取舍：
//  1. 数据只认服务端。未加入企业时不做"输入企业码申请加入"之类的前端入口——
//     服务端没有对应的写接口，做出来只会把用户带进一条走不通的路。
//  2. 专属会议室是这一页唯一的主操作，视觉权重最高；身份、列表、安全说明依次
//     减弱，用户从任何位置都能一眼回到"进入会议室"。
//  3. 首帧用骨架而不是全屏菊花：概览、会议室、会议列表是三次请求，
//     全屏菊花会让页面在很短时间内反复闪白；骨架至少保留了布局的预期。
//  4. 所有异步回调都用 loadToken 守卫。离开页面时 token 会被换掉，
//     迟到的回调直接丢弃，不再写已经销毁视图的 @State。
//

import Combine
import Foundation
import SwiftUI
import UIKit

struct EnterpriseView: View {

    // MARK: - 外部依赖

    @ObservedObject var router: AppRouter

    /// 进入会议室。上层负责决定是先进预检页还是直接进会。
    var onEnterRoom: (JoinInfo) -> Void

    /// 未登录时的登录入口。企业空间自己不承载登录表单。
    var onRequestLogin: () -> Void

    /// 轻提示交给上层统一渲染。本页只负责产生"发生了什么"，
    /// 不自己维护一套 toast 状态与计时器，避免和首页的浮层叠成两条。
    var onToast: (String, ToastStyle) -> Void

    /// 打开首页侧边栏。企业页是 Dock 的一级目的地，没有首页品牌头，
    /// 抽屉入口必须在这里也放一个，否则用户切到企业后只能靠边缘手势才能回去。
    var onOpenSidebar: (() -> Void)?

    // MARK: - 状态

    @State private var session: AuthSession? = AuthStore.load()
    @State private var pageState: EnterprisePageState = .idle
    @State private var overview: EnterpriseOverview?
    @State private var room: EnterpriseRoom?
    @State private var meetings: [EnterpriseMeetingSummary] = []
    @State private var meetingsLoaded = false

    /// 分段控件的选中值。服务端是唯一事实源，这里只是它的可编辑副本：
    /// 请求失败时回滚到 room.roomMode，成功时再以响应里的 meeting 为准。
    @State private var modeSelection: EnterpriseRoomMode = .fixed

    @State private var isRefreshing = false
    @State private var isRotating = false
    @State private var isSwitchingMode = false
    @State private var isConfirmingRotate = false

    /// 每次整页加载、离开页面都会换一个新值。回调先比对它，比对失败说明
    /// 这次结果已经过期（页面走了，或已有更新的加载在跑），直接丢弃。
    @State private var loadToken = UUID()

    /// 上一次加载对应的账号。换账号时清掉旧企业的数据，
    /// 避免骨架期那几百毫秒里露出别人的企业名与会议号。
    @State private var loadedAccountToken: String?

    /// 设计稿页面边距 20（与首页一致）；卡片内部统一 16。
    private let pagePadding: CGFloat = 20

    init(
        router: AppRouter,
        onEnterRoom: @escaping (JoinInfo) -> Void,
        onRequestLogin: @escaping () -> Void,
        onToast: @escaping (String, ToastStyle) -> Void = { _, _ in },
        onOpenSidebar: (() -> Void)? = nil
    ) {
        self._router = ObservedObject(wrappedValue: router)
        self.onEnterRoom = onEnterRoom
        self.onRequestLogin = onRequestLogin
        self.onToast = onToast
        self.onOpenSidebar = onOpenSidebar
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets

            ZStack {
                BrandBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        header

                        content
                            .padding(.top, 20)
                    }
                    .padding(.horizontal, pagePadding)
                    .padding(.top, insets.top + 8)
                    // 悬浮 Dock 实际占位 58 + 10 + 安全区；120 是"刚好露出最后一行
                    // 再加两指呼吸"的值。少算会卡在玻璃块边缘，像被裁掉。
                    .padding(.bottom, 120 + insets.bottom)
                }
                // GeometryReader 里的子视图从屏幕原点开始，手动吃安全区，
                // 顶部留白已经由 insets.top + 8 显式给过。
                .ignoresSafeArea()

                if isConfirmingRotate {
                    rotateDialog
                        .zIndex(2)
                }
            }
        }
        .onAppear {
            // 从登录页回来时账号可能变了；首帧用骨架，已就绪时只做静默刷新。
            load(showSkeleton: pageState != .ready)
        }
        .onDisappear {
            // 换一个 token：所有还在路上的回调都会在 guard 处被丢弃。
            loadToken = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // 登录页可能是以 sheet 形式盖在本页上的，登录成功后本页不会重新
            // onAppear；AuthStore 落盘会触发这条通知，用它把账号态接回来。
            // 通知的投递线程跟着写入方走，统一回主线程再改 @State。
            DispatchQueue.main.async {
                let current = AuthStore.load()
                // 只比对 token：改昵称、换头像色同样会写 UserDefaults，不该引发网络请求。
                guard current?.token != session?.token else { return }
                load(showSkeleton: current != nil)
            }
        }
        .onChange(of: modeSelection) { value in
            // 只处理"用户改了选择"这一种变化。加载后同步值、失败后回滚值
            // 都会走到这里，但它们与 room.roomMode 相等，被同一个 guard 挡掉。
            guard
                let current = room,
                current.canManage,
                value != current.roomMode
            else { return }

            changeMode(to: value)
        }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("企业空间")
                    .font(.system(size: 28, weight: .semibold))
                    .kerning(-0.3)
                    .foregroundColor(Theme.Palette.ink)

                Text("企业专属会议室，随时和同事开会。")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Palette.ink2)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                refreshButton

                if let onOpenSidebar = onOpenSidebar {
                    SidebarMenuButton(action: onOpenSidebar)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 未登录时禁用而不是隐藏：页头的入口位置保持稳定，
    /// 用户登录回来后不需要重新寻找"刷新"在哪里。
    private var refreshButton: some View {
        Button {
            Haptics.impact(.light)
            load(showSkeleton: false, notifyOnSuccess: true)
        } label: {
            ZStack {
                if isRefreshing || pageState == .loading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Theme.Palette.ink2))
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: SymbolCompat.name("arrow.clockwise", "arrow.triangle.2.circlepath"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink2)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .liquidGlass(.clear, cornerStyle: .circle, isInteractive: true, castsShadow: false)
        .disabled(refreshDisabled)
        .opacity(refreshDisabled ? 0.4 : 1.0)
        .accessibilityLabel("刷新企业空间")
    }

    private var refreshDisabled: Bool {
        if session == nil { return true }
        if isRefreshing || isRotating || isSwitchingMode { return true }

        switch pageState {
        case .idle, .loading:
            return true
        case .ready, .noEnterprise, .failed(_):
            return false
        }
    }

    // MARK: - 内容分发

    @ViewBuilder
    private var content: some View {
        if session == nil {
            loginCard
        } else {
            switch pageState {
            case .idle, .loading:
                loadingSkeleton

            case .noEnterprise:
                noEnterpriseCard

            case .failed(let message):
                errorCard(message)

            case .ready:
                if let overview = overview, let room = room {
                    loadedContent(overview: overview, room: room)
                } else {
                    // 理论上不可达。真的出现时给可重试的错误卡，
                    // 而不是留一个永远转下去的骨架。
                    errorCard("企业信息尚未加载完成")
                }
            }
        }
    }

    private func loadedContent(overview: EnterpriseOverview, room: EnterpriseRoom) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            identityCard(overview)
            roomCard(room)

            if overview.isAdmin, meetingsLoaded {
                meetingsCard
            }

            securityCard(room)
        }
    }

    // MARK: - 未登录

    private var loginCard: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.14))
                    .frame(width: 56, height: 56)

                Image(systemName: SymbolCompat.name("person.crop.circle", "person.fill"))
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(Theme.Palette.accent)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 8) {
                Text("登录后可用企业会议室")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)
                    .multilineTextAlignment(.center)

                Text("使用企业分配的账号登录，加入企业后即可进入专属会议室。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.ink3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Haptics.impact(.light)
                onRequestLogin()
            } label: {
                Text("登录")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .liquidGlass(
                .tinted(Theme.Palette.accent),
                cornerStyle: .continuous(14),
                isInteractive: true,
                castsShadow: false
            )
            .accessibilityLabel("登录企业账号")
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .liquidGlass(.regular, cornerStyle: .continuous(20), castsShadow: false)
    }

    // MARK: - 未加入企业

    private var noEnterpriseCard: some View {
        VStack(spacing: 12) {
            Image(systemName: SymbolCompat.name("building.2", "building"))
                .font(.system(size: 32, weight: .light))
                .foregroundColor(Theme.Palette.ink3)
                .accessibilityHidden(true)

            Text("尚未加入企业")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.Palette.ink)

            Text("请让企业管理员在后台把你的账号加入企业。")
                .font(.system(size: 12))
                .foregroundColor(Theme.Palette.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .liquidGlass(.regular, cornerStyle: .continuous(20), castsShadow: false)
    }

    // MARK: - 加载骨架

    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 16) {
            skeletonBlock(height: 96)
            skeletonBlock(height: 248)
            skeletonBlock(height: 88)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载企业空间")
    }

    private func skeletonBlock(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Theme.Palette.surfaceSubtle)
            .frame(height: height)
            .accessibilityHidden(true)
    }

    // MARK: - 错误

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: SymbolCompat.name("exclamationmark.triangle.fill", "exclamationmark.triangle"))
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Theme.Palette.warning)
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Haptics.impact(.light)
                load(showSkeleton: true)
            } label: {
                Text("重试")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)
                    .padding(.horizontal, 24)
                    .frame(height: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(PlainButtonStyle())
            .liquidGlass(.regular, cornerStyle: .capsule, isInteractive: true, castsShadow: false)
            .accessibilityLabel("重试")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .liquidGlass(.regular, cornerStyle: .continuous(20), castsShadow: false)
    }

    // MARK: - 企业身份

    private func identityCard(_ overview: EnterpriseOverview) -> some View {
        let enterprise = overview.enterprise
        let limit = overview.memberLimit
        let members = overview.usage.members
        let ratio = progressRatio(members: members, limit: limit)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.Palette.brandGradient)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(enterpriseInitial(enterprise.name))
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(Theme.Palette.ink)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(enterprise.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Theme.Palette.ink)
                            .lineLimit(1)

                        if overview.isAdmin {
                            adminPill
                        }
                    }

                    if !enterprise.adminName.isEmpty {
                        Text("企业管理员：\(enterprise.adminName)")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.Palette.ink3)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(memberUsageText(members: members, limit: limit))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundColor(Theme.Palette.ink)

                    Text("成员")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Palette.ink3)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("企业成员 \(members) 人，上限 \(limit) 人")
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Palette.surfaceSubtle)

                    Capsule()
                        .fill(Theme.Palette.accent)
                        .frame(width: proxy.size.width * ratio)
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .padding(16)
        .liquidGlass(.regular, cornerStyle: .continuous(20), castsShadow: false)
    }

    private var adminPill: some View {
        Text("管理员")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Theme.Palette.accent)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Theme.Palette.accent.opacity(0.16)))
    }

    private func enterpriseInitial(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "企" }
        return String(first)
    }

    private func memberUsageText(members: Int, limit: Int) -> String {
        // 上限缺失时不显示 "12/0"：分母为 0 不是真实用量，写出来只会让人以为名额用完了。
        limit > 0 ? "\(members)/\(limit)" : "\(members)"
    }

    private func progressRatio(members: Int, limit: Int) -> CGFloat {
        guard limit > 0 else { return 0 }
        let raw = CGFloat(max(members, 0)) / CGFloat(limit)
        return min(max(raw, 0), 1)
    }

    // MARK: - 专属会议室

    private func roomCard(_ room: EnterpriseRoom) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("专属企业会议室")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Palette.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.Palette.accent.opacity(0.16)))

                Spacer(minLength: 8)

                liveStatus(room)
            }

            numberBlock(room)
            modeBlock(room)
            enterButton(room)

            if room.canManage {
                manageButtons(room)
            }
        }
        .padding(16)
        .liquidGlass(.regular, cornerStyle: .continuous(20), castsShadow: false)
    }

    private func numberBlock(_ room: EnterpriseRoom) -> some View {
        Text(JoinInfo.groupDigits(room.no))
            .font(.system(size: 28, weight: .semibold).monospacedDigit())
            .kerning(1.5)
            .foregroundColor(Theme.Palette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            // 数字滚动的过渡效果是更高版本才有的 API；
            // 这里用最朴素的动画表达"号码换了"，不为一个过渡引入版本分叉。
            .animationCompat(Theme.Motion.standard, value: room.no)
            // 分组后的号码（862 4471）会被 VoiceOver 读成两个数字，
            // 逐位读出更接近用户抄号码时的习惯。
            .accessibilityLabel("会议号 \(spokenDigits(room.no))")
    }

    @ViewBuilder
    private func liveStatus(_ room: EnterpriseRoom) -> some View {
        if room.isLive {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.Palette.success)
                    .frame(width: 6, height: 6)

                Text(room.liveCount > 0 ? "\(room.liveCount) 人进行中" : "进行中")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.Palette.success)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("空闲")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.Palette.ink3)
        }
    }

    @ViewBuilder
    private func modeBlock(_ room: EnterpriseRoom) -> some View {
        if room.canManage {
            VStack(alignment: .leading, spacing: 8) {
                Picker("会议号模式", selection: $modeSelection) {
                    ForEach(EnterpriseRoomMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // 系统分段控件的固有高度是 32，撑到 44 才满足触控目标。
                // 拉高的是控件本身，而不是套一层透明热区——后者会让点击落在
                // 没有视觉反馈的空白处，反而更让人困惑。
                .frame(height: 44)
                .disabled(isBusy)
                .opacity(isBusy ? 0.6 : 1.0)
                .accessibilityLabel("会议号模式")

                hintRow(modeSelection.hint)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(room.roomMode.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.Palette.surfaceSubtle))

                Text(room.roomMode.hint)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func hintRow(_ hint: String) -> some View {
        HStack(spacing: 8) {
            Text(hint)
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)

            if isSwitchingMode {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.Palette.ink3))
                    .scaleEffect(0.7)
            }

            Spacer(minLength: 0)
        }
    }

    private func enterButton(_ room: EnterpriseRoom) -> some View {
        Button {
            enterRoom(room)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: SymbolCompat.name("video.fill", "video"))
                    .font(.system(size: 14, weight: .semibold))

                Text("进入会议室")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(Theme.Palette.ink)
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
        // 切模式/换号期间号码可能正在变，此时进入会用旧号码，直接禁用。
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
        .accessibilityLabel("进入企业会议室")
    }

    private func manageButtons(_ room: EnterpriseRoom) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                secondaryButton(
                    title: "复制邀请",
                    symbol: "doc.on.doc",
                    isEnabled: !isBusy
                ) {
                    copyInvite(room)
                }

                secondaryButton(
                    title: isRotating ? "换号中" : "换号",
                    symbol: "arrow.triangle.2.circlepath",
                    isLoading: isRotating,
                    isEnabled: canRotate(room)
                ) {
                    isConfirmingRotate = true
                }
            }

            if room.liveCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: SymbolCompat.name("info.circle"))
                        .font(.system(size: 10, weight: .medium))

                    Text("会议室正在使用，结束后才能换号")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(Theme.Palette.ink3)
            }
        }
    }

    private func secondaryButton(
        title: String,
        symbol: String,
        isLoading: Bool = false,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            // 换号、复制邀请共用这一层触觉：点击即确认，
            // 不依赖后续网络结果，避免"点了没反应"的错觉。
            Haptics.impact(.light)
            action()
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Theme.Palette.ink2))
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: SymbolCompat.name(symbol, "circle"))
                        .font(.system(size: 12, weight: .medium))
                }

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isEnabled || isLoading ? Theme.Palette.ink : Theme.Palette.ink3)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
        .liquidGlass(
            .regular,
            cornerStyle: .continuous(12),
            isInteractive: isEnabled,
            castsShadow: false
        )
        .disabled(!isEnabled)
        .opacity(isEnabled || isLoading ? 1.0 : 0.5)
        .accessibilityLabel(title)
    }

    private func canRotate(_ room: EnterpriseRoom) -> Bool {
        !isBusy && room.liveCount == 0
    }

    // MARK: - 会议列表

    private var meetingsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("企业会议")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)

                Spacer(minLength: 8)

                if !meetings.isEmpty {
                    Text("\(meetings.count) 场")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.ink3)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(height: 1)

            if meetings.isEmpty {
                Text("还没有企业会议")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(Array(visibleMeetings.enumerated()), id: \.element.id) { index, item in
                    meetingRow(item)

                    if index < visibleMeetings.count - 1 {
                        Rectangle()
                            .fill(Theme.Palette.hairline)
                            .frame(height: 1)
                            .padding(.leading, 16)
                    }
                }

                if meetings.count > visibleMeetings.count {
                    Rectangle()
                        .fill(Theme.Palette.hairline)
                        .frame(height: 1)

                    Text("共 \(meetings.count) 场")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
        .liquidGlass(.regular, cornerStyle: .continuous(20), castsShadow: false)
    }

    private var visibleMeetings: [EnterpriseMeetingSummary] {
        Array(meetings.prefix(6))
    }

    private func meetingRow(_ item: EnterpriseMeetingSummary) -> some View {
        let meta = statusMeta(item)
        let title = meetingTitle(item)

        return Button {
            openMeeting(item)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink)
                        .lineLimit(1)

                    if !item.metaText.isEmpty {
                        Text(item.metaText)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Palette.ink3)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(meta.text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(meta.color)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(meta.color.opacity(0.14)))

                    if item.liveCount > 0 {
                        Text("\(item.liveCount) 人")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.Palette.ink3)
                    }
                }

                Image(systemName: SymbolCompat.name("chevron.right"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(BrandPressStyle())
        .accessibilityLabel("\(title)，\(meta.text)，进入会议")
    }

    private func meetingTitle(_ item: EnterpriseMeetingSummary) -> String {
        item.title.isEmpty ? "企业会议" : item.title
    }

    private func statusMeta(_ item: EnterpriseMeetingSummary) -> (text: String, color: Color) {
        // 只要还有人在房间里，就按进行中展示：状态字段可能因为另一端
        // 尚未刷新而滞后，在线人数是更直接的信号。
        if item.isLive {
            return ("进行中", Theme.Palette.success)
        }

        switch item.status {
        case "scheduled":
            return ("未开始", Theme.Palette.accent)
        case "ended":
            return ("已结束", Theme.Palette.ink3)
        case "canceled":
            return ("已取消", Theme.Palette.danger)
        default:
            // 未知状态原样展示服务端的值，不编造一个"正常/异常"的结论。
            return (item.status.isEmpty ? "未知" : item.status, Theme.Palette.ink3)
        }
    }

    // MARK: - 安全说明

    @ViewBuilder
    private func securityCard(_ room: EnterpriseRoom) -> some View {
        if let text = securityText(room) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: SymbolCompat.name("lock.shield", "lock.fill"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.Palette.ink3)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("会议安全")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink2)

                    Text(text)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .liquidGlass(.regular, cornerStyle: .continuous(20), castsShadow: false)
        }
    }

    /// 只陈述服务端 settings 里真实为 true 的部分。
    /// 两项都被关掉时返回 nil，而不是继续写"默认开启"——
    /// 安全文案说错一次，比少一张说明卡严重得多。
    private func securityText(_ room: EnterpriseRoom) -> String? {
        switch (room.e2ee, room.noArchive) {
        case (true, true):
            return "企业会议默认开启端到端加密，会议内容不归档。"
        case (true, false):
            return "企业会议默认开启端到端加密。"
        case (false, true):
            return "企业会议默认不归档会议内容。"
        case (false, false):
            return nil
        }
    }

    // MARK: - 换号确认

    private var rotateDialog: some View {
        GlassConfirmDialog(
            title: "更换会议号？",
            message: "换号后旧号码立即失效，并中断当前无人会议。",
            confirmTitle: "换号",
            isDestructive: true,
            onConfirm: {
                confirmRotate()
            },
            onCancel: {
                withAnimation(Theme.Motion.standard) {
                    isConfirmingRotate = false
                }
            }
        )
    }

    // MARK: - 加载

    /// - Parameters:
    ///   - showSkeleton: 首次加载为 true；已有内容时的刷新为 false，
    ///     只在右上角转小菊花，不清空用户正在看的内容。
    ///   - notifyOnSuccess: 只有用户主动点刷新才提示"已刷新"。
    ///     自动刷新（例如从登录页回来）不该弹一条用户没预期的提示。
    private func load(showSkeleton: Bool, notifyOnSuccess: Bool = false) {
        let currentSession = AuthStore.load()
        session = currentSession

        guard let currentSession = currentSession else {
            overview = nil
            room = nil
            meetings = []
            meetingsLoaded = false
            pageState = .idle
            isRefreshing = false
            isRotating = false
            isSwitchingMode = false
            isConfirmingRotate = false
            return
        }

        if loadedAccountToken != currentSession.token {
            loadedAccountToken = currentSession.token
            overview = nil
            room = nil
            meetings = []
            meetingsLoaded = false
            modeSelection = .fixed
        }

        let token = UUID()
        loadToken = token

        // 新的整页加载会让所有在途操作作废。不重置的话，
        // 被丢弃的换号回调会让按钮永远停在 loading。
        isRotating = false
        isSwitchingMode = false
        isConfirmingRotate = false

        let keepsContentOnFailure = !showSkeleton && pageState == .ready

        if showSkeleton {
            pageState = .loading
        } else {
            isRefreshing = true
        }

        EnterpriseService.fetchOverview { result in
            // 整页加载的总闸：页面已离开或已有新加载时，下面所有写入都跳过。
            guard token == self.loadToken else { return }

            switch result {
            case .failure(let error):
                self.finishFailure(error, keepContent: keepsContentOnFailure)

            case .success(let value):
                guard let value = value else {
                    self.overview = nil
                    self.room = nil
                    self.meetings = []
                    self.meetingsLoaded = false
                    self.isRefreshing = false
                    self.pageState = .noEnterprise
                    if notifyOnSuccess {
                        self.onToast("已刷新", .success)
                    }
                    return
                }

                self.overview = value
                self.loadRoom(
                    token: token,
                    overview: value,
                    keepContentOnFailure: keepsContentOnFailure,
                    notifyOnSuccess: notifyOnSuccess
                )
            }
        }
    }

    private func loadRoom(
        token: UUID,
        overview: EnterpriseOverview,
        keepContentOnFailure: Bool,
        notifyOnSuccess: Bool
    ) {
        EnterpriseService.fetchRoom { result in
            guard token == self.loadToken else { return }

            switch result {
            case .failure(let error):
                if EnterpriseError.isNotInEnterprise(error) {
                    // 概览与会议室两个接口对企业归属的判断理论上一致；
                    // 真的不一致时以会议室接口为准，不伪造一个进不去的入口。
                    self.room = nil
                    self.meetings = []
                    self.meetingsLoaded = false
                    self.isRefreshing = false
                    self.pageState = .noEnterprise
                } else {
                    self.finishFailure(error, keepContent: keepContentOnFailure)
                }

            case .success(let value):
                self.room = value
                self.modeSelection = value.roomMode
                self.pageState = .ready
                self.isRefreshing = false
                self.loadMeetings(token: token, isAdmin: overview.isAdmin)

                if notifyOnSuccess {
                    self.onToast("已刷新", .success)
                }
            }
        }
    }

    /// 列表是管理员专属的附加信息。失败时整体隐藏，不影响已经加载好的
    /// 会议室主入口——不能因为附加信息失败，把用户能进会的路一起堵上。
    private func loadMeetings(token: UUID, isAdmin: Bool) {
        meetingsLoaded = false

        guard isAdmin else {
            meetings = []
            return
        }

        EnterpriseService.fetchMeetings { result in
            guard token == self.loadToken else { return }

            switch result {
            case .success(let list):
                self.meetings = list
                self.meetingsLoaded = true
            case .failure:
                self.meetings = []
                self.meetingsLoaded = false
            }
        }
    }

    private func finishFailure(_ error: Error, keepContent: Bool) {
        let message = EnterpriseError.message(from: error)
        isRefreshing = false

        // 已有内容时，刷新失败只弹 toast，不把可用的会议室入口换成错误卡；
        // 首次加载失败才整页进入错误态。
        if keepContent, pageState == .ready {
            onToast("刷新失败：\(message)", .danger)
        } else {
            pageState = .failed(message)
        }
    }

    // MARK: - 动作

    private var isBusy: Bool {
        isRotating || isSwitchingMode
    }

    private func changeMode(to mode: EnterpriseRoomMode) {
        guard
            let current = room,
            mode != current.roomMode,
            !isBusy
        else { return }

        Haptics.impact(.light)

        let token = loadToken
        isSwitchingMode = true

        EnterpriseService.updateRoomMode(mode) { result in
            guard token == self.loadToken else { return }
            self.isSwitchingMode = false

            switch result {
            case .success(let updated):
                let numberChanged = updated.no != self.room?.no
                self.room = updated
                self.modeSelection = updated.roomMode
                self.onToast(
                    numberChanged
                        ? "已切换为\(updated.roomMode.title)，会议号已更新"
                        : "已切换为\(updated.roomMode.title)",
                    .success
                )

            case .failure(let error):
                // 回滚到服务端当前值。这次赋值会再触发一次 onChange，
                // 但那时 value == room.roomMode，会被 onChange 的 guard 挡掉，
                // 不会形成"失败 → 回滚 → 再请求"的循环。
                self.modeSelection = current.roomMode
                Haptics.notify(.error)
                self.onToast(EnterpriseError.message(from: error), .danger)
            }
        }
    }

    private func confirmRotate() {
        withAnimation(Theme.Motion.standard) {
            isConfirmingRotate = false
        }

        guard let current = room else { return }
        guard current.liveCount == 0 else {
            onToast("会议室正在使用，结束后再换号", .warning)
            return
        }

        let token = loadToken
        isRotating = true

        EnterpriseService.rotateRoom { result in
            guard token == self.loadToken else { return }
            self.isRotating = false

            switch result {
            case .success(let updated):
                self.room = updated
                self.modeSelection = updated.roomMode
                self.onToast("会议号已更新", .success)

            case .failure(let error):
                Haptics.notify(.error)
                self.onToast(EnterpriseError.message(from: error), .danger)
            }
        }
    }

    private func copyInvite(_ room: EnterpriseRoom) {
        let inviteUrl = room.inviteUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        // 服务端没给邀请地址时回落到 App 自己的 scheme：
        // 这是唯一一个不依赖网页域名、在 App 内一定能打开的形式。
        let text = inviteUrl.isEmpty ? "tianqiong://join/\(room.no)" : inviteUrl

        UIPasteboard.general.string = text
        onToast("邀请链接已复制", .success)
    }

    private func enterRoom(_ room: EnterpriseRoom) {
        Haptics.impact(.medium)

        let trimmedTitle = room.title.trimmingCharacters(in: .whitespacesAndNewlines)
        onEnterRoom(
            JoinInfo(
                meetingNumber: room.no,
                title: trimmedTitle.isEmpty ? "企业会议室" : trimmedTitle,
                displayName: router.profile.displayName,
                // canManage 是服务端对"主持人 / 企业管理员"的合并判定，
                // 比在客户端猜身份更接近真实权限。
                isHost: room.canManage,
                // 音视频预置要跟着设置走。不传就落到 JoinInfo 的默认值
                // （麦克风开、摄像头关），用户在设置里关掉的默认麦克风会在这里被悄悄打开。
                micOn: AppSettings.mediaDefaultsSnapshot.mic,
                cameraOn: AppSettings.mediaDefaultsSnapshot.camera,
                token: AuthStore.load()?.token ?? ""
            )
        )
    }

    private func openMeeting(_ item: EnterpriseMeetingSummary) {
        Haptics.impact(.light)

        let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)

        // 列表接口不返回 isHost。这里一律按参会人入会，真实角色由会议室里的
        // participants 快照回灌（MeetingViewModel 已在快照里比对 role == .host）。
        //
        // 曾经用"主持人姓名 == 本机昵称"来猜，重名时会把普通成员判成主持人，
        // 让他一进会就看到"结束会议"——多给权限比晚一秒显示权限危险得多。
        onEnterRoom(
            JoinInfo(
                meetingNumber: item.no,
                title: trimmedTitle.isEmpty ? "企业会议" : trimmedTitle,
                displayName: router.profile.displayName,
                isHost: false,
                micOn: AppSettings.mediaDefaultsSnapshot.mic,
                cameraOn: AppSettings.mediaDefaultsSnapshot.camera,
                token: AuthStore.load()?.token ?? ""
            )
        )
    }

    // MARK: - 辅助

    private func spokenDigits(_ number: String) -> String {
        number.map { String($0) }.joined(separator: " ")
    }
}

// MARK: - 页面状态

private enum EnterprisePageState: Equatable {
    case idle
    case loading
    case ready
    case noEnterprise
    case failed(String)
}
