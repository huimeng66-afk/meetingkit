//
//  LiquidGlass.swift
//  MeetingKit
//
//  Liquid Glass 2.0 —— 全项目玻璃材质的唯一实现。
//
//  两条渲染路径：
//    · iOS 26（#if compiler(>=6.2) 整段包裹）：系统 `glassEffect(_:in:)`，
//      自带折射、高光、以及相邻玻璃的吸附融合。
//    · iOS 14~25：五层手写合成（模糊 / 底色 / 镜面高光 / 1px 描边 / 投影）。
//      少叠一层就会退化成"一块半透明色块"，其中最关键的是第 4 层：
//      苹果玻璃的灵魂是"上亮下暗的 1px 边"，没有它，玻璃和视频糊在一起。
//
//  三条硬约束，改这个文件前先读：
//    1. 新 API 只能出现在 `#if compiler(>=6.2)` 里，`#if` 块内的 iOS 26 类型
//       不允许泄漏到块外（老 SDK 上没有 `Glass` 这个符号，泄漏即编译失败）。
//    2. 颜色一律 `colorScheme == .dark ? a : b`，不允许写死 `.dark`：
//       本项目强制深色，但强行写死会在系统深浅切换/分屏投屏时闪一下白块。
//    3. 降级路径要认 `accessibilityReduceTransparency` 与 `LiquidGlassSettings`：
//       前者是无障碍要求，后者是低端机/录屏时的降负载开关。
//

import Combine
import Foundation
import SwiftUI
import UIKit

// MARK: - 变体

/// 玻璃的三档语义。不要按"位置"选，按"这块玻璃要表达什么"选：
/// 常规容器、压在视频上的小控件、正在广播的警示控件。
enum LiquidGlassVariant {

    /// 常规玻璃：面板、顶栏、卡片。
    case regular

    /// 更透：覆盖在视频上的小面积控件（底栏圆钮、浮层小胶囊）。
    /// 面积一大就发灰，所以不允许用于整块面板。
    case clear

    /// 着色玻璃：共享中（红）、选中态（蓝）。
    case tinted(Color)
}

/// 圆角形态。`continuous` 用连续曲率，与 Theme.Metrics 里的圆角一一对应。
enum LiquidGlassCornerStyle {
    case continuous(CGFloat)
    case capsule
    case circle
}

// MARK: - 全局开关

/// 玻璃总开关（UserDefaults 持久化，默认开）。
///
/// 关掉后所有玻璃退化为"实色 + 更强描边"：低端机滚动掉帧、或者要在录屏/投屏里
/// 避免实时模糊带来的额外功耗与摩尔纹时用它。运行期切换需要视图重新求值，
/// 所以 setter 会发一条通知，`LiquidGlassModifier` 收到后触发一次重绘。
enum LiquidGlassSettings {

    static let didChangeNotification = Notification.Name("MeetingKit.LiquidGlassSettings.didChange")

    private static let storageKey = "meetingkit.liquidglass.enabled"

    /// 读不到键时按 true 处理（新装用户默认享受玻璃）。
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: storageKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: storageKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: storageKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}

// MARK: - 模糊层

/// `UIVisualEffectView` 的 SwiftUI 包装。
///
/// 为什么不用 `Material`：`Material` 是 iOS 15 起的 ShapeStyle，
/// baseline 降到 14 之后完全不可用；而 `UIBlurEffect` 从 iOS 13 就在，
/// 且能精确指定 dark/light 变体，比 Material 更可控。
struct VisualEffectBlur: UIViewRepresentable {

    var effectStyle: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: effectStyle))
        // 模糊层只负责视觉，绝不能参与命中测试：
        // 否则底栏圆钮、顶栏按钮的点击会被背景吞掉（症状是"按钮偶尔点不动"）。
        view.isUserInteractionEnabled = false
        view.backgroundColor = UIColor.clear
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: effectStyle)
    }
}

// MARK: - 核心修饰器

/// 把"两套渲染路径 + 降级策略 + 按压反馈"全部关在这一个 ViewModifier 里。
struct LiquidGlassModifier<S: Shape>: ViewModifier {

    var shape: S
    var variant: LiquidGlassVariant
    var isInteractive: Bool
    var castsShadow: Bool
    /// 小圆钮/胶囊用小投影（radius 6 / y 3），大面积面板用大投影（18 / 8）。
    var compactShadow: Bool
    /// 旧 API（glassSurface 系列）传入的自定义色调；nil 表示用 variant 的默认值。
    var tintOverride: Color?
    /// 旧 API 传入的旧描边色，作为内圈补线叠加在新渐变描边之上。
    var strokeOverride: Color?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    /// 按压态。只由 `isInteractive` 的手势驱动，不读 ButtonStyle 的 isPressed。
    @State private var isPressed: Bool = false
    /// 仅用于让总开关变化时触发一次重绘，值本身没有语义。
    @State private var settingsRevision: Int = 0

    init(
        shape: S,
        variant: LiquidGlassVariant = .regular,
        isInteractive: Bool = false,
        castsShadow: Bool = true,
        compactShadow: Bool = false,
        tintOverride: Color? = nil,
        strokeOverride: Color? = nil
    ) {
        self.shape = shape
        self.variant = variant
        self.isInteractive = isInteractive
        self.castsShadow = castsShadow
        self.compactShadow = compactShadow
        self.tintOverride = tintOverride
        self.strokeOverride = strokeOverride
    }

    func body(content: Content) -> some View {
        interactiveBody(glassBody(content))
            // 总开关是静态量，视图不会自动重算；这里订阅一次通知，
            // 收到后改一个 @State 触发重绘（@State 变化一定会让 body 重新求值）。
            .onReceive(NotificationCenter.default.publisher(for: LiquidGlassSettings.didChangeNotification)) { _ in
                settingsRevision &+= 1
            }
    }

    // MARK: 版本分支

    @ViewBuilder
    private func glassBody(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            nativeGlass(content)
        } else {
            compatGlass(content)
        }
        #else
        compatGlass(content)
        #endif
    }

    // MARK: iOS 26 原生路径

    #if compiler(>=6.2)

    /// 原生玻璃已经在系统层做了三件事：背景折射、边缘镜面、以及和相邻玻璃的融合。
    ///
    /// 这里**不再补描边**。之前那圈 1px 渐变白边是我自己画的，它和系统自带的边缘
    /// 高光叠在一起，会在圆角处形成一道死白，整块玻璃立刻从"玻璃"变成"塑料片"。
    /// 投影只在浮在视频上时才给，且压到很轻——苹果自己的浮层几乎不用阴影，
    /// 靠的是玻璃边缘的明暗差，加厚投影会让它看起来像贴纸。
    @available(iOS 26.0, *)
    private func nativeGlass(_ content: Content) -> some View {
        content
            .glassEffect(nativeEffect, in: shape)
            .shadow(
                color: castsShadow ? Color.black.opacity(shadowOpacity) : Color.clear,
                radius: castsShadow ? resolvedShadowRadius : 0,
                x: 0,
                y: castsShadow ? resolvedShadowOffsetY : 0
            )
    }

    /// variant → Glass 的映射。`isInteractive` 用 `.interactive()` 追加"按下形变"，
    /// 这是系统提供的物理反馈，比自己写 scaleEffect 更接近苹果的观感。
    @available(iOS 26.0, *)
    private var nativeEffect: Glass {
        let base: Glass
        switch variant {
        case .regular:
            base = Glass.regular
        case .clear:
            base = Glass.clear
        case .tinted(let color):
            base = Glass.regular.tint(tintOverride ?? color)
        }
        return isInteractive ? base.interactive() : base
    }

    #endif

    // MARK: iOS 14~25 降级路径

    /// 五层合成：模糊 → 底色 → 镜面高光 → 描边 → 投影。
    /// 顺序不能换：先裁再描边，描边才不会被圆角切掉一半。
    private func compatGlass(_ content: Content) -> some View {
        content
            .background(backgroundLayers)
            .clipShape(shape)
            .overlay(shape.stroke(strokeStyle, lineWidth: 1))
            .overlay(legacyStrokeOverlay)
            .shadow(
                color: castsShadow ? Color.black.opacity(shadowOpacity) : Color.clear,
                radius: castsShadow ? resolvedShadowRadius : 0,
                x: 0,
                y: castsShadow ? resolvedShadowOffsetY : 0
            )
    }

    /// 层 1~2：模糊 + 底色。
    ///
    /// 这里原本还有一层 135° 的白色镜面渐变。它在静态截图里看着"有质感"，
    /// 一旦页面滚动、或者压在视频上，就会跟着内容一起晃，观感非常廉价——
    /// 真正的玻璃高光只发生在边缘，不会铺满整个面。删掉后玻璃反而更像玻璃。
    private var backgroundLayers: some View {
        ZStack {
            if usesBlur {
                VisualEffectBlur(effectStyle: blurStyle)
            } else {
                // 降低透明度 / 玻璃总开关关闭：换成实色，绝不留半透明。
                solidSurface
            }

            baseTintColor
        }
    }

    /// 旧 API 的描边色（默认 white 0.08）作为内圈补线，叠在新渐变描边之上。
    /// 默认值几乎不可见，既保住了旧调用方传自定义描边的能力，又不破坏新描边的层次。
    @ViewBuilder
    private var legacyStrokeOverlay: some View {
        if let strokeOverride = strokeOverride {
            shape.stroke(strokeOverride, lineWidth: 1)
        }
    }

    // MARK: 按压反馈

    @ViewBuilder
    private func interactiveBody<V: View>(_ view: V) -> some View {
        if isInteractive {
            view
                .scaleEffect(isPressed ? 0.97 : 1.0)
                .simultaneousGesture(pressGesture)
        } else {
            view
        }
    }

    /// minimumDistance 0 的拖拽 = 触摸按下/抬起的探针。
    /// 用 `simultaneousGesture` 而不是 `gesture`：后者会抢走外层 Button 的点击，
    /// 底栏圆钮就彻底点不动了。
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                withAnimation(Theme.Motion.standard) {
                    isPressed = true
                }
            }
            .onEnded { _ in
                withAnimation(Theme.Motion.standard) {
                    isPressed = false
                }
            }
    }

    // MARK: 渲染令牌

    private var usesBlur: Bool {
        !reduceTransparency && LiquidGlassSettings.isEnabled
    }

    /// `clear` 变体要更透（压在视频上的小控件），所以用更薄的模糊；
    /// 其余用 ultraThin。dark/light 各一套，深浅切换时不会突然变白块。
    private var blurStyle: UIBlurEffect.Style {
        let isDark = colorScheme == .dark
        if isClearVariant {
            return isDark ? .systemThinMaterialDark : .systemThinMaterialLight
        }
        return isDark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight
    }

    private var isClearVariant: Bool {
        if case .clear = variant {
            return true
        }
        return false
    }

    /// 层 2：底色。作用是锁死对比度——会议画面可能是白底 PPT，
    /// 纯模糊会让白字糊掉，必须先压一层。
    ///
    /// 系数从 0.28 / 0.12 收到 0.16 / 0.05：品牌底现在有四团流动光斑，
    /// 压太厚会把光斑全部吃掉，玻璃就退回"灰色圆角块"。收薄之后仍然
    /// 保留一层暗底兜住对比度，但能看见下面的颜色在透。
    private var baseTintColor: Color {
        if let tintOverride = tintOverride {
            return tintOverride
        }
        switch variant {
        case .regular:
            return colorScheme == .dark ? Color.black.opacity(0.16) : Color.white.opacity(0.50)
        case .clear:
            return colorScheme == .dark ? Color.black.opacity(0.05) : Color.white.opacity(0.26)
        case .tinted(let color):
            return color.opacity(0.32)
        }
    }

    /// 模糊关闭时的实色底。必须完全不透明，否则会和下面的视频混成一块脏色。
    private var solidSurface: Color {
        colorScheme == .dark ? Theme.Palette.surface : Theme.Palette.surfaceLight
    }

    /// 层 4：描边。左上亮 → 中段暗 → 右下稍亮，这就是"上亮下暗的 1px 边"。
    /// 降低透明度时整体加亮，弥补没有模糊层后的边界模糊。
    private var strokeStyle: LinearGradient {
        let isDark = colorScheme == .dark
        let boost: Double = reduceTransparency ? 0.15 : 0.0
        let top = min((isDark ? 0.55 : 0.85) + boost, 1.0)
        let mid = isDark ? 0.06 : 0.18
        let bottom = min((isDark ? 0.28 : 0.45) + boost, 1.0)

        return LinearGradient(
            stops: [
                .init(color: Color.white.opacity(top), location: 0.0),
                .init(color: Color.white.opacity(mid), location: 0.5),
                .init(color: Color.white.opacity(bottom), location: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 层 5：投影。深色背景上黑色投影几乎看不见，浅色下要收着来，否则像脏污。
    private var shadowOpacity: Double {
        colorScheme == .dark ? 0.22 : 0.14
    }

    private var resolvedShadowRadius: CGFloat {
        compactShadow ? 5 : 10
    }

    private var resolvedShadowOffsetY: CGFloat {
        compactShadow ? 2 : 4
    }

}

// MARK: - 调用入口

extension View {

    /// 通用写法：适合自定义 Shape（进度环、斜切卡片）。
    func liquidGlass<S: Shape>(
        _ variant: LiquidGlassVariant = .regular,
        in shape: S,
        isInteractive: Bool = false,
        castsShadow: Bool = true
    ) -> some View {
        modifier(
            LiquidGlassModifier(
                shape: shape,
                variant: variant,
                isInteractive: isInteractive,
                castsShadow: castsShadow
            )
        )
    }

    /// 按圆角形态调用。`capsule` / `circle` 自动切到小投影。
    func liquidGlass(
        _ variant: LiquidGlassVariant = .regular,
        cornerStyle: LiquidGlassCornerStyle,
        isInteractive: Bool = false,
        castsShadow: Bool = true
    ) -> some View {
        Group {
            switch cornerStyle {
            case .continuous(let radius):
                liquidGlass(
                    variant,
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous),
                    isInteractive: isInteractive,
                    castsShadow: castsShadow,
                    compactShadow: false
                )
            case .capsule:
                liquidGlass(
                    variant,
                    in: Capsule(),
                    isInteractive: isInteractive,
                    castsShadow: castsShadow,
                    compactShadow: true
                )
            case .circle:
                liquidGlass(
                    variant,
                    in: Circle(),
                    isInteractive: isInteractive,
                    castsShadow: castsShadow,
                    compactShadow: true
                )
            }
        }
    }

    /// 内部重载：多一个 `compactShadow`，供上面的 cornerStyle 分发使用。
    /// 独立成一个重载而不是给公开 API 加默认参数，是为了让公开签名保持最简。
    fileprivate func liquidGlass<S: Shape>(
        _ variant: LiquidGlassVariant,
        in shape: S,
        isInteractive: Bool,
        castsShadow: Bool,
        compactShadow: Bool
    ) -> some View {
        modifier(
            LiquidGlassModifier(
                shape: shape,
                variant: variant,
                isInteractive: isInteractive,
                castsShadow: castsShadow,
                compactShadow: compactShadow
            )
        )
    }

    /// iOS 26 的"玻璃形变"标识：底栏按钮 → 面板这类 morph 过渡靠它把两块玻璃关联起来。
    /// 14~25 上空实现，调用方不需要写版本分支。
    ///
    /// `namespace` 就是 `@Namespace` 声明出来的那个值（`Namespace` 类型 iOS 14 就有），
    /// 因此低版本也能安全地把参数传进来——只是不起作用而已。
    @ViewBuilder
    func liquidGlassID<ID: Hashable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - 容器

/// 玻璃容器。
///
/// iOS 26 上是真正的合并容器（相邻玻璃会互相吸附、融合成一整块）；
/// 14~25 上退化为普通容器，布局完全不变——所以调用方可以无条件使用它，
/// 不需要在业务代码里写版本分支。
struct LiquidGlassContainer<Content: View>: View {

    var spacing: CGFloat
    var content: Content

    init(spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - 按钮样式

/// 玻璃按钮：只保留 0.98 的按压反馈。
///
/// 之前这里有一道从左扫到右的白色高光带——那是 Web 2.0 的写法，放在系统玻璃上
/// 会盖掉玻璃本身的折射，看起来像贴了一层塑料膜。系统 `.interactive()` 已经给了
/// 按下时的形变与亮度变化，这里再做任何叠加都是减分。
struct LiquidGlassButtonStyle: ButtonStyle {

    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .liquidGlass(
                prominent ? .tinted(Theme.Palette.accent) : .regular,
                cornerStyle: .continuous(Theme.Metrics.buttonRadius),
                isInteractive: true,
                castsShadow: false
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animationCompat(Theme.Motion.standard, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LiquidGlassButtonStyle {

    /// 常规玻璃按钮。
    static var liquidGlass: LiquidGlassButtonStyle {
        LiquidGlassButtonStyle()
    }

    /// 主行动按钮（着色玻璃，强调蓝）。
    static var liquidGlassProminent: LiquidGlassButtonStyle {
        LiquidGlassButtonStyle(prominent: true)
    }
}
