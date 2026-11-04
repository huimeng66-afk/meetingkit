//
//  LocalVideoFloatingView.swift
//  MeetingKit
//
//  可拖拽的本地预览小窗。
//
//  位置用"归一化坐标"保存（0...1 表示在可用行程内的比例），而不是绝对 CGPoint：
//  设备旋转、分屏、共享时缩小都会改变行程，绝对坐标一定会把窗顶出屏幕。
//  归一化后只要在每帧重新乘一次行程，窗就永远在框内，不需要额外的救场代码。
//
//  命中测试：全屏的透明底必须 allowsHitTesting(false)，
//  否则它会盖住画布点击（用户点画面收不起控件）；只有小窗本体接收手势。
//  手势挂在小窗本体、且在 .position 之前——这两条都是踩过坑的（V3）。
//

import SwiftUI

struct LocalVideoFloatingView: View {

    @ObservedObject var viewModel: MeetingViewModel

    /// 可用区域（根视图安全区内的大小）。
    var containerSize: CGSize = .zero

    /// 根视图 `GeometryReader.safeAreaInsets.top`。
    var topInset: CGFloat = 0

    /// 根视图 `GeometryReader.safeAreaInsets.bottom`。
    var bottomInset: CGFloat = 0

    /// 归一化中心位置：x=0 贴左，x=1 贴右，y=0 贴顶，y=1 贴底。
    @State private var normalized: CGPoint = CGPoint(x: 1, y: 1)
    /// 拖拽起点的归一化位置，避免每次 onChanged 都做增量累加（会漂移）。
    @State private var dragStart: CGPoint?
    @State private var isDragging = false

    // MARK: - 尺寸与行程

    /// 共享时缩到 76×112，尽量少挡共享内容。
    private var tileSize: CGSize {
        viewModel.isScreenSharing
            ? CGSize(width: 76, height: 112)
            : CGSize(width: 100, height: 150)
    }

    private var edgeMargin: CGFloat { 12 }

    /// 上边界：与 `VideoCanvasView.contentTop` 完全同一公式（顶栏 52 + 共享红条 32 + 安全区 + 8）。
    /// 只写 `topInset + 60` 时，共享期间顶栏下面多出 32pt 的红色警示条，
    /// 小窗会被它压住 24pt（52 + 8 = 60 < 52 + 32 + 8 = 92）。
    private var topLimit: CGFloat {
        topInset + 52 + (viewModel.isScreenSharing ? 32 : 0) + 8
    }

    /// 下边界：底栏顶（64 + bottomInset）再留 12pt。
    private var bottomLimit: CGFloat {
        max(topLimit + tileSize.height, containerSize.height - (64 + bottomInset) - 12)
    }

    private var travelX: CGFloat {
        max(0, containerSize.width - tileSize.width - edgeMargin * 2)
    }

    private var travelY: CGFloat {
        max(0, bottomLimit - topLimit - tileSize.height)
    }

    private var resolvedPosition: CGPoint {
        CGPoint(
            x: edgeMargin + tileSize.width / 2 + normalized.x * travelX,
            y: topLimit + tileSize.height / 2 + normalized.y * travelY
        )
    }

    private var me: MeetingUser {
        if let local = viewModel.localUser {
            return local
        }
        // 入会握手的前 350ms 里 localUser 还不存在；给一个稳定的占位，
        // 避免小窗在这段时间突然消失或变成空白。
        return MeetingUser(
            id: "local-me",
            name: "我",
            role: .participant,
            isMicOn: viewModel.isMicOn,
            isCameraOn: viewModel.isCameraOn,
            isHandRaised: false,
            isSpeaking: false,
            isLocal: true,
            avatarColorIndex: 0
        )
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // 只用来把坐标系铺满容器：它是透明的，且必须关闭命中测试。
            // 这一层如果参与命中，小窗就会带着一整个全屏的拖拽区，底栏/画布的点击会被吞掉。
            Color.clear
                .allowsHitTesting(false)

            // 手势挂在窗口本体上、且在 .position 之前：
            // .position 会返回一个"铺满父容器"的布局容器，在手势加到它之后
            // 容易出现命中区被放大到整屏的问题（V3）。
            //
            // 动画也必须挂在 `.position` **之前**：iOS 14 上 animationCompat 退化成
            // `.animation(_:)`，它作用整棵子树；挂在最外层会把拖拽过程中每一帧的 position
            // 也套上弹簧，小窗变成"追着手指跑"的橡皮筋。
            windowBody
                .animationCompat(Theme.Motion.standard, value: isDragging)
                .animationCompat(Theme.Motion.standard, value: viewModel.isScreenSharing)
                .position(resolvedPosition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.isScreenSharing) { sharing in
            // 开始共享后统一回到右下角，避免正好压住共享内容的主体。
            if sharing {
                withAnimation(Theme.Motion.standard) {
                    normalized = CGPoint(x: 1, y: 1)
                }
            }
        }
        .onChange(of: containerSize) { _ in
            // 旋转 / 分屏后行程变了，归一化值本身没变，但需要重新夹一次防止极端值。
            normalized = clamped(normalized)
        }
    }

    // MARK: - 窗口本体

    /// 真正的小窗。命中区由 contentShape 显式限定成圆角矩形本身。
    private var windowBody: some View {
        preview
            .frame(width: tileSize.width, height: tileSize.height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.tileRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.tileRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            // 拖动时轻微放大 + 阴影加深，给出"被拿起来了"的物理感。
            .scaleEffect(isDragging ? 1.03 : 1.0)
            .opacity(viewModel.isScreenSharing ? 0.9 : 1.0)
            .shadow(
                color: Color.black.opacity(isDragging ? 0.55 : 0.35),
                radius: isDragging ? 18 : 10,
                y: 6
            )
            // 不给 contentShape 的话，命中区取决于内部各层的绘制范围，
            // 拖动/点击在边角上会时灵时不灵。
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.tileRadius, style: .continuous))
            .allowsHitTesting(true)
            .gesture(dragGesture)
            .onTapGesture {
                Haptics.impact(.light)
                viewModel.switchCamera()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("本地画面，点按切换摄像头，拖动调整位置")
    }

    // MARK: - 预览内容

    private var preview: some View {
        ZStack {
            Color.black
            // 真实链路：本地摄像头预览（RTCCameraPreviewView）。
            if let localView = viewModel.localPreviewView {
                RemoteVideoViewRepresentable(view: localView)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            } else {
                placeholderPreview
            }

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("我")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(Capsule().fill(Color.black.opacity(0.45)))

                    Spacer(minLength: 0)
                }
                .padding(6)

                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    Spacer(minLength: 0)

                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.5))
                            .frame(width: 22, height: 22)

                        Image(systemName: viewModel.isMicOn
                            ? SymbolCompat.name("mic.fill")
                            : SymbolCompat.name("mic.slash.fill", "mic.slash"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(
                                viewModel.isMicOn ? Theme.Palette.textPrimary : Theme.Palette.danger
                            )
                    }
                }
                .padding(6)
            }
        }
    }

    /// Mock / 摄像头关闭时的占位画面。
    private var placeholderPreview: some View {
        ZStack {
            // 深色底 + 蓝紫 0.35 渐变：纯半透明渐变会让背后的视频透上来，
            // 小窗里的头像与文字会随画面明暗忽隐忽现。
            Theme.Palette.tileBackground

            LinearGradient(
                colors: [
                    Theme.Palette.accent.opacity(0.35),
                    Theme.Palette.violet.opacity(0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.white.opacity(0.14), Color.clear],
                center: UnitPoint(x: 0.32, y: 0.18),
                startRadius: 2,
                endRadius: 190
            )

            if !viewModel.isCameraOn {
                Color.black.opacity(0.28)
            }

            AvatarView(
                user: me,
                size: tileSize.width * 0.46,
                showsSpeakingRing: false
            )
            .shadow(color: Color.black.opacity(0.28), radius: 8, y: 4)
        }
    }

    // MARK: - 拖拽

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                }
                if dragStart == nil {
                    dragStart = normalized
                }
                guard let start = dragStart else { return }

                // 位移换算成归一化增量：除以行程，保证在不同屏幕尺寸下手感一致。
                let deltaX = travelX > 0 ? value.translation.width / travelX : 0
                let deltaY = travelY > 0 ? value.translation.height / travelY : 0

                normalized = clamped(
                    CGPoint(x: start.x + deltaX, y: start.y + deltaY)
                )
            }
            .onEnded { _ in
                dragStart = nil
                isDragging = false

                // 松手吸附到最近的左右边缘（大厂产品的既定行为，避免窗停在画面中间）。
                let targetX: CGFloat = normalized.x < 0.5 ? 0 : 1
                withAnimation(Theme.Motion.standard) {
                    normalized = CGPoint(x: targetX, y: normalized.y)
                }
            }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
    }
}

struct LocalVideoFloatingView_Previews: PreviewProvider {
    static var previews: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.Palette.background
                LocalVideoFloatingView(
                    viewModel: MeetingViewModel(),
                    containerSize: proxy.size,
                    topInset: 47,
                    bottomInset: 34
                )
            }
        }
        .preferredColorScheme(.dark)
    }
}
