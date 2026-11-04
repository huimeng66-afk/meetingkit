//
//  ChatPanel.swift
//  MeetingKit
//
//  聊天面板。
//
//  几个刻意的取舍：
//    1. 输入区放在 VStack 的最后一个位置，列表 `layoutPriority(1)` 吃掉剩余高度。
//       键盘不是系统避让的：房间层挂了 `.ignoresSafeArea(.keyboard)`，
//       改由 GlassSheet 订阅键盘通知，把面板底边贴到键盘顶、同时压缩面板高度。
//       这里只要保证列表能缩短，最后一条消息就不会被输入框挡住。
//    2. 发送后不收起键盘（会议里要连续发言，收键盘等于每次多点一下）。
//    3. 气泡最大宽度按面板宽度算 72%：固定 pt 值在 iPad 上会变成一条细线。
//

import Foundation
import SwiftUI

struct ChatPanel: View {

    @ObservedObject var viewModel: MeetingViewModel

    @State private var draft: String = ""

    /// 滚动锚点：始终放在列表最后，新消息来了滚到它即可。
    private var bottomAnchorID: String { "chat-bottom-anchor" }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header

                if viewModel.messages.isEmpty {
                    emptyState
                        .layoutPriority(1)
                } else {
                    messageList(maxBubbleWidth: proxy.size.width * 0.72)
                        .layoutPriority(1)
                }

                inputBar
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Metrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("聊天")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundColor(Theme.Palette.textPrimary)

                Text("\(viewModel.participantCount) 位参会人可见")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Palette.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space1)
        .padding(.bottom, Theme.Metrics.space3)
    }

    // MARK: - 消息列表

    private func messageList(maxBubbleWidth: CGFloat) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: Theme.Metrics.space3) {
                    ForEach(viewModel.messages) { message in
                        ChatMessageRow(
                            message: message,
                            isMine: message.senderID == viewModel.localUser?.id,
                            // 颜色在父视图算好再传进去：这里能拿到 viewModel（也就是参会人列表），
                            // 行视图本身不该为了一个颜色去持有一份全局状态（H-4）。
                            avatarColorIndex: ChatAvatarColor.index(
                                for: message.senderID,
                                in: viewModel.participants
                            ),
                            maxBubbleWidth: maxBubbleWidth
                        )
                        .id(message.id)
                    }

                    // 锚点必须有高度，否则 scrollTo 在列表刚变化时可能算到 0 高度。
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(.horizontal, Theme.Metrics.horizontal)
                .padding(.bottom, Theme.Metrics.space2)
            }
            .onAppear {
                // 延后一帧：首帧布局还没完成时 scrollTo 无效。
                DispatchQueue.main.async {
                    scrollToBottom(scrollProxy, animated: false)
                }
            }
            .onChange(of: viewModel.messages.count) { _ in
                scrollToBottom(scrollProxy, animated: true)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
        if animated {
            withAnimation(Theme.Motion.standard) {
                action()
            }
        } else {
            action()
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: Theme.Metrics.space2) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.10))
                    .frame(width: 72, height: 72)

                Image(systemName: SymbolCompat.name(
                    "bubble.left.and.bubble.right.fill",
                    "bubble.left.and.bubble.right"
                ))
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(Theme.Palette.accent)
            }

            Text("还没有聊天消息")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.Palette.textSecondary)
                .padding(.top, 2)

            Text("发送一条消息，和参会人保持同步")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 输入区

    private var inputBar: some View {
        HStack(spacing: Theme.Metrics.space2) {
            // 回车发送走 iOS 13 就有的 `onCommit` 初始化器。
            // `.submitLabel(.send)` + `.onSubmit {}` 是 15 起的，14 上不可用。
            TextField("发消息…", text: $draft, onCommit: send)
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Palette.textPrimary)
                .accentColor(Theme.Palette.accent)
                .padding(.horizontal, Theme.Metrics.space3)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )

            Button {
                send()
            } label: {
                Image(systemName: SymbolCompat.name("arrow.up", "arrow.up.circle.fill"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(canSend ? .white : Theme.Palette.textTertiary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(
                            canSend
                                ? Theme.Palette.brandGradient
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.15), Color.white.opacity(0.15)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                        )
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(ControlButtonPressStyle())
            .disabled(!canSend)
            .accessibilityLabel("发送消息")
        }
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.vertical, Theme.Metrics.space2 + 2)
        .glassSurface(shape: Rectangle())
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        viewModel.sendMessage(text)
        draft = ""
        Haptics.impact(.light)
        // 保持键盘：会议里经常要连发几条，所以这里不调用 Keyboard.dismiss()。
    }
}

// MARK: - 单条消息

struct ChatMessageRow: View {

    let message: ChatMessage
    let isMine: Bool
    /// 头像配色索引。由父视图从参会人列表里查好后传入，保证与成员列表/画面宫格完全一致。
    var avatarColorIndex: Int = 0
    var maxBubbleWidth: CGFloat = 260

    var body: some View {
        if message.isSystem {
            systemRow
        } else if isMine {
            mineRow
        } else {
            otherRow
        }
    }

    // 系统消息：居中灰底胶囊，不带头像与名字。
    private var systemRow: some View {
        HStack {
            Spacer(minLength: 0)
            Text(message.text)
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Metrics.space3)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Color.white.opacity(0.08))
                )
            Spacer(minLength: 0)
        }
    }

    private var mineRow: some View {
        HStack {
            Spacer(minLength: Theme.Metrics.space6)

            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .font(Theme.Typography.body)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, Theme.Metrics.space3)
                    .padding(.vertical, 9)
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                            .fill(Theme.Palette.brandGradient)
                    )

                Text(ChatTimestamp.time(from: message.date))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Theme.Palette.textTertiary)
            }
        }
    }

    private var otherRow: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.space2) {
            // 头像比气泡小一号，避免在窄面板里抢走视线。
            // 颜色由父视图从参会人列表里查出来（同一个人的头像在所有列表里必须是同一种颜色），
            // 只有查不到时（系统消息 / 已退会成员）才回退到码点求和（H-4）。
            Circle()
                .fill(Theme.avatarGradient(index: avatarColorIndex))
                .frame(width: 28, height: 28)
                .overlay(
                    Text(String(message.senderName.prefix(1)))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(message.senderName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.Palette.textSecondary)

                Text(message.text)
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, Theme.Metrics.space3)
                    .padding(.vertical, 9)
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )

                Text(ChatTimestamp.time(from: message.date))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Theme.Palette.textTertiary)
            }

            Spacer(minLength: Theme.Metrics.space6)
        }
    }
}

// MARK: - 头像配色

/// 聊天头像的配色索引。
///
/// 首选参会人列表里的 `avatarColorIndex`：同一个人的头像在成员列表、宫格、聊天里
/// 必须是同一种颜色，各自算一套必然对不上（H-4）。只有拿不到时才回退到码点求和。
///
/// 为什么回退算法不用 `hashValue`：Swift 的 String.hashValue 带进程级随机种子，
/// 同一个 senderID 每次冷启动都会得到不同颜色。码点求和是纯函数，跨进程稳定。
enum ChatAvatarColor {

    /// 与 Theme 的头像调色板数量保持一致。
    private static let paletteCount = 8

    static func index(for senderID: String, in participants: [MeetingUser]) -> Int {
        if let matched = participants.first(where: { $0.id == senderID }) {
            return matched.avatarColorIndex
        }
        return index(for: senderID)
    }

    static func index(for senderID: String) -> Int {
        let checksum = senderID.unicodeScalars.reduce(0) { partial, scalar in
            partial &+ Int(scalar.value)
        }
        let remainder = checksum % paletteCount
        return remainder >= 0 ? remainder : remainder + paletteCount
    }
}

// MARK: - 时间格式

enum ChatTimestamp {

    /// DateFormatter 构造代价高，聊天滚动时每行都 new 一个会明显掉帧，所以全局复用一个。
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    static func time(from date: Date) -> String {
        formatter.string(from: date)
    }
}

struct ChatPanel_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.background
            ChatPanel(viewModel: MeetingViewModel())
        }
        .preferredColorScheme(.dark)
    }
}
