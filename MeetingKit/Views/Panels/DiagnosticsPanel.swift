//
//  DiagnosticsPanel.swift
//  MeetingKit
//
//  音视频诊断。不是给用户看的"功能"，是排障用的镜子：
//  "听不见/看不到"只有三种可能——连接没通、对端没发、播放没起来。
//  这张表把三段一次性摊开，用户截图一张就能定位，不用再来回猜。
//

import SwiftUI
import UIKit

struct DiagnosticsPanel: View {

    @ObservedObject var viewModel: MeetingViewModel

    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                Text(viewModel.diagnosticsText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Theme.Palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Metrics.space3)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                            .fill(Theme.Palette.surfaceSubtle)
                    )
                    .padding(.horizontal, Theme.Metrics.horizontal)
            }
            .frame(maxHeight: 300)

            actions
        }
        .onAppear { viewModel.refreshDiagnostics() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("音视频诊断")
                .font(Theme.Typography.sectionTitle)
                .foregroundColor(Theme.Palette.textPrimary)

            Text("连接没通 / 对端没发 / 播放没起来 —— 这张表能区分是哪一种")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space1)
        .padding(.bottom, Theme.Metrics.space3)
    }

    private var actions: some View {
        HStack(spacing: Theme.Metrics.space3) {
            Button {
                viewModel.refreshDiagnostics()
            } label: {
                Text("重新采集")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.Palette.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.Palette.surfaceSubtle)
                    )
            }
            .buttonStyle(.plain)

            Button {
                UIPasteboard.general.string = viewModel.diagnosticsText
                didCopy = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    didCopy = false
                }
            } label: {
                Text(didCopy ? "已复制" : "复制")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.Palette.brandGradient)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space3)
        .padding(.bottom, Theme.Metrics.space4)
    }
}
