//
//  GlassSheet.swift
//  MeetingKit
//
//  自绘底部抽屉。
//
//  为什么不用系统的 `.sheet` + `.presentationDetents`：
//  那套 API 是 iOS 16 起，而本项目 baseline 已经降到 iOS 14；而且会议界面要求
//  "面板只盖住下半屏、上半屏还能看到对方画面"，系统 sheet 会把整屏压暗到几乎不可用。
//  自绘抽屉还能做到 0.34 spring 的统一手感、拖拽条、以及键盘弹起时的自定义位移。
//

import Combine
import SwiftUI
import UIKit

// MARK: - 档位

enum GlassSheetDetent {
    case medium
    case large

    /// 相对可用高度（安全区内）的比例。大档位刻意留出顶部 12%，
    /// 让用户始终能瞥见一眼视频画面，不会觉得"界面被抢走了"。
    /// 中档从 0.52 提到 0.58：0.52 时参会人面板只剩三四行可视区域，滚动感太强。
    var heightRatio: CGFloat {
        switch self {
        case .medium:
            return 0.58
        case .large:
            return 0.88
        }
    }
}

// MARK: - 抽屉

struct GlassSheet<Content: View>: View {

    var detent: GlassSheetDetent

    /// 由调用方注入（根视图的 safeAreaInsets.bottom）。
    /// 嵌套的 GeometryReader 拿不到窗口级安全区，所以这里不自己读。
    var bottomInset: CGFloat

    var onClose: () -> Void
    var content: () -> Content

    @State private var currentDetent: GlassSheetDetent
    @State private var dragTranslation: CGFloat = 0
    @State private var keyboardHeight: CGFloat = 0
    /// 进场动画用：首帧放在屏幕下方，onAppear 再抬上来。
    @State private var isVisible = false

    init(
        detent: GlassSheetDetent = .medium,
        bottomInset: CGFloat = 0,
        onClose: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.detent = detent
        self.bottomInset = bottomInset
        self.onClose = onClose
        self.content = content
        _currentDetent = State(initialValue: detent)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // 遮罩只盖住画面、不参与布局；点它等于关闭。
            //
            // 透明度跟着下拉位移走：往下拖到一半时遮罩已经淡掉一半，
            // 视觉上"面板正在离开、底下的会议正在回来"。
            // 固定 0.45 不动的写法会让下拉过程像在拖一块盖着黑布的门。
            Color.black.opacity(dimOpacity)
                .ignoresSafeArea()
                .animation(isVisible ? nil : GlassMotion.exit, value: isVisible)
                .onTapGesture {
                    onClose()
                }

            GeometryReader { proxy in
                // 面板总高（含底部安全区补偿）。键盘弹起时靠"压缩高度"让出空间，
                // 而不是把整块面板平移到屏幕外，推导写在 panelHeight(containerHeight:)。
                let height = panelHeight(containerHeight: proxy.size.height)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    // 位移分两层，动画的归属也分两层：
                    //   ① 这一层（拖拽）**禁动画**，② 下一层（进场/键盘）**吃动画**。
                    panel(height: height)
                        // ① 拖拽位移层：唯一被显式清掉动画的一层。
                        //    iOS 14 没有 `.animation(_:value:)`，外层 withAnimation 会作用整棵子树，
                        //    拖拽时每一帧 offset 都被套上弹簧 → 面板追着手指跑（橡皮筋感）。
                        //    用 transaction 清掉后：拖拽 0 延迟。
                        //
                        //    缩放与位移同一层、同一个 transaction：下拉时整块面板
                        //    轻微缩小（最多 8%），像被从桌面上"抽走"而不是平移出去。
                        //    锚点必须在 .bottom，从中心缩会让面板两侧同时往里收，很怪。
                        .scaleEffect(panelScale, anchor: .bottom)
                        .offset(y: dragTranslation)
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                        // ② 静止位移层：在 transaction 之外，继续吃 withAnimation 的过渡。
                        //    注意这一层只负责"底边贴到键盘顶"，不负责让顶部出屏——
                        //    顶部是否可见由 ① 内侧 panel() 里的高度压缩保证。
                        .offset(y: restingOffset(height: height))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            withAnimation(Theme.Motion.standard) {
                isVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            let height = frame?.height ?? 0
            withAnimation(Theme.Motion.standard) {
                keyboardHeight = height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(Theme.Motion.standard) {
                keyboardHeight = 0
            }
        }
    }

    // MARK: - 面板本体

    private func panel(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            dragStrip

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 先给内容留出 home indicator 的高度，再定总高，这样内容不会被圆角切掉。
        .padding(.bottom, bottomInset)
        .frame(height: height)
        // 动画按属性拆开：只有「高度」这一层吃动画，拖拽位移那一层仍然被 transaction 关掉。
        //   · 换档位（0.58 ⇄ 0.88）改的就是 height → 走 Theme.Motion.standard，不再瞬跳；
        //   · 键盘压缩改的也是 height → 同一条曲线，与"底边贴键盘顶"的位移同步；
        //   · 拖拽改的是外层 offset，不在这一层，依旧 0 延迟。
        // 这个修饰符必须放在 panel() **内部**（比 `.offset`/`.transaction` 更内层）：
        // 放外层的话它会连拖拽 offset 一起接管，橡皮筋感就回来了。
        //
        // value 用 height 而不是 currentDetent：键盘弹起/收起同样只改 height，
        // 一个 `value:` 就能覆盖两种来源；两个 `.animation(_:value:)` 叠在同一个节点上时，
        // 后一个会把前一个设好的 transaction 再改写一次，容易其中一种变化被吞掉。
        .animationCompat(Theme.Motion.standard, value: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.panelRadius, style: .continuous))
        // 面板是这一整套界面里面积最大的一块玻璃，但刻意**不用** tinted：
        // 着色玻璃只用来表达状态（共享中红、选中蓝），大面积着色会让整块界面发闷。
        .liquidGlass(
            .regular,
            cornerStyle: .continuous(Theme.Metrics.panelRadius),
            castsShadow: true
        )
    }

    /// 顶部把手条：拖拽关闭 + 右上角关闭键。
    ///
    /// ── 为什么必须补一个 ✕ ────────────────────────────────────────────
    /// 用户反馈"诊断面板把底栏全挡住了，而且怎么都划不下去"。原因不是手势写错，
    /// 而是**手势只挂在这条 36pt 的把手条上**：诊断/聊天/参会人面板的主体都是
    /// ScrollView，手指落在文字上往下拖，事件被滚动视图吃掉，抽屉一动也不动。
    /// 把手条又只有 4pt 的胶囊看得见，用户根本不知道该抓哪里。
    /// 所以这里做两件事：
    ///   1. 把手条加高到 44pt，整条（含两侧留白）都是可拖区域；
    ///   2. 右上角给一个明确的 ✕ —— 手势可以学，按钮不需要学。
    /// 关闭键放在把手条里而不是各面板内部：所有面板共用一条退出路径，
    /// 新加面板不会因为忘写关闭而再次变成"关不掉的弹窗"。
    private var dragStrip: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 40, height: 4)
                    .padding(.top, 11)
                    .padding(.bottom, 9)

                Color.clear.frame(height: 20)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture)

            Button {
                Haptics.impact(.light)
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.Palette.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .contentShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 10)
            .padding(.top, 8)
            .accessibilityLabel("关闭")
        }
        .frame(maxWidth: .infinity)
        // 顶部高光：面板上沿那道自上而下衰减的亮边。
        // 玻璃感有一半来自这条边——没有它，面板在亮画面上就是一块灰板。
        // 用「视图参数」版本的 background（iOS 13 就有），闭包版是 15 起。
        .background(topHighlight, alignment: .top)
    }

    /// 只在上沿 34pt 内衰减到透明，与面板圆角一起被外层 clipShape 裁掉。
    private var topHighlight: some View {
        LinearGradient(
            colors: [Color.white.opacity(0.10), Color.clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 34)
    }

    // MARK: - 下拉联动

    /// 下拉进度（0~1）。260pt 视为"完全拉走"的距离，
    /// 与 dragGesture 里 120pt 触发关闭的阈值不冲突：阈值是**决定**，
    /// 这里是**过程**，手指还没松的时候遮罩和缩放就已经在跟着走了。
    private var dragProgress: CGFloat {
        min(max(dragTranslation, 0) / 260, 1)
    }

    /// 遮罩透明度：0.45 → 0.05。
    private var dimOpacity: Double {
        Double(0.45 * (1 - dragProgress * 0.88))
    }

    /// 面板缩放：下拉时最多缩到 0.92。
    ///
    /// 这里刻意**不做**进场缩放（0.97 → 1）：这一层被 `.transaction` 关掉了动画，
    /// 缩放会瞬跳 3%，反而是一次看不见理由的抖动。进场交给下方的位移层负责，
    /// 位移有 60% 屏高的行程，本身已经足够"被拉起来"。
    private var panelScale: CGFloat {
        GlassMotion.scale(1 - dragProgress * 0.08)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let translation = value.translation.height
                // 向上拖拽只给 60pt 的阻尼反馈：再往上没有更多档位，不能让面板飞出去。
                dragTranslation = translation < 0 ? max(translation, -60) : translation
            }
            .onEnded { value in
                let translation = value.translation.height

                if translation > 120 {
                    dragTranslation = 0
                    onClose()
                    return
                }

                withAnimation(Theme.Motion.standard) {
                    if translation < -60 {
                        currentDetent = .large
                    } else if translation > 60, case .large = currentDetent {
                        currentDetent = .medium
                    }
                    dragTranslation = 0
                }
            }
    }

    /// 未进场时整体沉到屏幕下方；进场后负责"安全区 + 键盘"这段可动画的位移。
    /// 拖拽位移由另一层 `.offset(y: dragTranslation)` 承担（那一层关掉了动画）。
    ///
    /// 为什么这里**仍然**要减 `keyboardHeight`（而不是像"只压缩高度"那样回到纯 bottomInset）：
    /// 父视图挂了 `.ignoresSafeArea(.keyboard)`，系统不会再避让，面板自身的底边就是唯一的参照。
    /// 若底边留在屏幕物理底，面板最后一行（ChatPanel 的 TextField）会整块落到键盘下面，
    /// 键盘弹起就再也输入不了字——那是比"顶部出屏"更严重的退化。
    /// 所以分工是：**这一层负责底边贴到键盘顶，panelHeight() 负责顶边不出屏**。
    private func restingOffset(height: CGFloat) -> CGFloat {
        guard isVisible else { return height }
        return bottomInset - keyboardHeight
    }

    // MARK: - 高度

    /// 面板顶部至少留出的高度。
    /// 拖拽条本体只有 4pt，但它的可点区域是整条 36pt 的 dragStrip；再算上圆角与顶部高光，
    /// 留 96pt 才能保证"键盘弹起后拖拽条还看得见、点得到"，遮罩也露出够大一块给点击关闭。
    /// 泛型类型不支持 static 存储属性，这里用实例计算属性等价表达。
    private var minimumTopMargin: CGFloat { 96 }

    /// 面板总高（含底部安全区补偿）。
    ///
    /// 坐标系推导（本视图 GeometryReader 内，y = 0 是安全区顶，H = 容器高）：
    ///   1. 面板贴底时底边在 y = H；`.offset(y: bottomInset)` 把它落到屏幕物理底。
    ///   2. 键盘弹起时底边要贴在键盘顶：y = H + bottomInset − keyboardHeight（由 restingOffset 负责）。
    ///   3. 只做位移是不够的：0.88 档高度是 0.88H，整块上移 keyboardHeight 后
    ///      顶边 = H − 0.88H − keyboardHeight，iPhone 14 上 = 0.12×763 − 336 = −244，直接出屏。
    ///   4. 设面板总高 h、可见高度 X（h = X + bottomInset，因为 panel() 内已有等量 bottom padding），
    ///      则顶边 y = (H + bottomInset − keyboardHeight) − h = H − X − keyboardHeight。
    ///   5. 要求顶边 ≥ 96：
    ///         H − X − keyboardHeight ≥ 96
    ///      ⇒  X ≤ H − keyboardHeight − 96
    ///      键盘收起时 keyboardHeight = 0，退化成 X ≤ H − 96（与原来"大档留 12% 顶部"兼容）。
    ///   6. 在满足上式的前提下取档位高度：
    ///         X = min(档位高度, H − keyboardHeight − 96)，并夹到 ≥ 0。
    ///
    /// 例（iPhone 14：H = 763、bottomInset = 34、键盘 336）：
    ///   X = min(763 × 0.88 = 671.4, 763 − 336 − 96 = 331) = 331
    ///   顶边 = 763 − 331 − 336 = 96 ✔；面板总高 = 331 + 34 = 365。
    ///
    /// - Parameter containerHeight: GeometryReader 给出的安全区内可用高度。
    /// - Returns: 面板总高，已包含底部安全区补偿，可直接喂给 `.frame(height:)`。
    private func panelHeight(containerHeight: CGFloat) -> CGFloat {
        let detentHeight = containerHeight * currentDetent.heightRatio
        let maxVisibleHeight = containerHeight - keyboardHeight - minimumTopMargin
        // min 保证顶边不被推出屏幕；max(0,...) 兜住"键盘比可用高度还高"的极端情况
        // （iPad 分屏 + 外接键盘），此时面板退化成只剩底部一个薄片，但不会翻负。
        let visibleHeight = max(0, min(detentHeight, maxVisibleHeight))
        return visibleHeight + bottomInset
    }
}

// MARK: - 预览

struct GlassSheet_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.tileBackground
            GlassSheet(detent: .medium, onClose: {}) {
                VStack {
                    Text("面板内容")
                        .font(Theme.Typography.sectionTitle)
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding()
            }
        }
        .preferredColorScheme(.dark)
    }
}
