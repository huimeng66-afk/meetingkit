//
//  TopStatusBar.swift
//  MeetingKit
//
//  会议室顶栏（52 + topInset）+ 共享警示条（32）。
//
//  布局要点：
//    1. 左侧三个 36pt 按钮、右侧结束/离开胶囊都画在 ZStack 的两端，
//       中间标题块单独居中（不是 HStack 里用 Spacer 挤出来的"伪居中"）。
//       这样无论右侧胶囊多宽，标题的视觉中心都落在屏幕中线上。
//    2. 警示条在顶栏**下方**，不是上方：顶栏已经含 topInset，
//       红条放在下面就不会顶到灵动岛，同时天然铺满左右安全区。
//    3. 顶栏玻璃是整条 Rectangle，包含状态栏区域；底部只补 1px 描边，
//       不画圆角——通栏顶栏一旦有圆角，刘海两侧会露出底色，像没铺满。
//

import SwiftUI

struct TopStatusBar: View {

    @ObservedObject var viewModel: MeetingViewModel

    /// 根视图 `GeometryReader.safeAreaInsets.top`。
    var topInset: CGFloat = 0

    /// 主持人点"结束"：由房间层弹 GlassConfirmDialog。
    var onEndMeetingRequest: () -> Void = {}

    /// 非主持人点"离开"：直接回首页，不结束整场会议。
    var onLeaveRequest: () -> Void = {}

    /// 顶栏整条高度（含安全区与共享条）。房间层用它决定画布的安全边距。
    private var totalHeight: CGFloat {
        topInset + 52 + (viewModel.isShareBannerVisible ? 32 : 0)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                statusRow(width: proxy.size.width)

                if viewModel.isShareBannerVisible {
                    sharingBanner
                }
            }
        }
        .frame(height: totalHeight)
    }

    // MARK: - 状态栏

    private func statusRow(width: CGFloat) -> some View {
        ZStack {
            titleBlock(width: width)

            HStack(spacing: 0) {
                leadingControls
                Spacer(minLength: 0)
                trailingAction
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .padding(.top, topInset)
        .frame(maxWidth: .infinity)
        .liquidGlass(.regular, in: Rectangle())
        .overlay(bottomHairline, alignment: .bottom)
    }

    /// 1px 底边。玻璃没有这条线时，顶栏和画布会糊成一块。
    private var bottomHairline: some View {
        Rectangle()
            .fill(Theme.Palette.glassStroke)
            .frame(height: 1)
    }

    // MARK: - 左三键

    private var leadingControls: some View {
        HStack(spacing: 2) {
            iconButton(
                symbol: SymbolCompat.name(
                    "arrow.down.right.and.arrow.up.left",
                    "rectangle.compress.vertical",
                    "arrow.down.right.and.arrow.up.left"
                ),
                label: "收起控件"
            ) {
                withAnimation(Theme.Motion.standard) {
                    viewModel.isChromeVisible = false
                }
                viewModel.showToast(
                    ToastMessage(
                        text: "已收起控件，点击画面恢复",
                        systemImage: "rectangle.compress.vertical",
                        style: .info
                    )
                )
            }

            iconButton(
                symbol: SymbolCompat.name(
                    viewModel.isSpeakerOn ? "speaker.wave.2.fill" : "ear",
                    "speaker.wave.2.fill",
                    "speaker.wave.2"
                ),
                label: viewModel.isSpeakerOn ? "切换到听筒" : "切换到扬声器"
            ) {
                viewModel.isSpeakerOn.toggle()
                let enabled = viewModel.isSpeakerOn
                viewModel.showToast(
                    ToastMessage(
                        text: enabled ? "已切换为扬声器" : "已切换为听筒",
                        systemImage: enabled ? "speaker.wave.2.fill" : "ear",
                        style: .info
                    )
                )
            }

            iconButton(
                symbol: layoutButtonSymbol,
                label: "切换视图"
            ) {
                viewModel.toggleLayout()
            }
        }
    }

    /// 图标展示"点下去会切到哪种布局"：当前宫格 → 显示单人图标。
    private var layoutButtonSymbol: String {
        if case .grid = viewModel.layoutMode {
            return SymbolCompat.name("person.fill", "person.crop.circle")
        }
        return SymbolCompat.name("rectangle.split.2x2", "square.grid.2x2", "rectangle.grid.1x2")
    }

    private func iconButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.Palette.textPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().stroke(Theme.Palette.glassStroke, lineWidth: 1))
                // 44pt 外扩命中区：视觉 36，触控 44，满足 HIG 最小触控尺寸。
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(ControlButtonPressStyle())
        .accessibilityLabel(label)
    }

    // MARK: - 中间会议信息

    private func titleBlock(width: CGFloat) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Text(viewModel.roomTitle)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if viewModel.isLocked {
                    Image(systemName: SymbolCompat.name("lock.fill", "lock"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.Palette.warning)
                        .accessibilityLabel("会议已锁定")
                }

                // 企业专属会议室：标题后挂一个企业名小胶囊。
                // 普通会议 meetingBrand.isEnterprise 为 false，这里完全不占位。
                if viewModel.meetingBrand.isEnterprise,
                   !viewModel.meetingBrand.enterpriseName.isEmpty {
                    Text(viewModel.meetingBrand.enterpriseName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.Palette.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(Theme.Palette.accent.opacity(0.16))
                        )
                        .accessibilityLabel("企业会议室：\(viewModel.meetingBrand.enterpriseName)")
                }
            }
            .lineLimit(1)

            if isConnected {
                Text(viewModel.durationText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Theme.Palette.textSecondary)
            } else {
                ReconnectingLabel()
            }

            // 375pt 的屏幕扣掉左右按钮后，第三行只有一百点出头，
            // 再放会议号会把三行都挤花；这里按设计规范的宽度门槛隐藏。
            if width >= 340 {
                HStack(spacing: 3) {
                    Image(systemName: SymbolCompat.name("number", "number.circle"))
                        .font(.system(size: 8, weight: .semibold))
                    Text(viewModel.meetingBrand.isEnterprise
                         ? "\(viewModel.formattedMeetingNumber) · \(viewModel.meetingBrand.modeText)"
                         : viewModel.formattedMeetingNumber)
                        .font(.system(size: 10).monospacedDigit())
                }
                .foregroundColor(Theme.Palette.textTertiary)
                .lineLimit(1)
            }
        }
        // 给左右控件留出硬边界：标题再长也只能在自己的中段里缩放/截断。
        .frame(maxWidth: max(60, width - 244))
    }

    private var isConnected: Bool {
        if case .connected = viewModel.connectionState {
            return true
        }
        return false
    }

    // MARK: - 右侧结束 / 离开

    private var trailingAction: some View {
        Button {
            Haptics.impact(.medium)
            if viewModel.isCurrentUserHost {
                onEndMeetingRequest()
            } else {
                onLeaveRequest()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: SymbolCompat.name("phone.down.fill", "phone.down"))
                    .font(.system(size: 12, weight: .semibold))

                Text(viewModel.isCurrentUserHost ? "结束" : "离开")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                Capsule().fill(
                    viewModel.isCurrentUserHost
                        ? Color(hex: 0xF0510F)
                        : Theme.Palette.danger
                )
            )
        }
        // 视觉胶囊 30 高，外层 44 命中区满足 HIG。
        .frame(height: 44)
        .contentShape(Rectangle())
        .buttonStyle(ControlButtonPressStyle())
        .accessibilityLabel(viewModel.isCurrentUserHost ? "结束会议" : "离开会议")
    }

    // MARK: - 共享警示条

    /// 共享条对本机/远端两种共享同时生效。
    ///
    /// 只在本机共享时显示，是之前最明显的一处信息缺失：别人共享时用户看到画面
    /// 突然变成 PPT，顶栏却仍是普通状态，既不知道是谁在共享，也不知道怎么退出观看。
    /// 远端共享时右侧不放"停止"——停止别人的共享既没有权限，也没有语义。
    private var sharingBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: SymbolCompat.name(
                "rectangle.inset.filled.and.person.filled",
                "rectangle.on.rectangle",
                "rectangle.fill.on.rectangle.fill"
            ))
                .font(.system(size: 12, weight: .semibold))

            Text(viewModel.shareBannerText)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Text(viewModel.shareBannerDurationText)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .opacity(0.9)

            Spacer(minLength: 8)

            if viewModel.isScreenSharing {
                Button {
                    Haptics.impact(.light)
                    viewModel.stopScreenShare()
                } label: {
                    Text("停止共享")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("停止共享屏幕")
            } else {
                Text("观看中")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        // 设计稿指定 #FF453A：比 danger 更亮，红色通栏在深空蓝上必须足够刺眼。
        // 远端共享用同一底色：这条横幅表达的是"有一块屏幕正在被全場看到"，
        // 不是"你正在做危险操作"；换成蓝色会让人以为是普通提示，反而看不到。
        .background(Color(hex: 0xFF453A))
    }
}

// MARK: - 重连小字

/// 独立的呼吸子视图：连接状态变化时它会被插入/移除，
/// onAppear 的延时启动因此每次都能重新触发循环动画。
private struct ReconnectingLabel: View {

    @State private var breathing = false

    var body: some View {
        Text("重连中…")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.Palette.warning)
            .opacity(breathing ? 0.45 : 1.0)
            .animationCompat(Theme.Motion.breathing, value: breathing)
            .onAppear {
                DispatchQueue.main.async {
                    breathing = true
                }
            }
    }
}

struct TopStatusBar_Previews: PreviewProvider {
    static var previews: some View {
        ZStack(alignment: .top) {
            Theme.Palette.tileBackground
            TopStatusBar(viewModel: MeetingViewModel(), topInset: 47)
        }
        .preferredColorScheme(.dark)
    }
}
