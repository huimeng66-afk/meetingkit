//
//  Skeleton.swift
//  MeetingKit
//
//  骨架屏 —— 加载中不要转圈。
//
//  ── 为什么不用 ProgressView ────────────────────────────────────────
//  系统菊花只在"等待时间 < 1 秒"时合理。首页拉会议列表要过网络 + 鉴权，
//  弱网下 2~3 秒很常见，一颗菊花转三秒，用户会以为卡死。
//  骨架屏把"将要出现什么"提前画出来，等待感会显著变短（HIG 的 loading 建议）。
//
//  ── 扫光的做法 ────────────────────────────────────────────────────
//  一条 18° 倾斜的高光带，在 1.25s 内从左扫到右，线性循环。
//  三个约束：
//    1. 必须 `repeatForever(autoreverses: false)`：往复扫光看起来像呼吸，
//       会让整块列表一明一暗，反而更累；
//    2. 高光带要比骨架块宽（1.6 倍），否则宽卡片上会看到一条细线在跑；
//    3. Reduce Motion 下**不扫光**，只留静态灰块——扫光是持续位移，
//       正是前庭敏感用户最难受的那一类。
//

import SwiftUI

// MARK: - 单块

/// 一块骨架。宽度由外部决定，高度/圆角由参数决定。
struct SkeletonBar: View {

    var height: CGFloat = 12
    var corner: CGFloat = 6
    /// 宽度比例（0~1）。nil 表示撑满。
    var widthRatio: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            let width = widthRatio.map { geo.size.width * $0 } ?? geo.size.width
            ShimmerSurface(corner: corner)
                .frame(width: max(width, 0), height: height)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
    }
}

/// 会扫光的灰块。所有骨架元素的底座。
struct ShimmerSurface: View {

    var corner: CGFloat = 8

    @State private var sweeping = false

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Theme.Palette.hairline.opacity(0.72))
            .overlay(
                GeometryReader { geo in
                    if !GlassMotion.isReduceMotion {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0),
                                Color.white.opacity(0.85),
                                Color.white.opacity(0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 1.6)
                        .rotationEffect(.degrees(16))
                        .offset(x: sweeping ? geo.size.width * 1.1 : -geo.size.width * 1.7)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .onAppear {
                guard !GlassMotion.isReduceMotion else { return }
                // 先让初始 offset 渲染一帧，再开始循环，否则第一次扫光会被吞掉。
                DispatchQueue.main.async {
                    withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                        sweeping = true
                    }
                }
            }
    }
}

// MARK: - 会议列表骨架

/// 首页「我的会议」列表的骨架：3 行，行高与真实卡片一致（64）。
///
/// 尺寸必须和真实行对齐，否则数据到达的瞬间整页会跳一下——
/// 这比"多等半秒"更伤，因为它让人以为点错了。
struct MeetingListSkeleton: View {

    var count: Int = 3

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<max(count, 1), id: \.self) { index in
                HStack(spacing: 12) {
                    // 左侧会议图标位
                    ShimmerSurface(corner: 11)
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBar(height: 12, corner: 6, widthRatio: index == 1 ? 0.44 : 0.58)
                        SkeletonBar(height: 9, corner: 5, widthRatio: 0.30)
                    }

                    Spacer(minLength: 8)

                    ShimmerSurface(corner: 6)
                        .frame(width: 34, height: 18)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.Palette.backgroundElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.Palette.hairline, lineWidth: 1)
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载会议列表")
    }
}

// MARK: - 入会连接骨架

/// 入会页点「加入」之后的等待态：不是菊花，而是"正在建立连接"的三段进度。
///
/// 会议连接有三个真实阶段（信令 → ICE → 首帧），把它们画出来，
/// 用户就知道"卡在哪一步"，而不是只看到一颗转圈。
struct ConnectingTrace: View {

    var stage: Int

    private let labels = ["正在连接服务器", "正在打通媒体通道", "正在接收画面"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(index <= stage ? Theme.Palette.accent : Theme.Palette.hairline)
                            .frame(width: 18, height: 18)

                        if index < stage {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                        } else if index == stage {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.55)
                        }
                    }

                    Text(label)
                        .font(.system(size: 13, weight: index == stage ? .medium : .regular))
                        .foregroundColor(index <= stage ? Theme.Palette.ink : Theme.Palette.ink3)

                    Spacer(minLength: 0)
                }
                .opacity(index <= stage + 1 ? 1 : 0.45)
                .animation(GlassMotion.settle, value: stage)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(labels[min(max(stage, 0), labels.count - 1)])
    }
}

// MARK: - 预览

struct Skeleton_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            BrandBackground()
            VStack(spacing: 24) {
                MeetingListSkeleton()
                ConnectingTrace(stage: 1)
            }
            .padding(24)
        }
    }
}
