//
//  InvitePanel.swift
//  MeetingKit
//
//  邀请面板：会议号 + 二维码 + 两种分享方式。
//
//  二维码必须白底：深色背景上 CIFilter 生成的黑白码在相机里对比度不足，
//  真机扫码会一直对不上焦。这里用白色圆角卡片把码包起来，码本身不染色。
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct InvitePanel: View {

    @ObservedObject var viewModel: MeetingViewModel

    @State private var qrImage: UIImage?
    @State private var didCopyNumber = false

    /// 邀请链接优先用网页地址，而不是 `tianqiong://`。
    ///
    /// 自定义 scheme 只有装了 App 的人能打开；把二维码发给还没装 App 的同事，
    /// 扫出来只会停在"无法打开链接"。网页版本身就能入会，先保证所有人都能进，
    /// 装没装 App 都不影响。首页通讯录的"邀请链接"用的也是同一个地址。
    private var invitePayload: String {
        TianqiongAPI.roomLink(number: viewModel.meetingNumber)
    }

    private var inviteText: String {
        "天穹会议邀请你加入\n会议号：\(viewModel.formattedMeetingNumber)\n点击加入：\(invitePayload)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: Theme.Metrics.space2)

            numberRow
                .padding(.horizontal, Theme.Metrics.horizontal)
                .padding(.bottom, Theme.Metrics.space3)

            qrCard
                .padding(.bottom, Theme.Metrics.space3)

            Spacer(minLength: Theme.Metrics.space3)

            actionRow
                .padding(.horizontal, Theme.Metrics.horizontal)
                .padding(.bottom, Theme.Metrics.space2)
        }
        .onAppear {
            regenerateQRCode()
        }
        .onChange(of: viewModel.meetingNumber) { _ in
            regenerateQRCode()
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("邀请参会人")
                .font(Theme.Typography.sectionTitle)
                .foregroundColor(Theme.Palette.textPrimary)

            Text("分享会议号或二维码")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.horizontal)
        .padding(.top, Theme.Metrics.space1)
        .padding(.bottom, Theme.Metrics.space3)
    }

    // MARK: - 会议号

    private var numberRow: some View {
        HStack(spacing: Theme.Metrics.space3) {
            Text(viewModel.formattedMeetingNumber.isEmpty ? "—" : viewModel.formattedMeetingNumber)
                .font(.system(size: 28, weight: .bold).monospacedDigit())
                .foregroundColor(Theme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)

            Button {
                copyNumber()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: didCopyNumber
                        ? SymbolCompat.name("checkmark")
                        : SymbolCompat.name("doc.on.doc.fill", "doc.on.doc"))
                        .font(.system(size: 11, weight: .semibold))

                    Text(didCopyNumber ? "已复制" : "复制")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(didCopyNumber ? Theme.Palette.success : Theme.Palette.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .liquidGlass(.clear, cornerStyle: .capsule, isInteractive: true)
            }
            .buttonStyle(LiquidPressStyle(pressedScale: 0.985, highlight: 0))
            .accessibilityLabel("复制会议号")
        }
    }

    // MARK: - 二维码

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)

            if let qrImage = qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: SymbolCompat.name("qrcode", "square.grid.3x3"))
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(Color.black.opacity(0.35))

                    Text("暂无会议号")
                        .font(.system(size: 11))
                        .foregroundColor(Color.black.opacity(0.45))
                }
            }
        }
        .frame(width: 150, height: 150)
        .accessibilityLabel("会议二维码")
    }

    // MARK: - 两个动作

    private var actionRow: some View {
        HStack(spacing: Theme.Metrics.space3) {
            actionButton(
                title: "复制邀请文案",
                symbol: SymbolCompat.name("text.bubble.fill", "text.bubble")
            ) {
                UIPasteboard.general.string = inviteText
                Haptics.impact(.light)
                viewModel.showToast(
                    ToastMessage(
                        text: "邀请文案已复制",
                        systemImage: "doc.on.doc.fill",
                        style: .success
                    )
                )
            }

            actionButton(
                title: "系统分享",
                symbol: SymbolCompat.name("square.and.arrow.up")
            ) {
                presentShareSheet()
            }
        }
    }

    private func actionButton(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(Theme.Palette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                    .fill(Theme.Palette.surfaceSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                    .stroke(Theme.Palette.glassStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous))
        }
        .buttonStyle(ControlButtonPressStyle())
    }

    // MARK: - 动作

    private func copyNumber() {
        guard !viewModel.meetingNumber.isEmpty else { return }
        UIPasteboard.general.string = viewModel.formattedMeetingNumber
        Haptics.impact(.light)

        withAnimation(Theme.Motion.standard) {
            didCopyNumber = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(Theme.Motion.standard) {
                didCopyNumber = false
            }
        }
    }

    private func regenerateQRCode() {
        guard !invitePayload.isEmpty, !viewModel.meetingNumber.isEmpty else {
            qrImage = nil
            return
        }
        qrImage = QRCodeGenerator.image(for: invitePayload)
    }

    private func presentShareSheet() {
        guard let window = Self.keyWindow(),
              let presenter = Self.topViewController(from: window.rootViewController) else {
            viewModel.showToast(
                ToastMessage(
                    text: "暂时无法打开系统分享",
                    systemImage: "exclamationmark.triangle.fill",
                    style: .warning
                )
            )
            return
        }

        let controller = UIActivityViewController(
            activityItems: [inviteText],
            applicationActivities: nil
        )
        if let popover = controller.popoverPresentationController {
            // iPad 上缺 sourceView/sourceRect 会直接崩溃，这两行是硬性要求。
            popover.sourceView = window
            popover.sourceRect = CGRect(
                x: window.bounds.midX,
                y: window.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true, completion: nil)
    }

    // MARK: - 顶层控制器

    private static func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            if let first = windowScene.windows.first {
                return first
            }
        }
        return nil
    }

    private static func topViewController(from base: UIViewController?) -> UIViewController? {
        if let navigation = base as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = base as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        if let presented = base?.presentedViewController {
            return topViewController(from: presented)
        }
        return base
    }
}

// MARK: - 二维码生成

/// 复用同一个 CIContext：创建 CIContext 会分配 GPU/Metal 资源，
/// 每次 body 求值都 new 一个会在面板打开期间明显抬高能耗。
private enum QRCodeGenerator {

    private static let context = CIContext(options: nil)

    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }

        // 放大 12 倍再用 .interpolation(.none) 显示，边缘不会糊。
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct InvitePanel_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.background
            InvitePanel(viewModel: MeetingViewModel())
        }
        .preferredColorScheme(.dark)
    }
}
