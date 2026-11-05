//
//  MeetingViewModel.swift
//  MeetingKit
//
//  会议界面唯一的状态源。
//
//  设计约束（阶段 3 接真实 SDK 时只需替换 RTCClient 实现，视图一行都不用改）：
//    1. 视图不持有自己的业务状态，所有可变量都在这里；
//    2. RTC 事件与屏幕共享的跨进程事件都汇流到本类，UI 只读 @Published；
//    3. 所有 @Published 的写都发生在主线程（类本身标注 @MainActor）。
//
//  屏幕共享的关键认知：App 无法自己"开始共享"，真正的状态由 Broadcast 扩展写进
//  App Group。所以 `isScreenSharing` 永远从 ScreenShareBridge 单向流入，
//  业务代码不允许把它当成"我点了共享"的开关来用。
//

import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class MeetingViewModel: ObservableObject {

    // MARK: - 会议

    @Published private(set) var roomTitle: String = ""
    /// 会议品牌（企业专属会议室时带企业名与号模式），入会快照下发后更新。
    @Published private(set) var meetingBrand = MeetingBrand()
    /// 纯数字存储，展示时统一走 `formattedMeetingNumber`。
    /// 存格式化后的字符串会让"复制邀请链接 / 拨号入会"这类场景各自再去做一次清洗。
    @Published private(set) var meetingNumber: String = ""
    /// 会议时长 "HH:mm:ss"。只由内部计时器刷新，外部不写。
    @Published private(set) var durationText: String = "00:00:00"
    @Published private(set) var participants: [MeetingUser] = []
    @Published private(set) var activeSpeakerID: String?
    @Published private(set) var connectionState: ConnectionState = .connecting
    @Published private(set) var networkQuality: NetworkQuality = .unknown

    // MARK: - 本机状态

    @Published private(set) var isMicOn: Bool = true

    /// 正在等麦克风就绪（权限弹窗 / 设备重建）。
    /// UI 据此把按钮切成"开启中"并禁用，避免连点触发两路采集。
    /// 对照 Jitsi 的 GUM pending 状态：这段时间既不能假装成功，也不能让用户以为卡死。
    @Published private(set) var isMicPending: Bool = false
    /// 麦克风授权是否已在入会后对账过（只对账一次，重连不重复提示）。
    private var hasReconciledMicPermission = false
    @Published private(set) var isCameraOn: Bool = true
    @Published private(set) var isFrontCamera: Bool = true
    @Published private(set) var isHandRaised: Bool = false

    /// 本地麦克风实时电平（0...1）。底栏的说话脉冲读它。
    @Published private(set) var localAudioLevel: Float = 0

    /// 音视频诊断文本。只在打开诊断面板时采集，
    /// 用户反馈"听不见/看不到"时靠它一次定位卡在哪一段。
    @Published private(set) var diagnosticsText: String = "正在采集…"

    /// 音频路由：true = 扬声器，false = 听筒。默认外放，与入会后的常规预期一致。
    /// didSet 直接下发 RTC：真实链路改的是 RTCAudioSession 的输出端口。
    @Published var isSpeakerOn: Bool = true {
        didSet {
            guard oldValue != isSpeakerOn else { return }
            rtc.setSpeakerEnabled(isSpeakerOn)
        }
    }

    // MARK: - 远端媒体（真实链路）

    /// 远端摄像头渲染视图（peerId → RTCMTLVideoView）。
    @Published private(set) var remoteVideoViews: [String: UIView] = [:]
    /// 远端共享渲染视图。
    @Published private(set) var remoteScreenViews: [String: UIView] = [:]
    /// 正在共享屏幕的远端 peerId。nil = 没有远端共享。
    @Published private(set) var remoteScreenPeerID: String?
    /// 本地摄像头预览视图（RTCCameraPreviewView）。Mock 模式下为 nil，UI 回退头像卡。
    @Published private(set) var localPreviewView: UIView?

    /// 是否显示可拖拽的本地预览小窗。
    ///
    /// 默认 **false**：一进会就有一块自己的画面浮在别人脸上，
    /// 既挡住共享内容，也让"主角是共享画面"这件事变模糊。
    /// 需要看自己时再从不面板里打开，每场会议独立，不记忆上次选择。
    @Published var showsLocalPreview: Bool = false

    // MARK: - 安全设置（本阶段只影响界面状态）

    /// 锁定会议：新参会人无法加入。开启后顶栏标题旁出现小锁。
    @Published var isLocked: Bool = false
    /// 离会遮罩文案：入会失败 / 被踢 / 会议结束共用同一遮罩，标题与副文案按场景区分。
    @Published private(set) var endTitle: String = "会议已结束"
    @Published private(set) var endText: String = "你可以关闭页面或重新入会"
    @Published private(set) var endCanRejoin: Bool = true
    /// 等候室：新参会人先进入等候区，由主持人放行。
    @Published var isWaitingRoomOn: Bool = false
    /// 入会时静音：新参会人进入时默认关闭麦克风。
    @Published var muteOnJoin: Bool = true
    /// 允许共享屏幕：关闭后普通参会人不能再发起共享。
    @Published var allowSharing: Bool = true

    // MARK: - 屏幕共享（来自 ScreenShareBridge）

    /// 本机是否正在共享。只由扩展进程的真实状态驱动，不做乐观点值。
    @Published private(set) var isScreenSharing: Bool = false
    /// 本机共享已持续时长 "mm:ss"。
    @Published private(set) var shareDurationText: String = "00:00"
    /// 远端共享者的显示名。用于共享舞台的"某某正在共享"，空串表示没有远端共享。
    @Published private(set) var remoteScreenPeerName: String = ""
    /// 远端共享已持续时长 "mm:ss"。
    @Published private(set) var remoteShareDurationText: String = "00:00"

    /// 屏幕共享失败的原因（扩展侧上报）。非 nil 时会议室会弹一次提示。
    ///
    /// 这条通道是上一版缺的：扩展在 `broadcastStarted` 里因为签名、
    /// 容器或编码器起不来而结束广播时，主 App 只看到"状态没变成 active"，
    /// 表现就是点了共享、面板也弹了、然后什么都没有——用户完全无从判断。
    @Published private(set) var shareFailure: String?

    /// 顶栏共享条是否显示。
    ///
    /// 之前只判断 `isScreenSharing`：别人共享时顶栏没有任何提示，画面突然从宫格
    /// 变成一张 PPT，用户不知道发生了什么，也找不到"这是谁在共享"。
    /// 共享条必须对本机/远端两种情况同时生效。
    var isShareBannerVisible: Bool {
        isScreenSharing || remoteScreenPeerID != nil
    }

    /// 共享条文案。本机共享与观看他人共享是两种完全不同的语义，
    /// 用一个统一字符串会让"停止共享"按钮出现在观看者身上。
    var shareBannerText: String {
        if isScreenSharing {
            return "你正在共享屏幕"
        }
        if remoteScreenPeerID != nil {
            let name = DisplayName.clean(remoteScreenPeerName, fallback: "参会成员")
            return "\(name) 正在共享屏幕"
        }
        return ""
    }

    /// 共享条右侧的时长。
    var shareBannerDurationText: String {
        isScreenSharing ? shareDurationText : remoteShareDurationText
    }

    /// 共享链路体检报告。面板展开时现算，不做成 @Published：
    /// 它要读文件与心跳，没必要每秒刷新一次 UI。
    var shareDiagnosticsReport: String {
        shareBridge.makeDiagnostics().report
    }

    /// 用户已经看过失败提示：清掉，避免每次刷新重复弹。
    func dismissShareFailure() {
        shareFailure = nil
        shareBridge.consumeFailure()
    }

    // MARK: - 布局与面板

    @Published var layoutMode: LayoutMode = .speaker
    @Published var pinnedSpeakerID: String?
    @Published var isChromeVisible: Bool = true
    @Published var activePanel: MeetingPanel?
    @Published private(set) var unreadCount: Int = 0
    @Published private(set) var toast: ToastMessage?

    // MARK: - 聊天

    @Published private(set) var messages: [ChatMessage] = []

    // MARK: - 依赖

    /// 真实链路客户端。UI 预览可用 `MeetingViewModel(join:client:)` 注入 Mock。
    private let rtc: RTCClient
    private let shareBridge = ScreenShareBridge()

    /// 销毁时需要收尾的对象（RTC、计时器）放这里：
    /// `@MainActor` 类的 deinit 是 nonisolated 的，不能读 actor 隔离的存储属性，
    /// 所以必须先放进一个 Sendable 的盒子，deinit 才拿得到。写法与 ScreenShareBridge 一致。
    private nonisolated let teardown = MeetingTeardownBox()

    private var cancellables = Set<AnyCancellable>()
    private var ticker: DispatchSourceTimer?
    private var sessionStart: Date?
    private var toastDismissTask: Task<Void, Never>?
    private var hasJoined = false

    /// 用户已经主动离会。
    ///
    /// 入会握手是异步的（信令 + ICE，慢网下要好几秒）。如果用户在握手返回前点了离开，
    /// 迟到的回调会把已经收起来的"无法加入会议"错误页重新推上来——
    /// 表现为"我明明退出了，怎么又弹一个加入失败"。
    private var hasLeftLocally = false

    /// 计时器的拍数。屏幕共享的轮询挂在这里，避免再起一个计时器。
    private var clockTickCount = 0

    /// 最近一次"请求停止共享"的时间。用于 3 秒去抖：
    /// 用户狂点要有响应，但不能每点一下就往 Darwin 通知里灌一条消息。
    private var pendingStopAt: Date?

    /// 已经提示过"系统广播没有启动"，避免每秒重复弹。
    private var didWarnPendingShare = false

    /// 停止请求的最小重发间隔。
    private static let stopRetryInterval: TimeInterval = 3

    /// 远端分享的起始时刻。用于计算"某某已共享 03:12"，
    /// 不能从 `participants` 里找时间戳——共享是媒体行为，不是参会状态。
    private var remoteShareStartedAt: Date?

    /// 是否已经处理过首次共享状态。冷启动时扩展可能早就在跑，
    /// 首次只同步 UI，不弹提示、也不重复调用 rtc.startScreenShare()。
    private var hasAppliedInitialShareState = false

    /// 上一次从 ScreenShareBridge 收到的共享状态。
    /// 只用来区分"冷启动的首次同步"与"真正的状态跃迁"：nil 表示还没收到过，
    /// 此时只同步 UI、不弹提示（否则 app 冷启动会误报上一场会议的共享状态，见 D-08）。
    private var lastBridgeBroadcasting: Bool?

    /// 本机用户的固定 ID。名字与角色只在 join 时使用，
    /// 麦克风/摄像头/举手这三项每次都从当前 @Published 值取（见 makeLocalUser），
    /// 这样重新入会不会把用户关掉的麦克风"偷偷打开"。
    private static let localUserID = "local-me"

    /// 主持人强制静音 / 已移出的远端用户。
    ///
    /// Mock 的心跳会周期性把整份 participants 快照重新推上来（发言人轮换每 6 秒一次），
    /// 如果只改当前数组，下一拍快照就会把"已静音 / 已移出"原样回滚。
    /// 所以本地留一份名单，在 `rtcDidUpdateParticipants` 合并快照时重新应用。
    /// 接真实服务端后，这两个集合应由服务端的成员状态回执驱动，而不是本地记忆。
    private var mutedUserIDs: Set<String> = []
    private var removedUserIDs: Set<String> = []

    /// 入会页带过来的本机身份。只用于构造本机参会者，不参与其他业务。
    private let displayName: String
    /// 当前是否主持人。真实链路下主持人转移（host:changed）会更新它，
    /// 所以不是 let：初始值来自入会上下文，之后以服务端为准。
    private(set) var isHost: Bool
    /// 头像底色索引。与姓名一样只进不出，保证列表、小窗、宫格三处头像一致。
    private let avatarColorIndex: Int
    /// 入会密码（服务端下发的 hasPassword 会议需要）。
    private let joinPassword: String
    /// 登录令牌（空 = 访客）。
    private let joinToken: String

    // MARK: - 初始化

    /// 默认参数保证 `MeetingViewModel()` 仍然可用（预览、旧调用点不受影响）。
    /// 默认使用真实链路（正式对接服务器）；预览场景可注入 MockRTCClient。
    init(join: JoinInfo = .demo, client: RTCClient? = nil) {
        let title = join.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatted = JoinInfo.groupDigits(join.meetingNumber)
        roomTitle = title.isEmpty ? "会议 \(formatted)" : title
        meetingNumber = JoinInfo.digitsOnly(join.meetingNumber)
        displayName = UserProfileStore.sanitizeName(join.displayName)
        avatarColorIndex = UserProfileStore.clampColor(join.avatarColorIndex)
        isHost = join.isHost
        joinPassword = join.password
        joinToken = join.token.isEmpty ? (AuthStore.load()?.token ?? "") : join.token
        // 进会即开麦。
        //
        // 这是产品明确要求的行为：走进会议室就应该能直接说话，不需要先找麦克风按钮。
        // 因此这里不再看入会页那个开关（它只影响入会前的试音预览），
        // 唯一的例外是用户在「设置 → 入会自动静音」里显式打开过——
        // 那是给大会旁听场景准备的强约束，必须尊重。
        isMicOn = !AppSettings.shared.autoMuteOnJoin
        isCameraOn = join.cameraOn

        let resolvedClient: RTCClient
        if let client = client {
            resolvedClient = client
        } else if join == .demo {
            // 无参预览场景：Mock，避免联网。
            resolvedClient = MockRTCClient()
        } else {
            // 正式路径：对接真实服务器。
            resolvedClient = RealRTCClient()
        }
        rtc = resolvedClient
        rtc.delegate = self
        teardown.store(client: rtc)
    }

    deinit {
        // deinit 里只碰 nonisolated 的盒子：取消计时器 + 让 RTC 退出。
        // 此时本对象已开始销毁，rtc.delegate 的弱引用已被置空，不会回调到半销毁的对象。
        teardown.invalidate()
    }

    // MARK: - 派生状态

    var participantCount: Int {
        participants.count
    }

    /// 会议号的展示形态：前三后四（"1234567" → "123 4567"），与 Web 端一致。
    /// 长串数字不分组时，用户念出来和抄下来都容易错位。
    var formattedMeetingNumber: String {
        JoinInfo.groupDigits(meetingNumber)
    }

    var localUser: MeetingUser? {
        participants.first(where: { $0.isLocal })
    }

    /// 主画面该放谁：手动 pin 优先 → 当前发言人 → 第一个开摄像头的人。
    /// 最后一级兜底是为了避免所有人都关摄像头时主画面空白。
    var speakerUser: MeetingUser? {
        if let id = pinnedSpeakerID, let pinned = participants.first(where: { $0.id == id }) {
            return pinned
        }
        if let id = activeSpeakerID, let active = participants.first(where: { $0.id == id }) {
            return active
        }
        if let cameraOn = participants.first(where: { $0.isCameraOn }) {
            return cameraOn
        }
        return participants.first
    }

    /// 离会/结束按钮是否可点。
    ///
    /// 只有已经断开（离会遮罩接管）时才禁用。connecting 卡住时也必须能点：
    /// 网络慢、信令没握手成功的那几十秒，正是用户最想退出的时刻，
    /// 这里灰掉等于把人锁在一个进不去也出不来的页面里。
    var canEndMeeting: Bool {
        if case .disconnected = connectionState { return false }
        return true
    }

    /// 当前入会身份是否是主持人。视图用只读别名判断按钮语义，
    /// 不直接读私有的 `isHost`，避免破坏"入会上下文只进不出"的封装。
    var isCurrentUserHost: Bool {
        isHost
    }

    // MARK: - 生命周期

    /// View 的 onAppear 可能被多次调用（例如从后台回来重建视图），这里必须幂等：
    /// 观察者、计时器、join 各自都有"已启动就不再启动"的判断。
    func onAppear() {
        bindScreenShareIfNeeded()
        shareBridge.startObserving()
        startTickerIfNeeded()

        guard !hasJoined else { return }
        hasJoined = true
        joinSession()
    }

    /// 结束会议后的"重新入会"。只有离开状态才允许重新加入，
    /// 同时把连接状态先拨回 connecting，让遮罩立刻消失、界面回到可交互态。
    func rejoin() {
        guard case .disconnected = connectionState else { return }

        connectionState = .connecting
        participants = []
        /* 重新入会要重新对账一次权限：用户可能刚去系统设置里改过麦克风授权，
           不能因为上一场已经对过账就把新的授权状态吞掉。 */
        hasReconciledMicPermission = false
        hasJoined = true
        joinSession()
    }

    func onDisappear() {
        hasJoined = false
        stopTicker()
        /* 离会时把 pending 清掉：麦克风重建的异步回调可能晚于离会到达，
           不清会让下一次入会的按钮一进来就转圈。 */
        isMicPending = false

        // 离开会议必须结束系统录屏，否则扩展成孤儿进程：会议室已经销毁，
        // ReplayKit 广播却还在后台采集屏幕、持续往 App Group 写帧，用户完全无感知。
        // 这里直接调 requestStop() 而不用 stopScreenShare()：后者有 3 秒去抖，
        // 用户刚点过"停止共享"再立刻退出时，这次收尾请求会被窗口吞掉。
        // 顺序不能反：必须先 requestStop 再 stopObserving，后者会摘掉 Darwin 观察者。
        // 这里不判断 isScreenSharing：App 侧状态可能因为心跳延迟而失真（扩展还在录、
        // UI 以为已经停了），漏发一次停止请求会把录屏留在后台；扩展没在跑时收到通知无害。
        shareBridge.requestStop()
        shareBridge.stopObserving()

        // 离开会议：Mock 会把参会者清空并回到 disconnected，下次 onAppear 能重新入会。
        rtc.leave()
    }

    // MARK: - 本机设备

    func toggleMic() {
        if isMicPending { return }
        guard !isMicOn else {
            applyMicState(false)
            return
        }

        // 开麦前先看系统授权。这一步不做的话会出现最难排查的一类反馈：
        // "我明明开了麦，对方听不到，波形也不动"。
        // 原因是麦克风权限被拒时，WebRTC 的 audio track 依然能 isEnabled = true，
        // 它只是采不到任何一点数据——界面全绿，实际是哑的。
        switch micPermission {
        case .denied:
            // denied 状态下系统不会再弹窗，只能引导用户自己去设置里改。
            showToast(.micPermissionDenied())
        case .granted, .undetermined:
            /* 统一走 ensureMicEnabled：它内部会处理"轨不存在/已失效"的情况，
               并在必要时弹系统授权。比起这里只改一个布尔值，多的是自愈能力：
               设备被拔出、音频会话被来电打断、用户刚在设置里放开权限，
               这些场景下旧实现都会静默失败。 */
            isMicPending = true
            rtc.ensureMicEnabled(true) { [weak self] ok, reason in
                guard let self = self else { return }
                self.isMicPending = false
                if ok {
                    self.applyMicState(true)
                } else {
                    self.isMicOn = false
                    if let reason = reason, !reason.isEmpty {
                        self.showToast(ToastMessage(
                            text: reason,
                            systemImage: "mic.slash.fill",
                            style: .warning
                        ))
                    } else {
                        self.showToast(.micPermissionDenied())
                    }
                }
            }
        }
    }

    /// 把麦克风状态同时落到 RTC 轨、本地成员和界面上。
    /// 集中在一处，避免"改了 isMicOn 忘了通知 RTC"这类不一致。
    private func applyMicState(_ enabled: Bool) {
        /* 双保险：正常路径由 ensureMicEnabled 的回调复位；
           若回调因视图销毁/超时未到达，这里落定状态时也必须解除转圈。 */
        isMicPending = false
        isMicOn = enabled
        rtc.setMicEnabled(enabled)
        updateLocalParticipant { $0.isMicOn = enabled }
        showToast(.micMuted(!enabled))
    }

    /// 当前系统麦克风授权状态。
    ///
    /// iOS 17 起 `AVAudioSession.recordPermission` 被 `AVAudioApplication` 取代，
    /// 部署目标是 15.0，两条路都要留。
    private var micPermission: MicPermission {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .undetermined
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .undetermined
            }
        }
    }

    private enum MicPermission: Equatable {
        case granted, denied, undetermined
    }

    func toggleCamera() {
        isCameraOn.toggle()
        let enabled = isCameraOn
        rtc.setCameraEnabled(enabled)
        updateLocalParticipant { $0.isCameraOn = enabled }
        showToast(.cameraToggled(enabled))
    }

    /// 显示/隐藏本地预览小窗。
    ///
    /// 摄像头关着时打开没有意义（小窗里只有一张头像卡，还挡着别人的画面），
    /// 所以这里顺手把摄像头打开——用户的意图就是"我想看看自己"。
    func toggleLocalPreview() {
        let willShow = !showsLocalPreview

        if willShow && !isCameraOn {
            toggleCamera()
        }

        showsLocalPreview = willShow
        Haptics.impact(.light)

        showToast(
            ToastMessage(
                text: willShow ? "已显示本地预览" : "已隐藏本地预览",
                systemImage: willShow ? "rectangle.inset.filled" : "rectangle.dashed",
                style: .info
            )
        )
    }

    func switchCamera() {
        isFrontCamera.toggle()
        rtc.switchCamera()
        showToast(
            ToastMessage(
                text: isFrontCamera ? "已切换前置摄像头" : "已切换后置摄像头",
                systemImage: "arrow.triangle.2.circlepath",
                style: .info
            )
        )
    }

    // MARK: - 屏幕共享

    /// 点"共享屏幕"只打开选择面板。
    /// 真正的广播必须由系统弹窗发起（ReplayKit 的硬性规定）。
    ///
    /// 这里**不再**用 `AppGroupConfig.isAvailable` 直接拦截：
    /// 拦掉之后用户只看到一条 2 秒就消失的 Toast，面板根本不开，
    /// 体感就是"点了共享没反应"。是否可用改成在面板里说明，
    /// 并给出"复制网页版链接"的兜底路径——决定权交给用户，
    /// 而不是让一次签名能力探测把整个入口吞掉。
    func toggleScreenShare() {
        openPanel(.sharePicker)
    }

    /// 系统共享面板弹出**之前**调用：清旧帧、写本次会话的 requestedAt。
    ///
    /// 必须在 `BroadcastPickerPresenter.present()` 之前完成，否则第一帧
    /// 可能早于 requestedAt 落盘，被主 App 的新鲜度下界挡掉。
    func prepareForScreenShare() {
        didWarnPendingShare = false
        shareBridge.prepareForNewShare()
    }

    /// 请求停止屏幕共享。
    ///
    /// 这里**不做乐观置值**：`isScreenSharing` 只由两条真实来源改写——bridge 回调
    /// `applyScreenSharing(false)`，或 `validateLiveness()` 的兜底清理。
    /// 先置 false 会带来三个连锁问题（H-2）：
    ///   1. 顶栏红条与"停止共享"按钮立刻消失，用户看不到"正在停止"，也没有重试入口；
    ///   2. 真实状态回读时 `applyScreenSharing` 被 `isScreenSharing != broadcasting` 短路，
    ///      扩展其实还在推流，App 却再也纠正不回来；
    ///   3. 扩展没收到请求时，用户连"再点一次"的机会都没有。
    func stopScreenShare() {
        // 唯一的短路条件：3 秒去重窗口内重复点击。
        // 不再用 `isScreenSharing` 当前置条件：停止是异步的，请求发出后 isScreenSharing
        // 仍然是 true，旧逻辑里的 guard 语义正好相反，会把整个动作吞掉。
        let now = Date()
        if let last = pendingStopAt, now.timeIntervalSince(last) < Self.stopRetryInterval {
            return
        }
        pendingStopAt = now

        // 主 App 无权结束扩展进程，只能发信号让扩展自己收尾（它会调 finishBroadcastWithError）。
        // `rtc.stopScreenShare()` 不在这里调：等 applyScreenSharing(false) 在真实状态确认后
        // 统一通知 RTC，否则上层会先认为推流已停，与仍在出帧的扩展不一致。
        shareBridge.requestStop()

        showToast(
            ToastMessage(
                text: "正在停止共享…",
                systemImage: "rectangle.slash",
                style: .info
            )
        )
    }

    // MARK: - 布局

    func toggleLayout() {
        layoutMode = layoutMode.toggled
        // 切到宫格时清掉 pin：宫格里没有"主画面"概念，留着会在切回演讲者模式时突然跳人。
        if case .grid = layoutMode {
            pinnedSpeakerID = nil
        }
    }

    /// 传 nil 表示取消固定、回到跟随发言人。
    /// 传当前已 pin 的同一人时视为"再点一次取消"，这是缩略图条的常见交互。
    func pinSpeaker(_ id: String?) {
        guard let id = id else {
            pinnedSpeakerID = nil
            return
        }
        pinnedSpeakerID = (pinnedSpeakerID == id) ? nil : id
    }

    // MARK: - 会议内功能开关

    func toggleHandRaise() {
        isHandRaised.toggle()
        let raised = isHandRaised
        rtc.setHandRaised(raised)
        updateLocalParticipant { $0.isHandRaised = raised }
        showToast(.handRaised(raised))
    }

    // MARK: - 聊天

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 不在这里 append：Mock 会同步回调 rtcDidReceiveMessage，
        // 让消息只经过一个入口，避免"自己发的消息出现两条"。
        rtc.sendMessage(trimmed)
    }

    func markChatRead() {
        guard unreadCount != 0 else { return }
        unreadCount = 0
    }

    // MARK: - 面板

    /// 采集一份诊断文本。真实 RTC 才有 RTP 计数，Mock 直接给一句说明。
    func refreshDiagnostics() {
        diagnosticsText = "正在采集…"
        if let real = rtc as? RealRTCClient {
            real.collectDiagnostics { [weak self] text in
                self?.diagnosticsText = text
            }
        } else {
            diagnosticsText = "模拟连接，没有真实 RTP 数据。"
        }
    }

    func openPanel(_ panel: MeetingPanel) {
        // 面板会盖住底栏，如果此刻 chrome 是隐藏态，用户点完按钮会觉得"点了没反应"。
        isChromeVisible = true
        activePanel = panel
        if panel == .chat {
            markChatRead()
        }
        if panel == .diagnostics {
            refreshDiagnostics()
        }
    }

    func closePanel() {
        activePanel = nil
    }

    // MARK: - Toast

    func showToast(_ message: ToastMessage) {
        toast = message

        // 后一条覆盖前一条：取消上一次的自动消失任务，否则新 toast 会被旧任务提前清掉。
        toastDismissTask?.cancel()
        let identifier = message.id
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self = self, !Task.isCancelled else { return }
            if self.toast?.id == identifier {
                self.toast = nil
            }
        }
    }

    // MARK: - 成员管理（主持人）

    /// 远程开关某个参会人的麦克风（主持人强制静音）。
    ///
    /// 真实链路：转发给 RTC（服务端拒绝非主持人调用，被静音方收到 host:mute）。
    /// 本地同时记进 `mutedUserIDs`，让后续快照刷新时仍保持静音展示。
    func setMic(_ enabled: Bool, for userID: String) {
        // 管理动作只作用于远端：把自己塞进 mutedUserIDs 会和 @Published 的 isMicOn 打架。
        guard userID != localUser?.id else { return }
        guard participants.contains(where: { $0.id == userID }) else { return }

        if !enabled {
            rtc.mutePeer(userID)
        }
        if let index = participants.firstIndex(where: { $0.id == userID }) {
            participants[index].isMicOn = enabled
        }
        if enabled {
            mutedUserIDs.remove(userID)
        } else {
            mutedUserIDs.insert(userID)
        }
    }

    /// 把某个参会人移出会议。
    func removeParticipant(_ userID: String) {
        guard userID != localUser?.id else { return }
        guard participants.contains(where: { $0.id == userID }) else { return }

        rtc.removePeer(userID)

        if let index = participants.firstIndex(where: { $0.id == userID }) {
            participants.remove(at: index)
        }
        removedUserIDs.insert(userID)
        // 已经不在会议里了，再记静音没有意义，还会让名单无限增长。
        mutedUserIDs.remove(userID)

        // 不要让"固定/发言人"指向一个已经不在列表里的人：
        // 顶栏的发言人名字与宫格高亮都会因此悬空。
        if activeSpeakerID == userID {
            activeSpeakerID = nil
        }
        if pinnedSpeakerID == userID {
            pinnedSpeakerID = nil
        }
        // 远端视图一并清掉。
        remoteVideoViews.removeValue(forKey: userID)
        remoteScreenViews.removeValue(forKey: userID)
        if remoteScreenPeerID == userID {
            clearRemoteShareState()
        }
    }

    /// 主持人锁定/解锁会议：乐观更新 UI，最终状态以服务端 room:locked 回执为准。
    func setLocked(_ locked: Bool) {
        guard isCurrentUserHost else { return }
        isLocked = locked
        rtc.setRoomLocked(locked)
    }

    func muteAll() {
        guard isCurrentUserHost else { return }

        rtc.muteAllPeers()

        // 只处理远端：主持人自己的麦克风由底栏控制，不能被"全部静音"顺手关掉。
        let candidates = participants.filter { !$0.isLocal }
        let newlyMuted = candidates.filter { $0.isMicOn }

        guard !newlyMuted.isEmpty else {
            showToast(
                ToastMessage(
                    text: "参会人已全部静音",
                    systemImage: "mic.slash.fill",
                    style: .info
                )
            )
            return
        }

        for index in participants.indices where !participants[index].isLocal {
            participants[index].isMicOn = false
            mutedUserIDs.insert(participants[index].id)
        }

        // 数量取"这次真正被静音的人"，已经是静音状态的同事不该被重复计数。
        showToast(
            ToastMessage(
                text: "已静音 \(newlyMuted.count) 位参会人",
                systemImage: "mic.slash.fill",
                style: .success
            )
        )
    }

    // MARK: - 会议级操作

    /// 真正结束会议（不是"只弹个提示"）：停止共享 → 退出 RTC → 清空参会人。
    /// 聊天记录保留：会后用户往往还要回看纪要，清掉反而丢数据。
    ///
    /// 主持人路径：先通知服务端（服务端广播 meeting:ended，所有人包括自己都会
    /// 收到 rtcDidMeetingEnd 走统一的结束清理）；随后本地立即执行清理兜底。
    /// 参会者路径：直接本地清理。
    func endMeeting() {
        if isScreenSharing {
            stopScreenShare()
        }

        if isCurrentUserHost {
            rtc.endMeeting()
        }

        finalizeLocalEnd(
            toast: ToastMessage(
                text: isCurrentUserHost ? "会议已结束" : "已离开会议",
                systemImage: "phone.down.fill",
                style: .danger
            ),
            title: isCurrentUserHost ? "会议已结束" : "已离开会议",
            text: isCurrentUserHost ? "你结束了本次会议" : "你可以重新加入会议",
            // 主持人结束的是会议本身（即时会议在服务端已置为 ENDED），
            // 再点"重新入会"只会得到一句"会议已结束"。参会者只是离开，会议还在，可以重进。
            canRejoin: !isCurrentUserHost
        )
    }

    /// 统一的本机离会清理：RTC 退出 + 状态复位 + 提示。
    /// 主持人结束 / 被踢 / 被顶号 / 服务端结束会议 / 入会失败，多条路径共用这一份，
    /// 避免各自清一半导致"遮罩有了、底栏还在"的怪状态。
    private func finalizeLocalEnd(
        toast message: ToastMessage,
        title: String = "会议已结束",
        text: String = "你可以关闭页面或重新入会",
        canRejoin: Bool = true
    ) {
        rtc.leave()
        // 标记主动离会：正在飞行中的入会回调看到它就不再改写界面状态。
        hasLeftLocally = true
        connectionState = .disconnected
        participants = []
        remoteVideoViews.removeAll()
        remoteScreenViews.removeAll()
        clearRemoteShareState()
        localPreviewView = nil
        activeSpeakerID = nil
        networkQuality = .unknown
        // 会议结束，管理名单一起失效；否则"重新入会"后这些同事会永远不再出现。
        mutedUserIDs.removeAll()
        removedUserIDs.removeAll()

        // 计时基准清空：离会遮罩期间 durationText 不再累加
        // （refreshClocks 在 sessionStart == nil 时整段跳过，时长就停在离会那一刻）。
        // 不清的话，用户在遮罩上停留一分钟，重新入会后的时长会凭空多出一分钟（H-3）。
        sessionStart = nil

        activePanel = nil
        isChromeVisible = true
        isLocked = false
        // 主持人身份必须一起复位。不清的话，主持人结束会议后立刻以参会者身份
        // 进别人的会，会有一小段时间仍看到"结束会议"和成员管理入口，
        // 直到服务端快照回来才纠正——这期间点下去会真的去结束别人的会。
        isHost = false
        // 共享/举手/喇叭等会内状态一并复位：带着上一场的状态"重新入会"
        // 会出现共享红条、举手高亮等错位。
        isScreenSharing = false
        isHandRaised = false
        isSpeakerOn = true
        hasAppliedInitialShareState = false
        lastBridgeBroadcasting = nil
        pendingStopAt = nil

        // 离会遮罩文案：入会失败与被踢不再是"会议已结束"。
        endTitle = title
        endText = text
        endCanRejoin = canRejoin

        showToast(message)
    }

    // MARK: - 面板枚举

    enum MeetingPanel: String, Identifiable {
        case participants
        case chat
        case more
        case sharePicker
        case invite
        case safety
        case settings
        case diagnostics

        var id: String { rawValue }
    }
}

// MARK: - RTCClientDelegate

extension MeetingViewModel: RTCClientDelegate {

    func rtcDidUpdateMeetingBrand(_ brand: MeetingBrand) {
        meetingBrand = brand
    }

    func rtcDidUpdateParticipants(_ participants: [MeetingUser]) {
        // 合并规则：先按 removedUserIDs 剔除已被移出的人，再对 mutedUserIDs 里的人
        // 强制 isMicOn = false。Mock 的快照是一次性覆盖的，不做这一步，
        // 主持人刚做完的静音/移出会在下一拍（最多 1 秒）被原样还原。
        self.participants = participants
            .filter { !removedUserIDs.contains($0.id) }
            .map { user in
                guard mutedUserIDs.contains(user.id) else { return user }
                var muted = user
                muted.isMicOn = false
                return muted
            }

        // participants 里的本机行是权威数据（RTC 只认它），而视图读的是三个 @Published 标量。
        // 不在这里回写就会出现"双真相源"：换会话后底栏说静音、成员列表说麦克风已开。
        // 只在值真的变化时赋值，避免每次全量刷新都触发一次无意义的 objectWillChange。
        //
        // 同时补齐共享者名字：screen:state 事件可能比 participants 快照先到，
        // 那一刻只能显示"参会成员 正在共享"；快照到达后必须把真名补上，
        // 否则共享条会一直停在占位文案上。
        if let sharingID = remoteScreenPeerID,
           let sharer = self.participants.first(where: { $0.id == sharingID }),
           remoteScreenPeerName != DisplayName.clean(sharer.name) {
            remoteScreenPeerName = DisplayName.clean(sharer.name)
        }

        guard let local = self.participants.first(where: { $0.isLocal }) else { return }
        if isMicOn != local.isMicOn {
            isMicOn = local.isMicOn
        }
        if isCameraOn != local.isCameraOn {
            isCameraOn = local.isCameraOn
        }
        if isHandRaised != local.isHandRaised {
            isHandRaised = local.isHandRaised
        }
        // 主持人身份以服务端快照为准：主持人通过"加入会议/邀请链接"进自己的会时，
        // JoinInfo.isHost 可能是 false，而服务端快照 self.role == "host"。
        // 不回灌会导致主持人看不到管理入口、点"离开"也不结束会议。
        let serverSaysHost = local.role == .host
        if isHost != serverSaysHost {
            isHost = serverSaysHost
        }
    }

    func rtcDidChangeActiveSpeaker(_ userID: String?) {
        activeSpeakerID = userID
    }

    /// 摄像头实际没开成（权限被拒 / 无可用设备）。
    ///
    /// 状态本身由 `rtcDidUpdateParticipants` 的快照统一回灌，这里只负责解释原因：
    /// 用户点了"开摄像头"，图标闪一下又变回关闭，不给一句话只会以为是 App 坏了。
    func rtcDidUpdateLocalCamera(_ enabled: Bool) {
        guard !enabled else { return }
        showToast(
            ToastMessage(
                text: "无法开启摄像头，请在系统设置中允许访问相机",
                systemImage: "video.slash.fill",
                style: .warning
            )
        )
    }

    func rtcDidUpdateLocalAudioLevel(_ level: Float) {
        // 阈值 0.015 是"环境噪声"与"人声"的分界：安静房间里底噪
        // 通常在 0.005~0.012，正常说话在 0.05 以上。
        // 不做平滑，脉冲本来就要跟着音量起伏；平滑会让它变成一条迟钝的呼吸。
        localAudioLevel = level
    }

    /// 麦克风权限被拒：把界面上的"开着"改回"关了"，否则用户会以为自己在说话。
    func rtcDidUpdateLocalMic(_ enabled: Bool) {
        guard !enabled else { return }
        if isMicOn { isMicOn = false }
        if let index = participants.firstIndex(where: { $0.isLocal }), participants[index].isMicOn {
            participants[index].isMicOn = false
        }
        showToast(
            ToastMessage(
                text: "没有麦克风权限，请在系统设置中允许后重试",
                systemImage: "mic.slash.fill",
                style: .warning
            )
        )
    }

    func rtcDidChangeNetworkQuality(_ quality: NetworkQuality) {
        let wasPoor: Bool
        if case .poor = networkQuality {
            wasPoor = true
        } else {
            wasPoor = false
        }

        networkQuality = quality

        // 只在"刚变差"这一跳提示一次，否则每一拍都会弹。
        if case .poor = quality, !wasPoor {
            showToast(.networkPoor())
        }
    }

    func rtcDidChangeConnectionState(_ state: ConnectionState) {
        connectionState = state

        // 首次真正连上时对账一次麦克风授权。
        // 入会流程里确实请求过权限，但结果被丢掉了：如果用户在系统弹窗里点了
        // "不允许"，isMicOn 仍是 true，界面显示正在发言，实际采不到声音。
        // 这里把它纠正过来并明确告知原因，而不是让对方去猜。
        if case .connected = state, !hasReconciledMicPermission {
            hasReconciledMicPermission = true
            reconcileMicPermissionOnJoin()
        }
    }

    /// 入会后的麦克风授权对账。只做一次，重连不再重复提示。
    private func reconcileMicPermissionOnJoin() {
        guard isMicOn, micPermission != .granted else { return }
        isMicOn = false
        rtc.setMicEnabled(false)
        updateLocalParticipant { $0.isMicOn = false }
        showToast(.micPermissionDenied())
    }

    func rtcDidReceiveMessage(_ message: ChatMessage) {
        messages.append(message)

        let isMine = (message.senderID == localUser?.id)
        // 自己发的消息、系统消息都不该计入未读；聊天面板开着时也不需要小红点。
        if !message.isSystem, !isMine, activePanel != .chat {
            unreadCount += 1
        }
    }

    // MARK: 远端媒体视图

    func rtcDidReceiveRemoteVideo(_ view: UIView, for userID: String) {
        remoteVideoViews[userID] = view
        // 这里**不能**因为收到摄像头帧就把共享态清掉。
        // 远端共享时通常同时开着摄像头轨道，服务端也会周期性重推 participants 快照，
        // 一旦摄像头帧晚到一点，共享画面就会"闪一下又回到宫格"。
        // 共享的结束只由两条明确信号驱动：媒体丢失（rtcDidLoseRemoteMedia）
        // 或共享者离开列表（removeParticipant）。
    }

    func rtcDidReceiveRemoteScreen(_ view: UIView, for userID: String) {
        let isNewSharer = remoteScreenPeerID != userID
        remoteScreenViews[userID] = view
        remoteScreenPeerID = userID
        if isNewSharer {
            remoteShareStartedAt = Date()
            remoteShareDurationText = "00:00"
        }
        let sharerName = DisplayName.clean(participants.first(where: { $0.id == userID })?.name)
        if !sharerName.isEmpty {
            remoteScreenPeerName = sharerName
        }
        // 切到共享展示时收起面板，保证画面完整。
        activePanel = nil
        // 有人开始共享时把控件收起来：共享内容是全场焦点，
        // 顶栏/底栏会直接压住 PPT 的第一行标题（与网页端观感一致）。
        // 只在"刚切到共享"时收，避免观看者手动展开后又被每次快照推回隐藏。
        if isNewSharer {
            isChromeVisible = false
        }
    }

    func rtcDidLoseRemoteMedia(for userID: String) {
        remoteVideoViews.removeValue(forKey: userID)
        remoteScreenViews.removeValue(forKey: userID)
        if remoteScreenPeerID == userID {
            clearRemoteShareState()
        }
    }

    /// 清空远端共享的展示态。
    /// 名字与起始时间必须一起清：只清 peerID 的话，下一个人开始共享时
    /// 会在头 1 秒里显示上一个人的名字和上一场的时长。
    private func clearRemoteShareState() {
        remoteScreenPeerID = nil
        remoteScreenPeerName = ""
        remoteShareStartedAt = nil
        remoteShareDurationText = "00:00"
    }

    // MARK: 房间级事件

    func rtcDidGetMutedByHost() {
        isMicOn = false
        if let index = participants.firstIndex(where: { $0.isLocal }) {
            participants[index].isMicOn = false
        }
        showToast(
            ToastMessage(
                text: "主持人已将你静音",
                systemImage: "mic.slash.fill",
                style: .warning
            )
        )
    }

    func rtcDidGetKicked(by hostName: String) {
        finalizeLocalEnd(
            toast: ToastMessage(
                text: "你已被主持人移出会议",
                systemImage: "person.crop.circle.badge.xmark",
                style: .danger
            ),
            title: "你已被移出会议",
            text: "\(hostName) 将你移出了本次会议",
            canRejoin: false
        )
    }

    func rtcDidMeetingEnd(reason: String) {
        // 自己主动结束会议时本地已清理（disconnected），服务端广播到达时跳过，
        // 否则"会议已结束"提示会被重复弹出。
        if case .disconnected = connectionState { return }
        finalizeLocalEnd(
            toast: ToastMessage(
                text: "会议已结束",
                systemImage: "phone.down.fill",
                style: .danger
            ),
            // 会议已经在服务端结束，重新入会必然失败，不给这个死按钮。
            canRejoin: false
        )
    }

    func rtcDidHostChange(hostPeerID: String, isSelfNowHost: Bool) {
        let wasHost = isHost
        isHost = isSelfNowHost
        if isSelfNowHost && !wasHost {
            showToast(
                ToastMessage(
                    text: "你已成为主持人",
                    systemImage: "crown.fill",
                    style: .success
                )
            )
        }
    }

    func rtcDidRoomLockChange(locked: Bool) {
        isLocked = locked
        showToast(
            ToastMessage(
                text: locked ? "会议已锁定，新成员无法加入" : "会议已解锁",
                systemImage: locked ? "lock.fill" : "lock.open.fill",
                style: .info
            )
        )
    }

    func rtcDidSessionReplaced() {
        finalizeLocalEnd(
            toast: ToastMessage(
                text: "账号已在其他设备登录",
                systemImage: "person.2.fill",
                style: .danger
            ),
            title: "账号在其他设备入会",
            text: "同一账号只能在一个设备参加会议",
            // 这里不能给"重新入会"：点下去会把另一台设备顶掉，
            // 两边来回点就是无限互踢。要换设备，请在那边先退出。
            canRejoin: false
        )
    }

    func rtcDidSessionRevoked() {
        // 账号被禁用 / 密码被重置 / 移出企业：本地会话一并作废，回到登录态。
        AuthStore.clear()
        finalizeLocalEnd(
            toast: ToastMessage(
                text: "账号状态已变更，请重新登录",
                systemImage: "exclamationmark.shield.fill",
                style: .danger
            ),
            title: "账号状态已变更",
            text: "账号被禁用或密码已重置，请重新登录",
            canRejoin: false
        )
    }

    func rtcDidScreenShareRejected(reason: String) {
        // RTC 已停本地推流并回退摄像头轨：这里同步 UI 并让扩展停止广播。
        applyScreenSharing(false, isInitial: true)
        shareBridge.requestStop()
        showToast(
            ToastMessage(
                text: reason,
                systemImage: "rectangle.slash",
                style: .danger
            )
        )
    }

    func rtcDidRejoinFail(message: String) {
        finalizeLocalEnd(
            toast: ToastMessage(
                text: message,
                systemImage: "wifi.exclamationmark",
                style: .danger
            ),
            title: "重新加入失败",
            text: message,
            canRejoin: true
        )
    }
}

// MARK: - 私有实现

private extension MeetingViewModel {

    // MARK: 屏幕共享订阅

    func bindScreenShareIfNeeded() {
        guard cancellables.isEmpty else { return }

        shareBridge.$isBroadcasting
            .removeDuplicates()
            .sink { [weak self] broadcasting in
                // sink 的闭包是 nonisolated 的：即便发布发生在主线程，编译器也不允许
                // 直接调用 @MainActor 方法，所以显式跳一次主线程。
                Task { @MainActor in
                    guard let self = self else { return }

                    let isInitial = !self.hasAppliedInitialShareState
                    self.hasAppliedInitialShareState = true
                    let previous = self.lastBridgeBroadcasting
                    self.lastBridgeBroadcasting = broadcasting

                    self.applyScreenSharing(broadcasting, isInitial: isInitial)

                    if !broadcasting {
                        // 扩展已确认结束、或存活检测把这些脏状态清了：
                        // 去抖时间戳必须一起清，否则下一次"停止共享"会被上一次的请求窗口挡住。
                        self.pendingStopAt = nil
                    }

                    // 首次订阅只同步状态：冷启动时扩展可能早就在跑，此时弹"共享已开始"
                    // 是对上一场会议的误报（见 D-08）。
                    guard !isInitial, let previous = previous, previous != broadcasting else { return }
                    if broadcasting {
                        self.showToast(.screenShareStarted())
                    } else {
                        // 会议已结束时不再弹"屏幕共享已结束"：那条提示会把刚弹出的
                        // "会议已结束"顶掉，用户会以为结束会议没成功（D-11 / P2-6）。
                        let meetingEnded: Bool
                        if case .disconnected = self.connectionState {
                            meetingEnded = true
                        } else {
                            meetingEnded = false
                        }
                        if !meetingEnded {
                            self.showToast(.screenShareStopped())
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// 共享状态的同步点：只改状态与 RTC 调用，不负责弹提示。
    /// 提示属于"状态跃迁"的语义，交给 sink 里的 previous/broadcasting 比较：
    /// 如果在这里弹，`stopScreenShare` 与 `validateLiveness` 两条路径会各弹一次，用户看到重复提示（见 D-07）。
    /// - Parameters:
    ///   - broadcasting: 来自 ScreenShareBridge 的真实状态。
    ///   - isInitial: 是否是冷启动后的第一次同步。
    func applyScreenSharing(_ broadcasting: Bool, isInitial: Bool) {
        guard isScreenSharing != broadcasting else { return }
        isScreenSharing = broadcasting

        if broadcasting {
            // 共享时优先保证画面与警示条可见，任何面板都让位。
            activePanel = nil
            isChromeVisible = true
            pendingStopAt = nil
            didWarnPendingShare = false
            // 新一轮共享：诊断计数从零开始，否则面板里会混着上一场的数字。
            ScreenShareRuntime.reset()
            shareFailure = nil
            // 首次同步不调：扩展早就在跑，重复 start 只是往日志里灌噪音。
            if !isInitial {
                rtc.startScreenShare()
            }
            // 真实链路：开始把 App Group 里的共享帧推上 video sender。
            rtc.beginScreenFramePush()
        } else {
            shareDurationText = "00:00"
            pendingStopAt = nil
            // 真实链路：停止推流并换回摄像头轨。
            rtc.endScreenFramePush()
            if !isInitial {
                rtc.stopScreenShare()
            }
        }
    }

    // MARK: 计时器

    func startTickerIfNeeded() {
        guard ticker == nil else { return }

        // 会议时长只在第一次进场时起算，重进页面不该把计时归零。
        if sessionStart == nil {
            sessionStart = Date()
        }
        refreshClocks()

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + 1.0,
            repeating: 1.0,
            leeway: .milliseconds(200)
        )
        source.setEventHandler { [weak self] in
            // DispatchSource 的 handler 不保证带 actor 上下文，
            // 这里统一用 Task { @MainActor } 显式回到主线程，任何编译器版本都不会有歧义。
            Task { @MainActor in
                self?.refreshClocks()
            }
        }
        ticker = source
        // 同时交给盒子一份，保证 deinit 能取消（deinit 读不到 ticker 属性）。
        teardown.store(timer: source)
        source.resume()
    }

    func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    func refreshClocks() {
        let now = Date()
        clockTickCount &+= 1

        if let start = sessionStart {
            durationText = Self.formatClock(now.timeIntervalSince(start))
        }

        // 屏幕共享与 App Group 的对账挂在这里。
        //
        // 从"每 2 秒"提到"每秒"：共享状态是从另一个进程读回来的，2 秒的轮询
        // 叠加 Darwin 通知的偶发丢失，会让用户点完"开始直播"后盯着屏幕等两秒
        // 还没反应，体感就是"没连上"。读的只是共享容器里几百字节的 JSON，
        // 一秒一次的代价可以忽略。
        shareBridge.refreshState()

        // 扩展侧上报的失败只提示一次。
        if shareFailure == nil, let failure = shareBridge.failure {
            shareFailure = failure
            // 1.5.4：App Group 不匹配这类失败以前只藏在面板里，
            // 用户点完共享回到会议界面就再也看不到。直接弹一次，
            // 把"扩展根本没起来"和"起来了但没画面"彻底分开。
            showToast(
                ToastMessage(
                    text: failure,
                    systemImage: "exclamationmark.triangle.fill",
                    style: .danger
                )
            )
        }

        // 用户点了开始共享、系统面板也弹了，但 6 秒内扩展一个状态都没写回来：
        // 多半是在系统面板里点了取消，或者旧广播卡在"停止中"。
        // 不提示的话，界面看起来就是"点了没反应"。
        if !isScreenSharing,
           !didWarnPendingShare,
           let requested = shareBridge.pendingRequestAt,
           now.timeIntervalSince(requested) > 6 {
            didWarnPendingShare = true
            showToast(
                ToastMessage(
                    text: "没有收到共享扩展的状态。请确认系统弹窗里点了「开始直播」；若仍无反应，多半是当前签名没有把 App Group 授予扩展，需要重签安装。",
                    systemImage: "dot.radiowaves.left.and.right",
                    style: .warning
                )
            )
        }

        if clockTickCount % 4 == 0 {
            shareBridge.validateLiveness()
        }

        if isScreenSharing, let shareStart = shareBridge.startedAt {
            shareDurationText = Self.formatShortClock(now.timeIntervalSince(shareStart))
        } else if !isScreenSharing {
            shareDurationText = "00:00"
        }

        // 远端共享的时长只能本地计时：服务端 screen:state 只告诉"谁在共享"，
        // 不带开始时间。走同一拍计时器，避免为一行文字再起一个 Timer。
        if let remoteStart = remoteShareStartedAt {
            remoteShareDurationText = Self.formatShortClock(now.timeIntervalSince(remoteStart))
        } else if remoteShareDurationText != "00:00" {
            remoteShareDurationText = "00:00"
        }
    }

    // MARK: 本机用户

    func updateLocalParticipant(_ mutate: (inout MeetingUser) -> Void) {
        guard let index = participants.firstIndex(where: { $0.isLocal }) else { return }
        mutate(&participants[index])
    }

    // MARK: 格式化

    /// 把数字串按固定长度分组，用空格分隔。非数字字符（分隔符、括号）会被丢弃，
    /// 这样上游无论给 "862447109" 还是 "862 447-109" 都能得到同一个展示结果。
    static func groupDigits(_ raw: String, groupSize: Int) -> String {
        guard groupSize > 0 else { return raw }
        let digits = raw.filter { $0.isNumber }
        guard digits.count > groupSize else { return digits }

        var groups: [String] = []
        var current = ""
        for character in digits {
            current.append(character)
            if current.count == groupSize {
                groups.append(current)
                current = ""
            }
        }
        // 末组不足一组时就地保留，不补零：补零会造出一个并不存在的会议号。
        if !current.isEmpty {
            groups.append(current)
        }
        return groups.joined(separator: " ")
    }

    /// 会议时长固定六位，避免每秒都在 0:01 / 00:01:02 之间跳宽度。
    static func formatClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    /// 共享时长只有分钟级，六位反而显得空。
    static func formatShortClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    // MARK: 本机用户构造

    /// 用当前开关值构造本机用户。
    ///
    /// 以前这里是 `static` 且硬编码 `isMicOn: true, isCameraOn: true`，
    /// 导致重新入会后参会人列表里的本机行与底栏状态互相矛盾（D-03）。
    /// 现在以 @Published 的实时值为准：rejoin 后用户关掉的麦克风不会自己打开。
    func makeLocalUser() -> MeetingUser {
        MeetingUser(
            id: Self.localUserID,
            name: displayName,
            role: isHost ? .host : .participant,
            isMicOn: isMicOn,
            isCameraOn: isCameraOn,
            isHandRaised: isHandRaised,
            isSpeaking: false,
            isLocal: true,
            avatarColorIndex: avatarColorIndex
        )
    }

    // MARK: 入会

    /// 入会终态错误对应的标题：与正文（服务端文案）搭配，避免所有失败都显示同一句「无法加入会议」。
    private static func joinFailureTitle(for code: String) -> String {
        switch code {
        case "KICKED": return "已被移出会议"
        case "LOCKED": return "会议已锁定"
        case "ENDED", "CANCELED": return "会议已结束"
        case "NOT_FOUND", "BAD_NO": return "会议号无效"
        case "EXPIRED": return "预约已过期"
        default: return "无法加入会议"
        }
    }

    /// onAppear 与 rejoin 共用的入会流程：构造本机用户 → rtc.join，失败则回到 disconnected。
    func joinSession() {
        hasLeftLocally = false
        let me = makeLocalUser()
        let options = JoinOptions(
            no: meetingNumber,
            name: displayName,
            password: joinPassword,
            token: joinToken,
            audioOn: isMicOn,
            videoOn: isCameraOn
        )
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await self.rtc.join(roomID: self.meetingNumber, me: me, options: options)

                // 握手期间用户已经离会：不要再往界面上写任何"入会成功"的状态。
                guard !self.hasLeftLocally else { return }

                // 结束会议后重新入会：sessionStart 已在 endMeeting 里清空，
                // 这里把计时基准复位到"入会成功"的瞬间，durationText 从 00:00:00 重新走（H-3）。
                // 首次入会时 startTickerIfNeeded 已经起过基准，不能覆盖，
                // 否则计时会悄悄少掉入会握手那段时间。
                if self.sessionStart == nil {
                    self.sessionStart = Date()
                    self.durationText = "00:00:00"
                }
                // 入会成功后同步本地预览视图。
                self.localPreviewView = self.rtc.localPreviewView()
            } catch let joinError as RTCJoinError {
                // 主动离会导致的失败不是"入会失败"，不要用错误页盖掉离会结果。
                guard !self.hasLeftLocally else { return }
                self.connectionState = .disconnected
                // 终态错误（会议已结束/被移出/已锁定/号无效/预约过期）重试也不会成功，
                // 直接隐藏「重新入会」，避免用户反复点同一个失败按钮。
                let terminal = ["KICKED", "LOCKED", "ENDED", "CANCELED", "NOT_FOUND", "BAD_NO", "EXPIRED"]
                    .contains(joinError.code)
                self.endTitle = terminal ? Self.joinFailureTitle(for: joinError.code) : "无法加入会议"
                self.endText = joinError.message
                self.endCanRejoin = !terminal
                self.showToast(
                    ToastMessage(
                        text: joinError.message,
                        systemImage: "exclamationmark.triangle.fill",
                        style: .danger
                    )
                )
            } catch {
                guard !self.hasLeftLocally else { return }
                self.connectionState = .disconnected
                self.endTitle = "无法加入会议"
                self.endText = "加入会议失败，请检查网络"
                self.endCanRejoin = true
                self.showToast(
                    ToastMessage(
                        text: "加入会议失败，请检查网络",
                        systemImage: "exclamationmark.triangle.fill",
                        style: .danger
                    )
                )
            }
        }
    }
}

// MARK: - 销毁清理盒

/// `@MainActor` 类的 `deinit` 是 nonisolated 的，不能访问 actor 隔离的存储属性。
/// 这个盒子用 `nonisolated let` 持有，内部加锁，专门给 deinit 提供一条合法的清理路径。
/// 与 ScreenShareBridge 里的 ObserverTokenBag 是同一个模式的变体（那边存 token，这边存对象）。
final class MeetingTeardownBox: @unchecked Sendable {

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var client: RTCClient?

    func store(timer newTimer: DispatchSourceTimer) {
        lock.lock()
        let previous = self.timer
        self.timer = newTimer
        lock.unlock()
        // 换新计时器时顺手取消旧的，避免新旧两个计时器同时刷新时长。
        previous?.cancel()
    }

    func store(client newClient: RTCClient) {
        lock.lock()
        self.client = newClient
        lock.unlock()
    }

    /// 取出并清空，随后取消计时器、让 RTC 退出会议。
    /// 先取快照再放锁，避免持锁执行外部代码（leave 可能回调 delegate）。
    func invalidate() {
        lock.lock()
        let timerToCancel = timer
        let clientToLeave = client
        timer = nil
        client = nil
        lock.unlock()

        timerToCancel?.cancel()
        // RTCClient 隔离到 @MainActor：切回主线程执行，快照捕获的是具体对象，
        // 不捕获正在销毁的 ViewModel。
        if let clientToLeave = clientToLeave {
            Task { @MainActor in
                clientToLeave.leave()
            }
        }
    }
}
