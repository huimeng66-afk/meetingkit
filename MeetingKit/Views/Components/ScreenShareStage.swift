//
//  ScreenShareStage.swift
//  MeetingKit
//
//  共享舞台：会议里唯一"以内容为中心"的页面形态。
//
//  ── 为什么单独一个文件，而不是继续堆在 VideoCanvasView ─────────────────
//  共享态的交互和宫格/演讲者完全不同：它要能放大看细节、要能切换适应/填充、
//  要在无人操作时自动让出整块屏幕。这些状态如果仍挂在画布上，画布会变成
//  一个既管布局又管手势的巨型视图；拆出来之后，画布只负责"什么时候显示它"。
//
//  ── 一条硬规则：共享者本人不回显自己的画面 ────────────────────────────
//  本机共享时显示的是状态卡，不是屏幕镜像。原因有三：
//    1. 一块屏幕上看自己正在共享的屏幕没有新增信息，只会让人以为画面卡住；
//    2. App Group 每秒只搬 4~20 帧 JPEG，回显必然比真实屏幕慢半拍，
//       用户会误判"共享出去的就是这张卡顿的画面"；
//    3. iOS 的屏幕录制本身对"录制者可见性"没有要求，回显只是纯 UI 成本。
//  参会者看到的是实时视频轨，本机看到的是一条明确的"正在共享中"状态。
//

import SwiftUI
import UIKit
import WebRTC

struct ScreenShareStage: View {

    @ObservedObject var viewModel: MeetingViewModel

    /// 根视图安全区底部。工具条要贴在 home indicator 上方。
    var bottomInset: CGFloat = 0

    /// 适应 / 填充。默认适应：共享 PPT 时"少裁一点"永远比"多裁一点"安全。
    @State private var isFillMode = false

    /// 复位令牌。每次换共享者 / 重新进入共享态自增，缩放容器据此回到 1x。
    /// 不用 Binding 直接驱动 UIScrollView：UIKit 与 SwiftUI 的状态同步只保留单向，
    /// 否则用户双指缩放后 SwiftUI 还以为 scale 是 1，下一次 update 会把画面拽回去。
    @State private var zoomResetToken = 0

    /// 自动收起控件的延时任务。切人/离场都要取消，否则旧任务会把新画面的控件收掉。
    @State private var autoHideTask: DispatchWorkItem?

    private var isSelfSharing: Bool {
        viewModel.isScreenSharing && viewModel.remoteScreenPeerID == nil
    }

    private var remoteMedia: UIView? {
        guard let peerID = viewModel.remoteScreenPeerID else { return nil }
        return viewModel.remoteScreenViews[peerID]
    }

    var body: some View {
        ZStack {
            // 共享画面永远铺在纯黑上：任何彩色底都会在画面边缘形成一圈脏边。
            Color.black.ignoresSafeArea()

            content

            // 浮层控件不参与布局，共享画面始终是全屏尺寸。
            overlayChrome
        }
        .onAppear {
            scheduleAutoHide()
        }
        .onDisappear {
            cancelAutoHide()
        }
        .onChange(of: viewModel.remoteScreenPeerID) { _ in
            // 换了共享者：缩放必须归位，否则新画面一进来就是上一张 PPT 的 3x 位置。
            zoomResetToken += 1
            scheduleAutoHide()
        }
        .onChange(of: viewModel.isScreenSharing) { _ in
            zoomResetToken += 1
            scheduleAutoHide()
        }
        .onChange(of: viewModel.isChromeVisible) { visible in
            if visible {
                scheduleAutoHide()
            } else {
                cancelAutoHide()
            }
        }
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if isSelfSharing {
            selfSharingCard
        } else if let media = remoteMedia {
            ZoomableScreenView(
                mediaView: media,
                isFillMode: isFillMode,
                resetToken: zoomResetToken,
                onTap: toggleChrome
            )
            .ignoresSafeArea()
        } else if viewModel.remoteScreenPeerID != nil {
            receivingCard
        } else {
            // isScreenSharing 为真、remotePeerID 也为真（两人同时共享）时走远端画面：
            // 看别人的内容优先。服务端正常情况下只允许一个共享者，这里只是兜底。
            receivingCard
        }
    }

    // MARK: - 本机共享状态卡（不回显画面）

    private var selfSharingCard: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                // 呼吸光晕只做"活着"的暗示，不承载信息，因此压得很低。
                Circle()
                    .fill(Theme.Palette.success.opacity(0.12))
                    .frame(width: 132, height: 132)
                    .blur(radius: 18)

                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 88, height: 88)

                Image(systemName: SymbolCompat.name(
                    "rectangle.inset.filled.and.person.filled",
                    "rectangle.on.rectangle",
                    "rectangle.fill.on.rectangle.fill"
                ))
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(Theme.Palette.success)
            }

            Text("正在屏幕共享中")
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(Theme.Palette.textPrimary)
                .padding(.top, 22)
                .accessibilityAddTraits(.isHeader)

            Text("参会成员可以看到你的屏幕")
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.textSecondary)
                .padding(.top, 7)

            // 这句是"为什么不显示自己的画面"的显式解释。
            // 不写的话，用户会以为共享没成功——因为屏幕上什么都没有。
            Text("为减少延迟，本机不回显共享画面")
                .font(.system(size: 11.5))
                .foregroundColor(Theme.Palette.textTertiary)
                .padding(.top, 2)

            HStack(spacing: 6) {
                Image(systemName: SymbolCompat.name("timer", "clock"))
                    .font(.system(size: 11, weight: .medium))

                Text(viewModel.shareDurationText)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .foregroundColor(Theme.Palette.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .liquidGlass(.clear, cornerStyle: .capsule, castsShadow: false)
            .padding(.top, 18)

            Button {
                Haptics.impact(.medium)
                viewModel.stopScreenShare()
            } label: {
                Label {
                    Text("停止共享")
                        .font(.system(size: 15, weight: .semibold))
                } icon: {
                    Image(systemName: SymbolCompat.name("stop.fill", "stop.circle.fill"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 26)
                .frame(height: 46)
                .liquidGlass(
                    .tinted(Theme.Palette.danger),
                    cornerStyle: .capsule,
                    isInteractive: true,
                    castsShadow: false
                )
                .contentShape(Capsule())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 22)
            .accessibilityLabel("停止共享屏幕")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // 极轻的一团绿光，位置偏上：让状态卡不是"浮在纯黑里的一张纸"。
            RadialGradient(
                colors: [
                    Theme.Palette.success.opacity(0.10),
                    Color.clear
                ],
                center: UnitPoint(x: 0.5, y: 0.34),
                startRadius: 0,
                endRadius: 320
            )
            .ignoresSafeArea()
        )
        // 本机共享没有缩放容器，点击恢复控件只能自己接。
        // 顶栏"收起控件"之后，这张卡是画面上唯一还能点的东西。
        .contentShape(Rectangle())
        .onTapGesture {
            toggleChrome()
        }
    }

    // MARK: - 接收中占位

    private var receivingCard: some View {
        VStack(spacing: 18) {
            if let user = remoteSharer {
                AvatarView(user: user, size: 64, showsSpeakingRing: false)
                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
            } else {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 64, height: 64)

                    Image(systemName: SymbolCompat.name("rectangle.on.rectangle", "rectangle.fill"))
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(Theme.Palette.textSecondary)
                }
            }

            VStack(spacing: 6) {
                Text("\(DisplayName.clean(viewModel.remoteScreenPeerName, fallback: "参会成员")) 正在共享")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.center)

                Text("画面马上就到")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.textSecondary)
            }

            LoadingDotsView(tint: Theme.Palette.textSecondary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 接收中的占位卡同样需要"点一下恢复控件"的逃生口。
        .contentShape(Rectangle())
        .onTapGesture {
            toggleChrome()
        }
    }

    // MARK: - 浮层

    /// 共享舞台只保留一条底部工具条。
    ///
    /// 顶栏已经有一条红色共享条（含共享者、时长、停止入口），舞台里再放一个
    /// "某某正在共享"的玻璃胶囊就是同一句话写两遍。控件隐藏时顶栏和工具条
    /// 一起淡出，才是真正的沉浸观看——这也是"共享优先"的应有之义。
    @ViewBuilder
    private var overlayChrome: some View {
        if !isSelfSharing {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                shareToolbar
                    // 顶栏可见时让开底栏（64 + 安全区 + 呼吸位），隐藏时贴近底部。
                    .padding(.bottom, bottomInset + (viewModel.isChromeVisible ? 82 : 14))
            }
            .opacity(viewModel.isChromeVisible ? 1 : 0)
            .allowsHitTesting(viewModel.isChromeVisible)
            .animationCompat(Theme.Motion.standard, value: viewModel.isChromeVisible)
        }
    }

    /// 观看者工具条。共享者本人没有这条：他没有画面可缩放。
    private var shareToolbar: some View {
        HStack(spacing: 4) {
            toolbarButton(
                symbol: isFillMode
                    ? SymbolCompat.name("arrow.down.right.and.arrow.up.left", "rectangle.compress.vertical")
                    : SymbolCompat.name("arrow.up.left.and.arrow.down.right", "rectangle.expand.vertical"),
                label: isFillMode ? "切换到适应屏幕" : "切换到填充屏幕"
            ) {
                withAnimation(Theme.Motion.standard) {
                    isFillMode.toggle()
                }
                Haptics.selection()
            }

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 20)

            toolbarButton(
                symbol: SymbolCompat.name("1.magnifyingglass", "minus.magnifyingglass"),
                label: "还原缩放"
            ) {
                zoomResetToken += 1
                Haptics.selection()
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 46)
        .liquidGlass(.clear, cornerStyle: .capsule, castsShadow: false)
    }

    private func toolbarButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.Palette.textPrimary)
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: - 交互

    private func toggleChrome() {
        Haptics.impact(.light)
        withAnimation(Theme.Motion.standard) {
            viewModel.isChromeVisible.toggle()
        }
    }

    /// 4 秒无操作收起控件。
    ///
    /// 只对远端共享生效：本机共享时"停止共享"是最重要的逃生口，
    /// 自动把它藏起来会让用户在最需要的时候找不到按钮（底栏也被一起藏了）。
    private func scheduleAutoHide() {
        cancelAutoHide()

        guard AppSettings.autoHideControlsDuringShareSnapshot else { return }
        guard viewModel.remoteScreenPeerID != nil else { return }
        guard viewModel.isChromeVisible else { return }

        let work = DispatchWorkItem {
            withAnimation(Theme.Motion.standard) {
                viewModel.isChromeVisible = false
            }
        }
        autoHideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    private var remoteSharer: MeetingUser? {
        guard let peerID = viewModel.remoteScreenPeerID else { return nil }
        return viewModel.participants.first(where: { $0.id == peerID })
    }
}

// MARK: - 缩放容器

/// 共享画面的缩放容器。
///
/// 为什么用 UIScrollView 而不是 SwiftUI 的 MagnificationGesture：
/// UIScrollView 自带橡皮筋、边界回弹、惯性、双击定点缩放与"缩放后平移不越界"，
/// 这些细节手写会写出两三百行且很难对齐系统手感。共享画面是全场唯一的阅读内容，
/// 手感差一点都会被放大成"这个 App 很卡"。
struct ZoomableScreenView: UIViewRepresentable {

    /// 远端共享的渲染视图（RTCMTLVideoView）。由 ViewModel 持有，这里只挂载。
    let mediaView: UIView

    var isFillMode: Bool
    var resetToken: Int
    var onTap: () -> Void

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.onSingleTap = onTap
        return view
    }

    func updateUIView(_ uiView: ZoomingScrollView, context: Context) {
        uiView.onSingleTap = onTap
        uiView.attach(mediaView)
        uiView.applyContentMode(fill: isFillMode)

        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            uiView.resetZoom(animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(resetToken: resetToken)
    }

    final class Coordinator {
        var lastResetToken: Int

        init(resetToken: Int) {
            lastResetToken = resetToken
        }
    }
}

/// 单屏内容 + 可缩放的滚动视图。
final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {

    /// 单击回调（切换控件显隐）。双击必须等它失败，否则每次双击都会先触发一次单击。
    var onSingleTap: (() -> Void)?

    private let canvas = UIView()
    private var mediaView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .black
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        // .fast 比默认的 .normal 更接近"看一眼细节就退回"的共享场景；
        // 默认减速会让画面在松手后继续滑很久，读 PPT 时反而难定位。
        decelerationRate = .fast
        minimumZoomScale = 1
        maximumZoomScale = 4
        delegate = self

        canvas.backgroundColor = .clear
        addSubview(canvas)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 挂载

    func attach(_ view: UIView) {
        guard mediaView !== view else { return }
        mediaView?.removeFromSuperview()
        mediaView = view
        view.frame = canvas.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.addSubview(view)
    }

    func applyContentMode(fill: Bool) {
        guard let mtl = mediaView as? RTCMTLVideoView else { return }
        // 不显式写类型名：不同 WebRTC 发行版里 videoContentMode 的类型可能是
        // RTCVideoContentMode，也可能是 UIView.ContentMode（M140 就没有导出前者）。
        // 用赋值表达式让编译器自己推断，换一个 WebRTC 版本也不会再断在类型名上。
        mtl.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
    }

    // MARK: 布局

    override func layoutSubviews() {
        super.layoutSubviews()

        // 未缩放时 canvas 必须严格等于视口。旋转/分屏后如果还沿用旧尺寸，
        // UIScrollView 会保留旧的 contentSize，画面会偏到左上角。
        if zoomScale <= 1.001 {
            if canvas.frame != bounds {
                canvas.frame = bounds
            }
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        canvas
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerCanvas()
    }

    /// 缩放后画面小于视口时居中，而不是贴在左上角。
    private func centerCanvas() {
        let insetX = max((bounds.width - contentSize.width) / 2, 0)
        let insetY = max((bounds.height - contentSize.height) / 2, 0)
        canvas.center = CGPoint(
            x: contentSize.width / 2 + insetX,
            y: contentSize.height / 2 + insetY
        )
    }

    // MARK: 手势

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
            return
        }

        // 以双击点为中心放大 2.5 倍。直接 setZoomScale 会以内容中心缩放，
        // 用户双击右下角的表格时，那一块反而会跑出屏幕。
        let point = gesture.location(in: canvas)
        let width = bounds.width / 2.5
        let height = bounds.height / 2.5
        zoom(
            to: CGRect(
                x: point.x - width / 2,
                y: point.y - height / 2,
                width: width,
                height: height
            ),
            animated: true
        )
    }

    func resetZoom(animated: Bool) {
        setZoomScale(1, animated: animated)

        guard animated else {
            contentOffset = .zero
            return
        }

        UIView.animate(
            withDuration: 0.26,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.contentOffset = .zero
        }
    }
}
