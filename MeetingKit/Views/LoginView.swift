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
import UIKit

struct LoginView: View {

    /// 入会页"你的名称"。登录成功后回填账号昵称，不清空用户已填的会议号。
    @Binding var displayName: String

    /// 由宿主提供的关闭动作。
    ///
    /// 登录页现在既可能挂在 `.sheet` 里（老路径），也可能作为窗口内浮层出现
    /// （首页现在用这个）。闭包为空时才回落到 presentationMode，
    /// 这样同一个视图在两种承载方式下都能正常关闭，不需要两套实现。
    var onClose: (() -> Void)? = nil

    @Environment(\.presentationMode) private var presentationMode

    @State private var account = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    /// 密码可见开关。移动端键盘误触率高，看不见输入内容时用户很难判断
    /// 是"密码错了"还是"根本没输进去"。
    @State private var showsPassword = false

    /// 已登录会话（打开 sheet 时读一次）。用于展示"当前账号"与退出登录。
    @State private var existingSession: AuthSession? = AuthStore.load()

    /// 键盘高度。
    ///
    /// 登录页作为窗口内浮层挂在首页时，首页整棵子树忽略了键盘安全区
    /// （底栏不能被顶起来），这个忽略会一起继承下来。不自己补这一段，
    /// 键盘弹起后"登录"按钮就被压在键盘下面，用户只能盲点。
    @State private var keyboardHeight: CGFloat = 0

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
                    registerHint
                    devicePolicyNote
                    guestNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32 + keyboardHeight)
            }
        }
        .onAppear {
            // 已登录时自动带出账号，用户只需输入密码即可换设备续登。
            if let session = existingSession {
                account = session.account
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            withAnimation(Theme.Motion.standard) {
                keyboardHeight = max(0, frame.height - 34)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(Theme.Motion.standard) {
                keyboardHeight = 0
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                close()
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

                HStack(spacing: 6) {
                    Group {
                        if showsPassword {
                            TextField("请输入密码", text: $password)
                        } else {
                            SecureField("请输入密码", text: $password)
                        }
                    }
                    .font(.system(size: 15))
                    .foregroundColor(Theme.Palette.ink)
                    .accentColor(Theme.Palette.accent)
                    .textContentType(.password)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                    Button {
                        showsPassword.toggle()
                        Haptics.selection()
                    } label: {
                        Image(systemName: showsPassword ? "eye.slash" : "eye")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.Palette.ink3)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel(showsPassword ? "隐藏密码" : "显示密码")
                }
                .padding(.leading, 16)
                .padding(.trailing, 2)
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
            .opacity(isSubmitting ? 0.85 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous))
        }
        .buttonStyle(BrandPressStyle())
        // 只拦"正在提交"，不再因为输入不完整而禁用。
        //
        // 上一版字段没填满时按钮被禁用且只有 0.4 透明度，用户点下去毫无反应，
        // 看起来就是"登录点不动"。现在点击一定会有反馈：要么给出缺什么的提示，
        // 要么直接发出请求。
        .disabled(isSubmitting)
        .accessibilityLabel("登录")
    }

    /// 没有账号时的唯一去处。
    ///
    /// 网页端注册走的是审核制（注册后需管理员通过），App 里不做注册表单——
    /// 那会把审核流程拆成两套。这里只负责把用户送到网页端注册页，
    /// 比让人对着"账号或密码不正确"反复试要诚实。
    private var registerHint: some View {
        Button {
            guard var url = URL(string: TianqiongAPI.origin.absoluteString) else { return }
            url.appendPathComponent("auth.html")
            Haptics.impact(.light)
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                Text("还没有账号？")
                    .foregroundColor(Theme.Palette.ink3)
                Text("去网页端注册")
                    .foregroundColor(Theme.Palette.accent)
            }
            .font(.system(size: 12.5, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("还没有账号，去网页端注册")
    }

    private var devicePolicyNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: SymbolCompat.name("iphone", "iphone.gen3"))
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.ink3)
                .padding(.top, 1)

            Text("同一账号仅限一台设备登录，在其它设备登录后本机会自动退出。")
                .font(.system(size: 11.5))
                .foregroundColor(Theme.Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func close() {
        Keyboard.dismiss()
        if let onClose = onClose {
            onClose()
        } else {
            presentationMode.wrappedValue.dismiss()
        }
    }

    private func submit() {
        guard !isSubmitting else { return }

        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "请输入账号"
            Haptics.notify(.warning)
            return
        }
        guard !password.isEmpty else {
            errorMessage = "请输入密码"
            Haptics.notify(.warning)
            return
        }

        Haptics.impact(.medium)
        Keyboard.dismiss()
        isSubmitting = true
        errorMessage = nil

        let trimmedAccount = trimmed.lowercased()

        APIClient.login(account: trimmedAccount, password: password) { result in
            isSubmitting = false

            switch result {
            case .success(let session):
                AuthStore.save(session)
                existingSession = session
                displayName = session.name
                Haptics.notify(.success)
                close()

            case .failure(let error):
                errorMessage = (error as? APIClient.APIError)?.message ?? error.localizedDescription
                Haptics.notify(.error)
            }
        }
    }
}
