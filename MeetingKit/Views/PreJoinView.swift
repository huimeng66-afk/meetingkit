//
//  PreJoinView.swift
//  MeetingKit
//
//  入会页。按 docs/design-tianqiong.md 3.1：
//  品牌头 → 16:10 预览卡（大头像 + 麦克风/摄像头开关）→ 表单 → 渐变主按钮。
//
//  键盘策略：整页是 ScrollView，靠系统自动避让；不引入 iOS 15 才有的
//  安全区 inset / 焦点状态 API。数字键盘没有 return 键，所以"加入会议"按钮
//  自己先收键盘再进会议，避免键盘跟着页面一起消失时画面抖一下。
//

import Foundation
import SwiftUI

struct PreJoinView: View {

    @ObservedObject var router: AppRouter
    let info: JoinInfo

    /// 展示串（"123 4567" 前三后四）。真正的纯数字由 `digits` 在提交时统一清洗。
    @State private var numberText: String
    @State private var displayName: String
    @State private var isMicOn: Bool
    @State private var isCameraOn: Bool
    @State private var isHost: Bool
    @State private var meetingTitle: String

    @State private var isJoining = false
    /// 右上角登录页（sheet）。
    @State private var isLoginPresented = false
    /// 服务端下发的会议信息（入会前校验的结果）。nil = 还没校验或会议号已改。
    @State private var meetingInfo: MeetingInfoResponse?
    /// 入会密码（服务端 hasPassword 时显示输入框）。
    @State private var passwordText = ""
    /// 校验 / 入会的错误提示。
    @State private var joinError: String?
    /// 入会前的权限申请 + 转场任务。离开页面必须取消，否则用户返回首页后
    /// 几秒后会被一个"幽灵任务"强行拉进会议室。
    @State private var joinTask: Task<Void, Never>?
    /// 系统录音授权状态。
    ///
    /// 这里**不再**用 AVAudioRecorder 做"入会前电平演示"。教训很直接：
    /// AVAudioRecorder 会真正占住麦克风，而 SwiftUI 的页面切换是异步的——
    /// 点下"加入会议"后，PreJoinView 的 onDisappear 往往晚于 WebRTC 启动音频设备，
    /// 那次迟到的 `setActive(false)` 会把刚拉起来的 AudioUnit 一起按停。
    /// 表现就是"一进会议就没有麦克风"，且所有界面状态都还是正常的。
    /// 所以门外只负责"授权"，采集一律交给会议内的 WebRTC。
    @State private var micGranted: Bool = RealRTCClient.micPermissionGranted

    private let pagePadding: CGFloat = 20

    init(router: AppRouter, info: JoinInfo) {
        // 直接初始化包装器，避免在其它存储属性就绪前调用 wrappedValue 的 setter。
        _router = ObservedObject(wrappedValue: router)
        self.info = info
        _numberText = State(
            initialValue: JoinInfo.groupDigits(JoinInfo.digitsOnly(info.meetingNumber))
        )
        _displayName = State(initialValue: info.displayName)
        _isMicOn = State(initialValue: info.micOn)
        _isCameraOn = State(initialValue: info.cameraOn)
        _isHost = State(initialValue: info.isHost)
        _meetingTitle = State(initialValue: info.title)
    }

    var body: some View {
        ZStack {
            BrandBackground()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // 顶栏不参与入场：它承担"返回"，必须第一帧就在正确位置，
                    // 否则用户从首页点进来时，返回键会先缺一块再浮上来。
                    topBar

                    // 其余四块依次浮入。预览卡承担"这是哪场会"的第一眼识别，
                    // 给它最大的位移（18pt），表单与按钮依次递减，
                    // 视觉重量从上到下递减，符合"先确认会议、再确认自己"的顺序。
                    previewCard
                        .enterFromBottom(index: 0, distance: 18)

                    formCard
                        .enterFromBottom(index: 1, distance: 14)

                    joinButton
                        .enterFromBottom(index: 2, distance: 10)

                    createNewMeetingLink
                        .enterFromBottom(index: 3, distance: 8)
                }
                .padding(.horizontal, pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            // 门外只做一件事：把授权问清楚。真正的采集从入会后由 WebRTC 接管，
            // 这里绝不打开任何录音设备（原因见 micGranted 的注释）。
            guard isMicOn, !micGranted else { return }
            Task { @MainActor in
                let granted = await RealRTCClient.requestMicPermission()
                micGranted = granted
                if !granted { isMicOn = false }
            }
        }
        .onDisappear {
            joinTask?.cancel()
            joinTask = nil
        }
        .sheet(isPresented: $isLoginPresented) {
            LoginView(displayName: $displayName)
        }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.impact(.light)
                Keyboard.dismiss()
                router.goHome()
            } label: {
                Image(systemName: SymbolCompat.name("chevron.left", "chevron.backward"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)
                    .frame(width: 36, height: 36)
                    .liquidGlass(.clear, cornerStyle: .circle, isInteractive: true)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(BrandPressStyle())
            // 0.6s 入会动画期间锁住返回：否则 WorkItem 已执行、Task 还没跑时
            // 用户返回首页，仍可能被异步 join 拉回会议室。
            .disabled(isJoining)
            .accessibilityLabel("返回首页")

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Palette.brandGradient)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: SymbolCompat.name("video.fill", "video"))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                )

            Text("天穹会议")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.Palette.ink)

            Spacer(minLength: 0)

            // 右上角登录：游客态入口。名称可空入会，所以登录不是入会前的必填项，
            // 只作为可选的身份入口，不影响"输会议号直接进"的主路径。
            Button {
                Haptics.impact(.light)
                Keyboard.dismiss()
                isLoginPresented = true
            } label: {
                Text("登录")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.Palette.accent)
                    .frame(minWidth: 44, minHeight: 36)
                    .padding(.horizontal, 10)
                    .liquidGlass(.clear, cornerStyle: .capsule, isInteractive: true)
                    .contentShape(Capsule())
            }
            .buttonStyle(BrandPressStyle())
            .disabled(isJoining)
            .accessibilityLabel("登录账号")
        }
        .frame(height: 44)
    }

    // MARK: - 预览卡

    private var previewCard: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Theme.Palette.accent.opacity(0.22),
                    Theme.Palette.violet.opacity(0.16),
                    Theme.Palette.backgroundElevated
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 12) {
                AvatarView(user: previewUser, size: 84, showsSpeakingRing: false)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )

                Text(previewName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 48)
            }

            VStack(spacing: 0) {
                HStack {
                    previewBadge
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Spacer(minLength: 0)

                    // 麦克风钮外圈：开麦时缓慢呼吸，表达"已就绪"。
                    // 不假装是实时电平——门外没有任何采集，画一条会动的波形
                    // 只会掩盖真正的问题（要么权限没给，要么设备被别的 App 占着）。
                    ZStack {
                        if isMicOn {
                            MicReadyHalo(diameter: 44)
                        }

                        previewToggle(
                            isOn: isMicOn,
                            onSymbol: "mic.fill",
                            offSymbol: "mic.slash.fill",
                            accessibilityLabel: isMicOn ? "关闭麦克风" : "开启麦克风"
                        ) {
                            toggleMic()
                        }
                    }

                    previewToggle(
                        isOn: isCameraOn,
                        onSymbol: "video.fill",
                        offSymbol: "video.slash.fill",
                        accessibilityLabel: isCameraOn ? "关闭摄像头" : "开启摄像头"
                    ) {
                        isCameraOn.toggle()
                    }
                }

                HStack {
                    Spacer(minLength: 0)
                    micStatusHint
                }
                .padding(.top, 8)
            }
            .padding(16)
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.Palette.glassStroke, lineWidth: 1)
        )
    }

    private var previewBadge: some View {
        Text("预览")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.Palette.ink2)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.black.opacity(0.32))
            )
            .overlay(
                Capsule().stroke(Theme.Palette.glassStroke, lineWidth: 1)
            )
    }

    private func previewToggle(
        isOn: Bool,
        onSymbol: String,
        offSymbol: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            ZStack {
                // 开启：白 10% 玻璃；关闭：danger 0.9 实红 + 斜杠，
                // 颜色之外还有图标语义，满足"不只靠颜色区分状态"。
                Circle()
                    .fill(
                        isOn
                            ? Color.white.opacity(0.10)
                            : Theme.Palette.danger.opacity(0.9)
                    )

                Image(systemName: SymbolCompat.name(isOn ? onSymbol : offSymbol, "questionmark.circle"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 44, height: 44)
            .liquidGlass(.clear, cornerStyle: .circle, castsShadow: false)
            .contentShape(Circle())
        }
        .buttonStyle(BrandPressStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - 麦克风

    /// 麦克风开关：只管理授权与意图，不碰录音设备。
    ///
    /// 权限在这里自己申请，不留给 proceedToRoom：用户点了麦克风却看不到
    /// 任何反馈，是"点了没反应"最典型的来源。
    private func toggleMic() {
        if isMicOn {
            isMicOn = false
            return
        }
        isMicOn = true
        Task { @MainActor in
            let granted = await RealRTCClient.requestMicPermission()
            micGranted = granted
            if !granted { isMicOn = false }
        }
    }

    /// 开关下方的一行状态。宁可多一句话，也不要让用户靠猜——
    /// 这一页是他判断"我的麦克风到底行不行"的唯一机会。
    @ViewBuilder
    private var micStatusHint: some View {
        Group {
            if !isMicOn {
                Text("麦克风已关闭 · 对方听不到你的声音").opacity(0.72)
            } else if !micGranted {
                Text("麦克风权限未开启 · 请到系统设置里允许").foregroundColor(Theme.Palette.danger)
            } else {
                Text("麦克风已就绪 · 入会后自动开启").opacity(0.72)
            }
        }
        .font(.system(size: 11))
        .foregroundColor(.white)
        .animation(.easeInOut(duration: 0.18), value: isMicOn)
    }

    // MARK: - 表单

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("会议号")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Palette.ink3)

                ZStack(alignment: .leading) {
                    TextField("", text: $numberText)
                        .accessibilityLabel("会议号")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.Palette.ink)
                        .accentColor(Theme.Palette.accent)
                        .keyboardType(.numberPad)
                        .onChange(of: numberText) { value in
                            let formatted = JoinInfo.groupDigits(JoinInfo.digitsOnly(value))
                            if numberText != formatted {
                                numberText = formatted
                            }
                            // 会议号变了：上一次的校验结果与密码展开状态作废，
                            // 主持人的"发起会议"身份也退回普通参会者。
                            if meetingInfo != nil || !passwordText.isEmpty {
                                meetingInfo = nil
                                passwordText = ""
                                joinError = nil
                            }
                            isHost = false
                        }

                    if numberText.isEmpty {
                        Text("请输入 7 位会议号")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.Palette.ink3)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.Palette.surfaceSubtle)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.Palette.glassStroke, lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("你的名称")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Palette.ink3)

                ZStack(alignment: .leading) {
                    TextField("", text: $displayName)
                        .accessibilityLabel("你的名称")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.Palette.ink)
                        .accentColor(Theme.Palette.accent)
                        .disableAutocorrection(true)
                        .onChange(of: displayName) { value in
                            if value.count > 30 {
                                displayName = String(value.prefix(30))
                            }
                        }

                    if displayName.isEmpty {
                        Text("可不填，将以「访客」入会")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.Palette.ink3)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.Palette.surfaceSubtle)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.Palette.glassStroke, lineWidth: 1)
                )
            }

            // 服务端确认"会议有密码"后展开，避免无密码会议被多余的输入框挡住。
            if meetingInfo?.hasPassword == true {
                VStack(alignment: .leading, spacing: 8) {
                    Text("入会密码")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Palette.ink3)

                    SecureField("会议设有密码", text: $passwordText)
                        .font(.system(size: 15))
                        .foregroundColor(Theme.Palette.ink)
                        .accentColor(Theme.Palette.accent)
                        .keyboardType(.asciiCapable)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.Palette.surfaceSubtle)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Theme.Palette.glassStroke, lineWidth: 1)
                        )
                }
            }

            if let joinError = joinError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(joinError)
                        .font(.system(size: 12))
                        .lineLimit(2)
                }
                .foregroundColor(Theme.Palette.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .liquidGlass(
            .regular,
            cornerStyle: .continuous(Theme.Metrics.cardRadius),
            castsShadow: true
        )
    }

    // MARK: - 主按钮

    private var joinButton: some View {
        Button {
            startJoin()
        } label: {
            HStack(spacing: 8) {
                if isJoining {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Color.white))
                        .scaleEffect(0.9)
                }

                Text(isJoining ? "正在加入…" : "加入会议")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                    .fill(Theme.Palette.brandGradient)
            )
            .opacity(formIsValid ? 1.0 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous))
        }
        .buttonStyle(BrandPressStyle())
        // 只在提交中禁用。会议号不足 7 位时按钮仍然可点，点下去明确告诉用户差几位，
        // 而不是变成一块按不动的灰条——那和"登录点不动"是同一类问题。
        .disabled(isJoining)
        .accessibilityLabel("加入会议")
    }

    private var createNewMeetingLink: some View {
        Button {
            createNewMeeting()
        } label: {
            Text("发起新会议")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Palette.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle(pressedScale: 0.985, highlight: 0))
        .disabled(isJoining)
        .accessibilityLabel("发起新会议")
    }

    // MARK: - 动作

    private func startJoin() {
        guard !isJoining else { return }

        guard formIsValid else {
            let remaining = max(0, 7 - digits.count)
            joinError = remaining > 0
                ? "会议号是 7 位数字，还差 \(remaining) 位"
                : "请输入正确的 7 位会议号"
            Haptics.notify(.warning)
            return
        }

        Haptics.impact(.medium)
        Keyboard.dismiss()
        joinError = nil

        // 会议号变化后上一次的校验结果作废（onChange 里已清空 meetingInfo）。
        if meetingInfo == nil {
            verifyThenJoin()
            return
        }

        // 缓存命中也要重跑校验：锁定状态可能刚被主持人改掉，
        // 只校验一次会让人第二次点击直接绕过锁定/密码检查（S-9）。
        guard let info = meetingInfo else { return }
        let canBypass = isHost || info.isHost
        if info.locked && !canBypass {
            joinError = "会议已锁定，暂不能加入"
            return
        }
        if info.hasPassword && passwordText.isEmpty && !canBypass {
            joinError = "请输入入会密码"
            return
        }

        proceedToRoom()
    }

    /// 真实链路：入会前先向服务端确认会议存在、可加入。
    /// 404 / 410 / 锁定 / 满员等错误直接展示在表单里，用户不离开入会页。
    private func verifyThenJoin() {
        isJoining = true
        let no = digits

        APIClient.fetchMeetingInfo(no: no) { result in
            self.isJoining = false

            switch result {
            case .success(let info):
                self.meetingInfo = info
                // 服务端标题优先：用户输入会议号后看到的是真实会议名。
                if !info.title.isEmpty {
                    self.meetingTitle = info.title
                }
                // 主持人身份以服务端判定为准（用会议号/邀请链接进自己的会也算主持人）。
                if info.isHost {
                    self.isHost = true
                }

                // 主持人可绕过锁定与密码（服务端对 host 同样豁免）。
                let canBypass = info.isHost || self.isHost
                if info.locked && !canBypass {
                    self.joinError = "会议已锁定，暂不能加入"
                    return
                }
                if info.hasPassword && self.passwordText.isEmpty && !canBypass {
                    // 展开密码输入框，让用户填完再点一次"加入会议"。
                    self.joinError = nil
                    return
                }
                self.proceedToRoom()

            case .failure(let error):
                self.joinError = (error as? APIClient.APIError)?.message ?? "会议不存在，请检查会议号"
            }
        }
    }

    /// 校验通过后：先在这张页面把麦克风/摄像头权限要完，再进入会议室。
    ///
    /// 为什么不在会议室里等 `rtc.join` 去要权限：
    ///   1. `AVAudioApplication.requestRecordPermission` 在 fullScreenCover 转场
    ///      期间调用时，系统弹窗可能被延迟甚至吞掉，用户只看到"正在连接会议…"；
    ///   2. 权限弹窗属于"入会前检查"，放在门外比放在门里更符合预期；
    ///   3. 用户拒绝后直接以静音/关摄像头入会，会议室不会再出现一次授权等待。
    private func proceedToRoom() {
        guard !isJoining else { return }
        isJoining = true
        joinError = nil

        let targetRouter = router
        let wantsCamera = isCameraOn
        let task = Task { @MainActor in
            // 1. 麦克风：入会必问。已授权/已拒绝时系统会立即返回，不会重复弹窗。
            let granted = await RealRTCClient.requestMicPermission()
            if Task.isCancelled { return }
            self.micGranted = granted
            if !granted { self.isMicOn = false }

            // 2. 摄像头：只在本次真的要开摄像头时问，避免多余弹窗。
            if wantsCamera {
                let cameraGranted = await RealRTCClient.requestCameraPermission()
                if Task.isCancelled { return }
                if !cameraGranted { self.isCameraOn = false }
            }

            // 3. 权限结果已经写进 @State，重新构造一次入会参数再导航。
            if Task.isCancelled { return }
            let payload = self.buildJoinInfo()

            // 给系统权限弹窗收起留一点时间，避免它和全屏转场叠在一起。
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            targetRouter.join(payload)
        }
        joinTask = task
    }

    /// "发起新会议"：真实链路向服务端创建即时会议（需要登录）。
    /// 只换会议号与主持人身份，不动用户已经输入的名称：
    /// 用户填了一半的名字被系统覆盖是最容易激怒人的交互之一。
    private func createNewMeeting() {
        guard !isJoining else { return }
        Haptics.selection()

        // 未登录不能发起会议（服务端要求主持人身份）。
        guard AuthStore.load() != nil else {
            joinError = "发起会议需要先登录（右上角登录）"
            return
        }

        isJoining = true
        let name = trimmedName.isEmpty ? router.profile.displayName : trimmedName
        APIClient.createMeeting(title: "\(name)的会议", instant: true) { result in
            self.isJoining = false

            switch result {
            case .success(let meeting):
                withAnimation(Theme.Motion.standard) {
                    self.numberText = JoinInfo.groupDigits(meeting.no)
                    self.meetingTitle = meeting.title
                    self.isHost = true
                    // 自己创建的会议无需再走校验；直接进入。
                    self.meetingInfo = MeetingInfoResponse(
                        title: meeting.title,
                        hostName: name,
                        hasPassword: false,
                        liveCount: 0,
                        locked: false,
                        allowGuest: true,
                        maxParticipants: 9,
                        isHost: true,
                        status: "live"
                    )
                    self.joinError = nil
                }
                // 会议号已就位，直接入会。
                self.proceedToRoom()

            case .failure(let error):
                self.joinError = (error as? APIClient.APIError)?.message ?? "创建会议失败，请稍后重试"
            }
        }
    }

    // MARK: - 派生

    private var digits: String {
        JoinInfo.digitsOnly(numberText)
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 设计规范：会议号满 7 位即可入会（名称可空，入会后默认「访客」）。
    /// 不足 7 位时按钮仍可点，点击会明确提示还差几位；
    /// 只用透明度表达"还没填完"，不再用 disabled 把点击吞掉。
    private var formIsValid: Bool {
        digits.count == 7
    }

    private var previewName: String {
        trimmedName.isEmpty ? "访客" : trimmedName
    }

    private var previewUser: MeetingUser {
        MeetingUser(
            id: "local-me",
            name: previewName,
            role: isHost ? .host : .participant,
            isMicOn: isMicOn,
            isCameraOn: isCameraOn,
            isHandRaised: false,
            isSpeaking: false,
            isLocal: true,
            avatarColorIndex: router.profile.avatarColorIndex
        )
    }

    private func buildJoinInfo() -> JoinInfo {
        // 变量名不叫 `final`：它是 Swift 关键字，虽然这里能编译，
        // 但任何语法高亮/静态分析工具都会在它后面的几行集体误判。
        var joinInfo = info
        joinInfo.meetingNumber = digits
        // 名称可空入会：空名原样上报，由服务端分配「访客XXXX」。
        // 客户端统一填「访客」会导致所有未命名访客共用同一个踢人键（g:访客），
        // 主持人踢一个会连带封禁其他未命名访客（服务端按名称记踢出名单）。
        joinInfo.displayName = trimmedName
        joinInfo.isHost = isHost
        joinInfo.avatarColorIndex = router.profile.avatarColorIndex
        joinInfo.micOn = isMicOn
        joinInfo.cameraOn = isCameraOn
        // 真实链路：入会密码与登录令牌。
        joinInfo.password = passwordText
        joinInfo.token = AuthStore.load()?.token ?? ""

        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if isHost {
            joinInfo.title = title.isEmpty ? "\(joinInfo.displayName)的会议" : title
        } else if title.isEmpty || title == "加入会议" {
            // 校验通过后服务端标题已写入 meetingTitle；这里兜底显示会议号。
            joinInfo.title = "会议 \(JoinInfo.groupDigits(digits))"
        } else {
            joinInfo.title = title
        }
        return joinInfo
    }
}

// MARK: - 就绪光环

/// 麦克风钮外圈的"已就绪"呼吸环。
///
/// 它只表达一件事：麦克风已授权、入会后会被打开。
/// 故意不做成随音量跳动的电平条——门外没有采集，任何跳动都是演出来的，
/// 反而会掩盖"权限被拒 / 设备被占用"这类真问题。
private struct MicReadyHalo: View {

    var diameter: CGFloat

    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)

            Circle()
                .stroke(Theme.Palette.accent.opacity(breathing ? 0.42 : 0.18), lineWidth: 1.4)
                .scaleEffect(breathing ? 1.16 : 1.0)
        }
        .frame(width: diameter, height: diameter)
        .animation(
            .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
            value: breathing
        )
        .onAppear { breathing = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
