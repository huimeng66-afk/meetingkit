//
//  GlassMotion.swift
//  MeetingKit
//
//  动效令牌 —— 全项目动画的唯一出口。
//
//  ── 为什么单独一个文件 ────────────────────────────────────────────
//  Theme.Motion 只管"一条曲线的手感"，回答不了下面这三件事，
//  于是各个视图各写一套 duration/easeInOut，页面之间开始互相打架：
//    · 进场该延迟多少（列表逐条入场要 stagger，弹窗不能等）；
//    · 按下该压到多小、松手要不要过冲（液态透镜的按压是**欠阻尼**的，
//      damping 必须 < 0.7，用 standard 的 0.86 只会"软塌塌地缩一下"）；
//    · 减弱动态（Reduce Motion）打开后该怎么降级。
//  这里把这三件事收成一处，视图只写 `GlassMotion.enter(index: 3)`。
//
//  ── 与 WebGL 参考实现的关系 ────────────────────────────────────────
//  参考工程 `webgl-apple-liquid-glass` 把交互拆成三种物理量：
//    press   —— 按下时玻璃被"压出"边界（pressed lens），阻尼低、回弹明显；
//    drag    —— 跟手位移 1:1，不套弹簧；只有松手吸附才用弹簧；
//    settle  —— 归位，阻尼 0.8 左右，一次到位不过冲。
//  下面三条曲线就是这三者的 SwiftUI 表达。数值按 60fps 手感调过：
//    press   response 0.26 / damping 0.62 —— 明显过冲，像捏了一下水球；
//    settle  response 0.38 / damping 0.82 —— 稳稳归位；
//    enter   response 0.52 / damping 0.86 —— 行程长（14~24pt），要更长响应。
//
//  ── 硬约束 ───────────────────────────────────────────────────────
//  1. 只能用 iOS 13 就有的 API（Animation.spring(response:dampingFraction:)）。
//  2. 所有"循环动画"必须是 linear + repeatForever，弹簧无法形成稳定节奏。
//  3. Reduce Motion 打开时，位移一律降级为纯淡入，不做缩放/位移，
//     否则前庭功能敏感的用户会眩晕（Apple HIG 明确要求）。
//

import SwiftUI
import UIKit

// MARK: - 曲线

enum GlassMotion {

    // MARK: 三条基础曲线

    /// 按下。欠阻尼，松手时有可见的过冲——这是"液态"的来源。
    /// 不要拿它做任何整块面板的进出场：过冲放在大面积的面上会像果冻。
    static let press = Animation.spring(response: 0.26, dampingFraction: 0.62)

    /// 松手归位 / 选中切换。比 Theme.Motion.standard 稍快、稍弹。
    static let settle = Animation.spring(response: 0.38, dampingFraction: 0.82)

    /// 进场。行程 14~24pt 的元素用它。
    static let enter = Animation.spring(response: 0.52, dampingFraction: 0.86)

    /// 退场。退场永远比进场快：用户已经决定离开，不该再等一次回弹。
    static let exit = Animation.easeIn(duration: 0.16)

    /// 形变（宽度拉伸、圆角收敛）。必须和拖拽同帧结束，不能带 spring。
    static let morph = Animation.interactiveSpring(response: 0.3, dampingFraction: 0.8, blendDuration: 0.2)

    // MARK: Stagger

    /// 逐条入场的单步延迟。45ms 是"看得出先后、又不会等到不耐烦"的临界值：
    /// 再小（20ms）在 60fps 上分不出先后，再大（80ms）第 6 条要等 0.4 秒。
    static let staggerStep: Double = 0.045

    /// 逐条入场延迟。最多累计到第 8 条就封顶，否则长列表尾部会等半秒。
    static func staggerDelay(_ index: Int) -> Double {
        Double(min(max(index, 0), 8)) * staggerStep
    }

    /// 带延迟的进场曲线。Reduce Motion 下退化为 0.12s 线性淡入。
    ///
    /// 名字必须带 Stagger：`enter` 已经被上面的 `static let enter` 占用，
    /// Swift 不允许同一类型里出现同名的存储属性与方法（即使签名不同），
    /// 写成 `func enter(index:)` 会直接 "invalid redeclaration" 编译失败。
    static func enterStagger(_ index: Int) -> Animation {
        if isReduceMotion { return .linear(duration: 0.12) }
        return enter.delay(staggerDelay(index))
    }

    /// 面板 / 弹窗的进场：延迟固定 0，交给调用方控制出现时机。
    static var panelEnter: Animation {
        isReduceMotion ? .linear(duration: 0.12) : .spring(response: 0.44, dampingFraction: 0.84)
    }

    // MARK: 无障碍

    /// 系统"减弱动态效果"。每次读都取最新值：用户可能在我们运行期间去设置里改。
    static var isReduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// 位移距离的降级：Reduce Motion 下所有入场位移归零，只保留淡入。
    static func offset(_ distance: CGFloat) -> CGFloat {
        isReduceMotion ? 0 : distance
    }

    /// 缩放的降级：Reduce Motion 下不做缩放。
    static func scale(_ value: CGFloat) -> CGFloat {
        isReduceMotion ? 1 : value
    }
}

// MARK: - 入场修饰器

/// 从下方 14pt 上浮 + 淡入，按 index 依次入场。
///
/// 用法：`card.enterFromBottom(3)`。**必须由容器负责触发时机**
/// （即视图真正出现在屏幕上时才调用），否则被打断的转场会让它提前跑完。
struct EnterFromBottom: ViewModifier {

    var index: Int
    var distance: CGFloat
    /// 外部传入的"是否已进场"。nil 时自己 onAppear 触发。
    ///
    /// 必须显式写 `= nil`：Swift 不会为没有默认值的 Optional 属性
    /// 自动生成 nil 默认参数，漏掉它 `EnterFromBottom(index:distance:)`
    /// 就是缺参编译失败。
    var active: Bool? = nil

    @State private var shown = false

    func body(content: Content) -> some View {
        let visible = active ?? shown

        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : GlassMotion.offset(distance))
            .onAppear {
                guard active == nil else { return }
                // 首帧先以"未进场"渲染，再在下一帧切到进场，
                // 否则 SwiftUI 会把初始值直接当成终值，动画根本不发生。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    withAnimation(GlassMotion.enterStagger(index)) {
                        shown = true
                    }
                }
            }
    }
}

/// 弹窗 / 面板的进场：从 0.94 放大 + 淡入，退场反过来更快。
///
/// 与 `.transition(.scale)` 的区别：这里的缩放锚点固定为**底边**，
/// 底部抽屉是从下往上"长"出来的，从中心缩放会看起来像在屏幕中间爆开。
struct PanelBounce: ViewModifier {

    var isPresented: Bool
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .scaleEffect(
                GlassMotion.scale(isPresented ? 1 : 0.94),
                anchor: anchor
            )
            .animation(
                isPresented ? GlassMotion.panelEnter : GlassMotion.exit,
                value: isPresented
            )
    }
}

// MARK: - 便捷入口

extension View {

    /// 逐条入场。index 从 0 开始。
    func enterFromBottom(index: Int = 0, distance: CGFloat = 14) -> some View {
        modifier(EnterFromBottom(index: index, distance: distance))
    }

    /// 由外部驱动进场的版本（用于"数据到位后整组一起进"）。
    func enterFromBottom(active: Bool, index: Int = 0, distance: CGFloat = 14) -> some View {
        modifier(EnterFromBottom(index: index, distance: distance, active: active))
    }

    /// 面板弹入 / 弹出。
    func panelBounce(_ isPresented: Bool, anchor: UnitPoint = .bottom) -> some View {
        modifier(PanelBounce(isPresented: isPresented, anchor: anchor))
    }
}

// MARK: - 页面转场

extension AnyTransition {

    /// 页面级转场：旧页轻微缩小淡出，新页从 1.02 收进来。
    ///
    /// 为什么不直接用 `.opacity`：整屏交叉淡入会让两层界面同时半透明地叠着，
    /// 中间那 0.1 秒里文字互相穿透，看起来像信号不良。
    /// 加一点点缩放（1.02 → 1）能让"新页面压上来"这件事成立。
    static var pagePush: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 1.02)),
            removal: .opacity.combined(with: .scale(scale: 0.985))
        )
    }
}
