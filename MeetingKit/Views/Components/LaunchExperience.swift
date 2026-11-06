//
//  LaunchExperience.swift
//  MeetingKit
//
//  启动动画 + 品牌标记。
//
//  ── 为什么要自己做一个启动覆盖层 ────────────────────────────────────
//  系统 LaunchScreen 只能放一张静态图，从它切到 SwiftUI 首帧时，
//  底色如果有 1% 的色差就会"闪一下"。更糟的是首页首帧通常是空的
//  （等鉴权 + 拉列表），用户看到的是"白屏 → 突然满屏内容"。
//  这一层做的事只有一件：**把这段空窗期变成有节奏的过渡**。
//
//  ── 时间轴 ────────────────────────────────────────────────────────
//    0.00s  底光淡入，品牌标记从 0.86 弹到 1（欠阻尼，有一次轻微过冲）
//    0.10s  文字上浮 10pt 淡入
//    0.86s  整层开始退出：放大到 1.05 + 淡出（像镜头向前推走）
//    1.20s  移除，回调 onFinish
//  总时长 1.2s 是刻意的：短于 0.8s 用户看不清品牌，长于 1.4s 就是在拖时间。
//  点击任意位置可立即跳过——启动动画永远不该成为"必须等待"。
//
//  ── Reduce Motion ────────────────────────────────────────────────
//  不做缩放与位移，只做 0.18s 淡入淡出，总时长压到 0.6s。
//

import SwiftUI

// MARK: - 品牌标记

/// 天穹的品牌标记：品牌渐变圆角方块 + 白色摄像机轮廓。
///
/// 单独抽出来是因为它会出现在三个地方（启动层、登录页、侧边栏），
/// 三处手写会让圆角/渐变角度/图标比例各差一点，一眼能看出不是同一个 logo。
struct BrandMark: View {

    var size: CGFloat = 56
    /// 图标相对边长的比例。0.46 是按 64pt 视觉重心调出来的，不是随便取的。
    var iconRatio: CGFloat = 0.46

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
            .fill(Theme.Palette.brandGradient)
            .frame(width: size, height: size)
            .overlay(
                // 上缘一道 1px 高光：纯渐变块是"贴纸"，有这道边才是"物体"。
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.55), Color.white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(
                Image(systemName: "video.fill")
                    .font(.system(size: size * iconRatio, weight: .semibold))
                    .foregroundColor(.white)
            )
            .shadow(color: Theme.Palette.accent.opacity(0.28), radius: size * 0.22, x: 0, y: size * 0.10)
            .accessibilityHidden(true)
    }
}

// MARK: - 启动层

struct LaunchOverlay: View {

    var onFinish: () -> Void

    @State private var markScale: CGFloat = 0.86
    @State private var markOpacity: Double = 0
    @State private var wordOpacity: Double = 0
    @State private var wordOffset: CGFloat = 10
    @State private var glowOpacity: Double = 0
    @State private var exiting = false
    @State private var finished = false

    var body: some View {
        ZStack {
            Theme.Palette.background
                .ignoresSafeArea()

            // 中心一团品牌冷光。半径给到 0.9 屏宽，慢慢衰减，
            // 这样它不会是一个可见的圆，而像"房间里的灯亮起来"。
            GeometryReader { geo in
                RadialGradient(
                    colors: [
                        Theme.Palette.accent.opacity(0.16),
                        Theme.Palette.violet.opacity(0.06),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.62
                )
            }
            .ignoresSafeArea()
            .opacity(glowOpacity)
            .allowsHitTesting(false)

            VStack(spacing: 20) {
                BrandMark(size: 68)
                    .scaleEffect(GlassMotion.scale(markScale))
                    .opacity(markOpacity)

                VStack(spacing: 6) {
                    Text("天穹会议")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink)
                        .kerning(0.4)

                    Text("把会开在屏幕里")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Palette.ink3)
                        .kerning(1.6)
                }
                .opacity(wordOpacity)
                .offset(y: wordOffset)
            }
            .offset(y: -18)
        }
        .opacity(exiting ? 0 : 1)
        .scaleEffect(exiting ? GlassMotion.scale(1.05) : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .onAppear(perform: run)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("天穹会议正在启动")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: 时间轴

    private func run() {
        if GlassMotion.isReduceMotion {
            withAnimation(.linear(duration: 0.18)) {
                markOpacity = 1
                wordOpacity = 1
                glowOpacity = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { finish() }
            return
        }

        withAnimation(.easeOut(duration: 0.30)) {
            glowOpacity = 1
        }

        withAnimation(GlassMotion.press.delay(0.02)) {
            markOpacity = 1
            markScale = 1
        }

        withAnimation(GlassMotion.enter.delay(0.10)) {
            wordOpacity = 1
            wordOffset = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.86) { finish() }
    }

    /// 退出。可以被点击提前触发，所以必须幂等——重复调用不能回调两次，
    /// 否则首页会收到两次"启动结束"，转场会跳帧。
    private func finish() {
        guard !finished else { return }
        finished = true

        withAnimation(GlassMotion.exit) {
            exiting = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + (GlassMotion.isReduceMotion ? 0.20 : 0.34)) {
            onFinish()
        }
    }
}

// MARK: - 预览

struct LaunchOverlay_Previews: PreviewProvider {
    static var previews: some View {
        LaunchOverlay(onFinish: {})
    }
}
