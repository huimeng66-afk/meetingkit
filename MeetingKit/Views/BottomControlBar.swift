//
//  BottomControlBar.swift
//  MeetingKit
//
//  会议室底栏：5 颗玻璃圆钮 + 文字标签。
//
//  ── 为什么是 5 个而不是 7 个 ────────────────────────────────────────
//  7 个键并排时每颗只有 51pt，图标下面再放 10pt 中文，整条底栏会变成"工具栏"：
//  密度过高、主次不明，用户必须逐个读字才能找到自己要做的事。
//  这一版只保留会议中真正高频的 5 个动作：
//    麦克风、摄像头、共享、消息、更多。
//  安全 / 邀请 / 成员 / 设置 全部下沉到"更多"面板，底栏不再为低频功能付宽度。
//
//  ── 麦克风脉冲 ──────────────────────────────────────────────────────
//  说话时圆钮外圈会向上扩散两圈声波。强度由 `isSpeaking` 决定：
//    · 正在说话：1.05s 一圈、描边 2pt、从不透明度 0.55 衰减到 0；
//    · 仅开麦：2.6s 一圈、描边 1pt、从 0.16 衰减，表示"正在采集"而不抢注意力；
//    · 静音：完全不画。
//  脉冲层 `allowsHitTesting(false)`，不会影响按钮命中。
//

import SwiftUI

struct BottomControlBar: View {

    @ObservedObject var viewModel: MeetingViewModel

    /// 根视图 `GeometryReader.safeAreaInsets.bottom`。
    var bottomInset: CGFloat = 0

    /// 圆钮直径。5 个键时每颗有约 76pt 的横向空间，44 是系统触控标准。
    private let keySize: CGFloat = 44

    /// 本地是否正在说话。
    ///
    /// 主判据是**真实麦克风电平**（WebRTC getStats 的 audioLevel）：
    /// 服务端不下发音量，只靠 activeSpeakerID 的话，一个人小声说话时
    /// 服务端还没把他判成"当前发言人"，脉冲就一直不亮。
    /// activeSpeakerID 作为兜底，覆盖 getStats 还没返回第一帧的瞬间。
    private var isLocalSpeaking: Bool {
        guard viewModel.isMicOn else { return false }
        // 0.035：电平现在是 RMS×4 的线性值，安静房间底噪在 0.01~0.03，
        // 说话在 0.1 以上。门限定 0.015 会让空调声把脉冲一直点亮。
        if viewModel.localAudioLevel > 0.035 { return true }
        guard let me = viewModel.localUser else { return false }
        return viewModel.activeSpeakerID == me.id
    }

    var body: some View {
        LiquidGlassContainer(spacing: 8) {
            HStack(spacing: 0) {
                micButton
                cameraButton
                shareButton
                chatButton
                moreButton
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, bottomInset + 6)
        .background(bottomScrim)
    }

    /// 自下而上的承接层。顶部完全透明，只保证按钮与文字有足够对比度。
    ///
    /// 浅色主题下不能再用黑色渐变——那会在页面底部拉出一条脏灰。
    /// 换成页面底色（#f4f5f7）的渐变：底层是实色，往上淡出，
    /// 玻璃圆钮压在上面时边缘才有落差。
    private var bottomScrim: some View {
        LinearGradient(
            stops: [
                .init(color: Theme.Palette.background.opacity(0), location: 0),
                .init(color: Theme.Palette.background.opacity(0.55), location: 0.40),
                .init(color: Theme.Palette.background.opacity(0.92), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .padding(.top, -40)
        .allowsHitTesting(false)
    }

    // MARK: - 五个键

    private var micButton: some View {
        ControlButton(
            systemImage: viewModel.isMicOn
                ? SymbolCompat.name("mic.fill")
                : SymbolCompat.name("mic.slash.fill", "mic.slash"),
            title: viewModel.isMicPending ? "开启中" : (viewModel.isMicOn ? "麦克风" : "已静音"),
            appearance: viewModel.isMicOn ? .neutral : .off,
            size: keySize,
            isLoading: viewModel.isMicPending,
            accessibilityText: viewModel.isMicOn ? "静音" : "取消静音"
        ) {
            viewModel.toggleMic()
        }
        .disabled(viewModel.isMicPending)
        // 脉冲画在圆钮下方，不参与命中测试。
        .overlay(alignment: .top) {
            MicPulseRing(
                isSpeaking: isLocalSpeaking,
                isMicOn: viewModel.isMicOn,
                diameter: keySize
            )
            .offset(y: 0)
        }
    }

    private var cameraButton: some View {
        ControlButton(
            systemImage: viewModel.isCameraOn
                ? SymbolCompat.name("video.fill")
                : SymbolCompat.name("video.slash.fill", "video.slash"),
            /* 固定写"摄像头"。
               以前关闭时标签是"已关闭"，底栏又是图标为主，用户一眼扫过去
               会把它读成"麦克风已关闭"——真机反馈里"有人进会就自动关麦"
               有一半是这句话造成的误解。状态交给图标和红色，标签只说明
               这是哪个键。 */
            title: "摄像头",
            appearance: viewModel.isCameraOn ? .neutral : .off,
            size: keySize,
            accessibilityText: viewModel.isCameraOn ? "关闭摄像头" : "开启摄像头"
        ) {
            viewModel.toggleCamera()
        }
    }

    private var shareButton: some View {
        ControlButton(
            systemImage: SymbolCompat.name(
                "rectangle.inset.filled.and.person.filled",
                "rectangle.on.rectangle",
                "rectangle.fill.on.rectangle.fill"
            ),
            title: viewModel.isScreenSharing ? "停止共享" : "共享",
            appearance: viewModel.isScreenSharing ? .broadcast : .neutral,
            isPrimary: !viewModel.isScreenSharing,
            size: keySize,
            accessibilityText: viewModel.isScreenSharing ? "停止共享屏幕" : "共享屏幕"
        ) {
            if viewModel.isScreenSharing {
                viewModel.stopScreenShare()
            } else {
                viewModel.toggleScreenShare()
            }
        }
    }

    private var chatButton: some View {
        ControlButton(
            systemImage: SymbolCompat.name(
                "bubble.left.and.bubble.right.fill",
                "bubble.left.and.bubble.right"
            ),
            title: "消息",
            size: keySize,
            badgeText: chatBadgeText,
            accessibilityText: viewModel.unreadCount > 0
                ? "消息，\(viewModel.unreadCount) 条未读"
                : "消息"
        ) {
            togglePanel(.chat)
        }
    }

    /// 未读数角标。抽成属性而不是写在调用点里：
    /// 三元表达式同时返回 String 与 nil 时，参数重载会让类型推断变慢，甚至报错。
    private var chatBadgeText: String? {
        let count = viewModel.unreadCount
        guard count > 0 else { return nil }
        return count >= 100 ? "99+" : "\(count)"
    }

    private var moreButton: some View {
        ControlButton(
            systemImage: SymbolCompat.name("ellipsis", "ellipsis.circle"),
            title: "更多",
            size: keySize,
            badgeSymbol: viewModel.isHandRaised ? "hand.raised.fill" : nil,
            accessibilityText: "更多功能"
        ) {
            togglePanel(.more)
        }
    }

    /// 同一个面板按钮再点一次就是关闭，这是底栏按钮的既定交互。
    private func togglePanel(_ panel: MeetingViewModel.MeetingPanel) {
        if viewModel.activePanel == panel {
            viewModel.closePanel()
        } else {
            viewModel.openPanel(panel)
        }
    }
}

// MARK: - 麦克风脉冲

/// 两圈错开的声波，从圆钮边缘向上扩散并淡出。
///
/// 用两个独立 Circle 而不是一个：单圈的 repeatForever 在重启瞬间会从
/// "透明的大圈"跳回"实的小圈"，看起来像闪了一下；两圈错开半拍后，
/// 每一帧至少有一圈处于可见阶段，跳变被另一圈盖住。
struct MicPulseRing: View {

    var isSpeaking: Bool
    var isMicOn: Bool
    var diameter: CGFloat

    /// 系统"减弱动态效果"。
    /// 一圈永不停止的扩散动画对前庭敏感用户是持续刺激；开启后改为静态描边，
    /// "麦克风开着"的信息仍然在，只是不再动。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expand: Bool = false

    /// 说话时更亮、更快；仅开麦时留一层能看见的呼吸。
    /// 0.16 是深色主题下的取值，浅色底上那圈几乎不存在——用户的原话是
    /// "没有脉冲"，所以开麦常态提到 0.30，让它至少能看出在呼吸。
    private var ringOpacity: Double {
        isSpeaking ? 0.55 : 0.30
    }

    private var ringScale: CGFloat {
        isSpeaking ? 1.75 : 1.30
    }

    private var duration: Double {
        isSpeaking ? 1.05 : 2.6
    }

    var body: some View {
        ZStack {
            if isMicOn {
                if reduceMotion {
                    // 静态描边：不跑循环动画，但保留"正在开麦"的视觉提示。
                    Circle()
                        .stroke(isSpeaking ? Color.white.opacity(0.5) : Color.white.opacity(0.2),
                                lineWidth: isSpeaking ? 2 : 1)
                        .frame(width: diameter, height: diameter)
                } else {
                    ring(delay: 0)
                    if isSpeaking {
                        ring(delay: duration * 0.5)
                    }
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        // 说话状态一变就重建脉冲：duration / scale 都变了，
        // 不重建的话 repeatForever 会沿用上一档的速度，直到当前圈跑完。
        .id(isSpeaking ? "speaking" : "idle")
        .onAppear {
            expand = true
        }
    }

    private func ring(delay: Double) -> some View {
        Circle()
            /* 一律用品牌色，不再用白色。
               浅色主题的底栏是 #f4f5f7，白色 0.30 的环压上去等于没有——
               用户看到的就是"麦开着，按钮一动不动"。 */
            .stroke(
                Theme.Palette.accent.opacity(isSpeaking ? 0.78 : 0.34),
                lineWidth: isSpeaking ? 2.5 : 1.5
            )
            .frame(width: diameter, height: diameter)
            .scaleEffect(expand ? ringScale : 1.0)
            // 向上偏移 8pt：用户要的是"往上冒"的声波，而不是以按钮为圆心的同心圆。
            .offset(y: expand ? -8 : 0)
            .opacity(expand ? 0 : ringOpacity)
            .animation(
                .easeOut(duration: duration)
                    .repeatForever(autoreverses: false)
                    .delay(delay),
                value: expand
            )
    }
}

struct BottomControlBar_Previews: PreviewProvider {
    static var previews: some View {
        ZStack(alignment: .bottom) {
            Theme.Palette.tileBackground
            VStack {
                Spacer()
                BottomControlBar(viewModel: MeetingViewModel(), bottomInset: 34)
            }
        }
        .preferredColorScheme(.dark)
    }
}
