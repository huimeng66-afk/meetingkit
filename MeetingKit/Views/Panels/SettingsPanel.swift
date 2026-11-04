//
//  SettingsPanel.swift
//  MeetingKit
//
//  会中设置：视频 / 音频 / 关于。
//
//  这里只做"开关与跳转"，不新增业务：
//    · 虚拟背景、美颜、降噪直接复用 ViewModel 现有的 toggle；
//    · 扬声器/听筒复用新增的 isSpeakerOn；
//    · 昵称与头像属于账号资料，会中不提供编辑入口（避免会议中途改身份）。
//

import SwiftUI

struct SettingsPanel: View {

    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header

                profileHint
                    .padding(.horizontal, Theme.Metrics.horizontal)
                    .padding(.bottom, Theme.Metrics.space3)

                groupTitle("视频")
                groupCard {
                    actionRow(
                        symbol: SymbolCompat.name("arrow.triangle.2.circlepath", "arrow.clockwise"),
                        title: "翻转摄像头",
                        subtitle: viewModel.isFrontCamera ? "当前：前置" : "当前：后置"
                    ) {
                        viewModel.switchCamera()
                    }

                    rowDivider

                    toggleRow(
                        symbol: SymbolCompat.name("person.crop.rectangle", "person.crop.square"),
                        title: "虚拟背景",
                        subtitle: "模糊或替换背景",
                        isOn: virtualBackgroundBinding
                    )

                    rowDivider

                    toggleRow(
                        symbol: SymbolCompat.name("wand.and.stars", "sparkles"),
                        title: "美颜",
                        subtitle: "轻度磨皮与提亮",
                        isOn: beautyBinding
                    )

                    rowDivider

                    toggleRow(
                        symbol: SymbolCompat.name("waveform", "waveform.path"),
                        title: "降噪",
                        subtitle: "抑制键盘与环境噪声",
                        isOn: noiseBinding
                    )
                }
                .padding(.horizontal, Theme.Metrics.horizontal)
                .padding(.bottom, Theme.Metrics.space3)

                groupTitle("音频")
                groupCard {
                    toggleRow(
                        symbol: SymbolCompat.name(
                            viewModel.isSpeakerOn ? "speaker.wave.2.fill" : "ear",
                            "speaker.wave.2.fill"
                        ),
                        title: "扬声器",
                        subtitle: viewModel.isSpeakerOn ? "当前：扬声器外放" : "当前：听筒",
                        isOn: $viewModel.isSpeakerOn
                    )
                }
                .padding(.horizontal, Theme.Metrics.horizontal)
                .padding(.bottom, Theme.Metrics.space3)

                groupTitle("关于")
                groupCard {
                    infoRow(title: "版本", value: "1.0.0")
                    rowDivider
                    infoRow(title: "会议号", value: viewModel.formattedMeetingNumber)
                }
                .padding(.horizontal, Theme.Metrics.horizontal)
                .padding(.bottom, Theme.Metrics.space4)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("设置")
                .font(Theme.Typography.sectionTitle)
                .foregroundColor(Theme.Palette.textPrimary)

            Text("会议中的画面与声音")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space1)
        .padding(.bottom, Theme.Metrics.space3)
    }

    private var profileHint: some View {
        HStack(spacing: 8) {
            Image(systemName: SymbolCompat.name("info.circle.fill", "info.circle"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.Palette.accent)

            Text("在首页修改昵称与头像")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.textSecondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.accent.opacity(0.10))
        )
    }

    // MARK: - 分组

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.Palette.textTertiary)
            .padding(.horizontal, Theme.Metrics.horizontal + 4)
            .padding(.bottom, 6)
    }

    private func groupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .stroke(Theme.Palette.glassStroke, lineWidth: 1)
        )
    }

    // MARK: - 行

    /// 三个画面开关在 ViewModel 里是 private(set)，视图不能直接写；
    /// 这里做只读 get + 调用 toggle 的 set，既保留 Toast，也不扩大 ViewModel 的写入口。
    private var virtualBackgroundBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isVirtualBackgroundOn },
            set: { enabled in
                if enabled != viewModel.isVirtualBackgroundOn {
                    viewModel.toggleVirtualBackground()
                }
            }
        )
    }

    private var beautyBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isBeautyOn },
            set: { enabled in
                if enabled != viewModel.isBeautyOn {
                    viewModel.toggleBeauty()
                }
            }
        )
    }

    private var noiseBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isNoiseSuppressionOn },
            set: { enabled in
                if enabled != viewModel.isNoiseSuppressionOn {
                    viewModel.toggleNoiseSuppression()
                }
            }
        )
    }

    private func actionRow(
        symbol: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            rowContent(symbol: symbol, title: title, subtitle: subtitle) {
                Image(systemName: SymbolCompat.name("chevron.right"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Palette.textTertiary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func toggleRow(
        symbol: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        rowContent(symbol: symbol, title: title, subtitle: subtitle) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Theme.Palette.accent))
                .accessibilityLabel(title)
        }
    }

    private func rowContent<Trailing: View>(
        symbol: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: Theme.Metrics.space3) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))

                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.Palette.textSecondary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.Palette.textPrimary)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Metrics.space2)

            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .contentShape(Rectangle())
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(Theme.Palette.textSecondary)

            Spacer(minLength: 0)

            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundColor(Theme.Palette.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 1)
            .padding(.leading, 54)
    }
}

struct SettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.background
            SettingsPanel(viewModel: MeetingViewModel())
        }
        .preferredColorScheme(.dark)
    }
}
