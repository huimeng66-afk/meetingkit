//
//  AppRootView.swift
//  MeetingKit
//
//  三阶段路由：首页 → 入会页 → 会议室。
//
//  为什么把路由独立成一个 ObservableObject，而不是用 NavigationView：
//  会议室必须是全屏、无导航栏、无返回手势的（否则用户可以从左边缘滑回入会页，
//  而 RTC 会话还在跑）。枚举驱动的 switch 没有导航栈，天然没有这个后门，
//  也避开了 iOS 16 才有的导航栈容器。
//

import Foundation
import SwiftUI

// MARK: - 路由

@MainActor
final class AppRouter: ObservableObject {

    enum Phase: Equatable {
        case home
        case preJoin(JoinInfo)
        case room(JoinInfo)
    }

    @Published private(set) var phase: Phase = .home
    @Published var profile: UserProfile
    @Published private(set) var history: [MeetingHistoryItem]

    /// 当前会议的上下文。离开会议室时用它写历史，不能从 phase 里现取：
    /// 路由可能在动画事务里已经切走，phase 不再可信。
    private var activeJoin: JoinInfo?
    private var roomEnteredAt: Date?
    /// 本次进会议室是否真正连上过会议（由 MeetingRoomView 确认）。
    private var roomJoinConfirmed = false

    init() {
        profile = UserProfileStore.load()
        history = MeetingHistoryStore.load()
    }

    // MARK: 路由动作

    func goHome() {
        if case .home = phase { return }
        transition(to: .home)
    }

    func openPreJoin(_ info: JoinInfo) {
        transition(to: .preJoin(info))
    }

    func join(_ info: JoinInfo) {
        activeJoin = info
        roomEnteredAt = Date()
        roomJoinConfirmed = false
        transition(to: .room(info))
    }

    /// 会议室确认真正连上（VM 的 connectionState 到 .connected）后置位。
    /// 入会失败（密码错误/网络失败）返回首页不该留下"参会记录"。
    func confirmRoomJoined() {
        roomJoinConfirmed = true
    }

    /// 从会议室返回首页。历史只在这里落库，保证"记录 = 真正开过一次会"。
    func leaveRoom() {
        recordActiveMeeting()
        transition(to: .home)
    }

    func updateProfile(displayName: String, avatarColorIndex: Int) {
        let updated = UserProfile(
            displayName: UserProfileStore.sanitizeName(displayName),
            avatarColorIndex: UserProfileStore.clampColor(avatarColorIndex)
        )
        profile = updated
        UserProfileStore.save(updated)
    }

    // MARK: 历史维护

    func removeHistory(id: String) {
        MeetingHistoryStore.remove(id: id)
        history = MeetingHistoryStore.load()
    }

    func clearHistory() {
        MeetingHistoryStore.clear()
        history = []
    }

    // MARK: 私有

    private func transition(to next: Phase) {
        withAnimation(Self.pageAnimation) {
            phase = next
        }
    }

    /// 0.25s 的根页面交叉淡入。用 spring 而不是 easeInOut，
    /// 与 Theme.Motion.standard 保持同一种手感（设计规范禁止满屏 easeInOut）。
    private static let pageAnimation = Animation.spring(response: 0.25, dampingFraction: 0.92)

    private func recordActiveMeeting() {
        defer {
            activeJoin = nil
            roomEnteredAt = nil
            roomJoinConfirmed = false
        }
        guard let join = activeJoin, let startedAt = roomEnteredAt else { return }
        guard !join.meetingNumber.isEmpty else { return }
        // 必须真正连上过会议才落历史：密码错误/网络失败等场景不产生参会记录。
        guard roomJoinConfirmed else { return }

        let title = join.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = MeetingHistoryItem(
            id: UUID().uuidString,
            title: title.isEmpty ? "会议 \(join.formattedNumber)" : title,
            number: join.meetingNumber,
            startedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt)
        )
        MeetingHistoryStore.add(item)
        history = MeetingHistoryStore.load()
    }
}

// MARK: - 根视图

struct AppRootView: View {

    @StateObject private var router = AppRouter()

    var body: some View {
        ZStack {
            // 根层只铺纯底色：三个页面各自带一层 BrandBackground，
            // 根层再叠一次光晕会让同一条渐变的透明度翻倍，失去"星空感"。
            Theme.Palette.background
                .ignoresSafeArea()

            switch router.phase {
            case .home:
                HomeView(router: router, settings: AppSettings.shared)
                    .transition(.opacity)
            case .preJoin(let info):
                PreJoinView(router: router, info: info)
                    .transition(.opacity)
            case .room(let info):
                MeetingRoomView(join: info, onExit: {
                    router.leaveRoom()
                }, onJoined: {
                    router.confirmRoomJoined()
                })
                .transition(.opacity)
            }
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .onOpenURL { url in
            handleInviteURL(url)
        }
    }

    // MARK: - 邀请链接落地

    /// 邀请二维码 / 邀请链接的落地页：`tianqiong://join/<7 位会议号>`。
    ///
    /// InvitePanel 的二维码与 VideoCanvasView 的"复制邀请"都写的是这个 scheme，
    /// 系统把它交回 App 后必须在这里解析，否则用户扫码/点链接只会打开 App 停在首页，
    /// 看起来"链接是坏的"。
    ///
    /// 规则：scheme 必须是 tianqiong、host 必须是 join、path 去掉 "/" 后清洗出
    /// 正好 7 位数字；其余情况一律静默忽略（伪造链接不该把用户带进任意页面）。
    private func handleInviteURL(_ url: URL) {
        guard url.scheme?.lowercased() == "tianqiong" else { return }
        guard url.host?.lowercased() == "join" else { return }

        let raw = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // 这里不能复用 digitsOnly：它会 prefix(7)，8 位数字会被截成合法 7 位，
        // 伪造/超长链接就能把用户带进另一个会议。严格校验原始数字位数。
        let digits = raw.filter { $0.isNumber }
        guard digits.count == 7 else { return }

        // 已经在会议室里收到邀请：必须先走一次正常离会（同时落历史、停共享），
        // 否则 room 的 phase 被原地换掉，会议室视图不会销毁，RTC 与录屏都停在半路。
        if case .room = router.phase {
            router.leaveRoom()
        }

        router.openPreJoin(
            JoinInfo(
                meetingNumber: digits,
                title: "加入会议",
                displayName: router.profile.displayName,
                isHost: false,
                token: AuthStore.load()?.token ?? ""
            )
        )
    }
}
