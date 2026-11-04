//
//  LoginView.swift
//  MeetingKit
//
//  右上角"登录"的落地页（sheet）。入会页名称可空，因此登录是可选动作：
//  它的唯一职责是"拿到账号身份并回填昵称"，不做任何入会逻辑。
//
//  结构：关闭条 → 品牌头 → 账号 / 密码 → 错误提示 → 登录按钮 → 游客说明。
//  Modal 规范：右上角提供明确的取消按钮（关闭 icon），同时保留系统下滑关闭。
//
//  登录成功后：
//    1. 会话落盘（AuthStore），下次打开自动带出账号；
//    2. 昵称回填入会页"你的名称"（displayName Binding）；
//    3. 关闭 sheet，用户回到入会页继续填会议号。
//

import SwiftUI

struct LoginView: View {

    /// 入会页"你的名称"。登录成功后回填账号昵称，不清空用户已填的会议号。
    @Binding var displayName: String

    @Environment(\.presentationMode) private var presentationMode

    @State private var account = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    /// 已登录会话（打开 sheet 时读一次）。用于展示"当前账号"与退出登录。
    @State private var existingSession: AuthSession? = AuthStore.load()

    var body: some View {
        ZStack {
            Theme.Palette.background
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    brandMark
                    form
                    loginButton
                    guestNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .onAppear {
            // 已登录时自动带出账号，用户只需输入密码即可换设备续登。
            if let session = existingSession {
                account = session.account
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Keyboard.dismiss()
                presentationMode.wrappedValue.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .overlay(Circle().stroke(Theme.Palette.glassStroke, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(BrandPressStyle())
            .disabled(isSubmitting)
            .accessibilityLabel("关闭登录")

            Text("登录")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.Palette.ink)

            Spacer(minLength: 0)
        }
        .frame(height: 40)
    }

    private var brandMark: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Palette.brandGradient)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: SymbolCompat.name("video.fill", "video"))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("天穹会议")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Theme.Palette.ink)

                Text(existingAccountText)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.ink3)
            }

            Spacer(minLength: 0)

            if existingSession != nil {
                Button {
                    Haptics.impact(.light)
                    AuthStore.clear()
                    existingSession = nil
                    account = ""
                    password = ""
                    errorMessage = nil
                    // 退出后入会页名称回空：避免拿着已退出账号的昵称当访客名入会。
                    if !displayName.isEmpty {
                        displayName = ""
                    }
                } label: {
                    Text("退出")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.Palette.ink2)
                        .frame(minWidth: 44, minHeight: 32)
                        .padding(.horizontal, 8)
                        .liquidGlass(.clear, cornerStyle: .capsule, isInteractive: true)
                        .contentShape(Capsule())
                }
                .buttonStyle(BrandPressStyle())
                .disabled(isSubmitting)
                .accessibilityLabel("退出登录")
            }
        }
    }

    private var existingAccountText: String {
        if let session = existingSession {
            return "当前账号：\(session.account)"
        }
        return "登录后以账号身份参会"
    }

    // MARK: - 表单

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("账号")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Palette.ink3)

                TextField("手机号或邮箱", text: $account)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.Palette.ink)
                    .accentColor(Theme.Palette.accent)
                    .keyboardType(.asciiCapable)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .textContentType(.username)
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.Palette.glassStroke, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("密码")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Palette.ink3)

                SecureField("请输入密码", text: $password)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.Palette.ink)
                    .accentColor(Theme.Palette.accent)
                    .textContentType(.password)
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.Palette.glassStroke, lineWidth: 1)
                    )
            }

            if let errorMessage = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .lineLimit(2)
                }
                .foregroundColor(Theme.Palette.danger)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.Palette.danger.opacity(0.12))
                )
            }
        }
        .padding(16)
        .liquidGlass(
            .regular,
            cornerStyle: .continuous(Theme.Metrics.cardRadius),
            castsShadow: true
        )
    }

    // MARK: - 登录按钮

    private var loginButton: some View {
        Button {
            submit()
        } label: {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Color.white))
                        .scaleEffect(0.9)
                }

                Text(isSubmitting ? "正在登录…" : "登录")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                    .fill(Theme.Palette.brandGradient)
            )
            .opacity(formIsValid && !isSubmitting ? 1.0 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous))
        }
        .buttonStyle(BrandPressStyle())
        .disabled(!formIsValid || isSubmitting)
        .accessibilityLabel("登录")
    }

    private var guestNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(Theme.Palette.ink3)

            Text("不登录也可以直接输入会议号加入")
                .font(.system(size: 12))
                .foregroundColor(Theme.Palette.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    // MARK: - 动作

    private var formIsValid: Bool {
        !account.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    private func submit() {
        guard formIsValid, !isSubmitting else { return }

        Haptics.impact(.medium)
        Keyboard.dismiss()
        isSubmitting = true
        errorMessage = nil

        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        APIClient.login(account: trimmedAccount, password: password) { result in
            isSubmitting = false

            switch result {
            case .success(let session):
                AuthStore.save(session)
                existingSession = session
                displayName = session.name
                Haptics.notify(.success)
                presentationMode.wrappedValue.dismiss()

            case .failure(let error):
                errorMessage = (error as? APIClient.APIError)?.message ?? error.localizedDescription
                Haptics.notify(.error)
            }
        }
    }
}
