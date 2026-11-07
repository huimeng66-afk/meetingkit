//
//  PasswordChangeSheet.swift
//  MeetingKit
//
//  「修改密码」浮层。
//
//  为什么单独一个文件：设置页已经承载了六组偏好与三个说明浮层，再把三段输入、
//  两处校验、一次换 token 的流程塞进去，单文件会突破一千行——那种文件没有人
//  愿意在改 bug 时打开。这个浮层只依赖 APIClient 与 AuthStore，自带键盘避让，
//  设置页只需要"打开 / 关闭 / 收一条成功回调"。
//
//  交互约定：
//    · 三个输入框都不禁用按钮。字段没填满时点击会明确告诉用户缺什么，
//      比一颗 0.4 透明度、点了没反应的按钮诚实得多。
//    · 新密码下限 8 位由服务端强制，这里提前拦一次，省一次往返。
//    · 成功后宿主负责关闭浮层并提示；浮层自己不做转场，避免两层动画打架。
//

import SwiftUI
import UIKit

struct PasswordChangeSheet: View {

    var onClose: () -> Void
    /// 成功回调带上新的会话，宿主可以立刻刷新账号卡片。
    var onSuccess: (AuthSession) -> Void

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var showsPassword = false
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var keyboardHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isSubmitting else { return }
                    close()
                }

            card
                .padding(.horizontal, 12)
                .padding(.bottom, keyboardHeight > 0 ? keyboardHeight + 8 : 12)
                .animationCompat(Theme.Motion.standard, value: keyboardHeight)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardHeight = frame.height
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
    }

    // MARK: - 卡片

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.16))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 14)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("修改密码")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink)

                    Text("修改后其它设备需要用新密码重新登录")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button {
                    guard !isSubmitting else { return }
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink2)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.Palette.surfaceSubtle))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(LiquidPressStyle(pressedScale: 0.985, highlight: 0))
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 18)

            VStack(alignment: .leading, spacing: 12) {
                field(
                    title: "当前密码",
                    placeholder: "请输入当前密码",
                    text: $oldPassword,
                    contentType: .password,
                    showsEye: false
                )

                field(
                    title: "新密码",
                    placeholder: "至少 8 位",
                    text: $newPassword,
                    contentType: .newPassword,
                    showsEye: true
                )

                field(
                    title: "确认新密码",
                    placeholder: "再输入一次新密码",
                    text: $confirmPassword,
                    contentType: .newPassword,
                    showsEye: false
                )

                if let errorMessage = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(Theme.Palette.danger)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.Palette.danger.opacity(0.12))
                    )
                }

                Button {
                    submit()
                } label: {
                    HStack(spacing: 8) {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.85)
                        }

                        Text(isSubmitting ? "正在更新…" : "更新密码")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.Palette.accent)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(BrandPressStyle())
                .disabled(isSubmitting)
                .padding(.top, 2)
                .accessibilityLabel("更新密码")
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .liquidGlass(.regular, cornerStyle: .continuous(24), castsShadow: true)
    }

    // MARK: - 输入行

    private func field(
        title: String,
        placeholder: String,
        text: Binding<String>,
        contentType: UITextContentType,
        showsEye: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Theme.Palette.ink3)

            HStack(spacing: 4) {
                Group {
                    if showsEye && showsPassword {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .font(.system(size: 15))
                .foregroundColor(Theme.Palette.ink)
                .accentColor(Theme.Palette.accent)
                .textContentType(contentType)
                .autocapitalization(.none)
                .disableAutocorrection(true)

                if showsEye {
                    Button {
                        showsPassword.toggle()
                        Haptics.selection()
                    } label: {
                        Image(systemName: showsPassword ? "eye.slash" : "eye")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.Palette.ink3)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(LiquidPressStyle(pressedScale: 0.985, highlight: 0))
                    .accessibilityLabel(showsPassword ? "隐藏新密码" : "显示新密码")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, showsEye ? 4 : 14)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.Palette.surfaceSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Theme.Palette.glassStroke, lineWidth: 1)
            )
        }
    }

    // MARK: - 动作

    private func close() {
        Keyboard.dismiss()
        onClose()
    }

    private func submit() {
        guard !isSubmitting else { return }

        guard !oldPassword.isEmpty else {
            errorMessage = "请输入当前密码"
            Haptics.notify(.warning)
            return
        }
        guard newPassword.count >= 8 else {
            errorMessage = "新密码至少 8 位"
            Haptics.notify(.warning)
            return
        }
        guard newPassword == confirmPassword else {
            errorMessage = "两次输入的新密码不一致"
            Haptics.notify(.warning)
            return
        }
        guard newPassword != oldPassword else {
            errorMessage = "新密码不能与当前密码相同"
            Haptics.notify(.warning)
            return
        }
        guard let token = AuthStore.load()?.token, !token.isEmpty else {
            errorMessage = "登录状态已失效，请重新登录"
            Haptics.notify(.error)
            return
        }

        Keyboard.dismiss()
        isSubmitting = true
        errorMessage = nil
        Haptics.impact(.medium)

        APIClient.changePassword(
            oldPassword: oldPassword,
            newPassword: newPassword,
            token: token
        ) { result in
            isSubmitting = false
            switch result {
            case .success(let session):
                Haptics.notify(.success)
                onSuccess(session)
            case .failure(let error):
                errorMessage = (error as? APIClient.APIError)?.message ?? error.localizedDescription
                Haptics.notify(.error)
            }
        }
    }
}
