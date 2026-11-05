//
//  RTCClient.swift
//  MeetingKit
//
//  RTC 抽象层。UI 只依赖这里的协议与事件定义，不关心底层是 Mock 还是真实 SDK。
//
//  约定：
//    1. 所有 delegate 回调都保证在主线程触发（实现方负责，见 publish 模式）；
//    2. 方法调用均视为幂等，重复 join / leave 不产生副作用；
//    3. 错误只从 `join` 抛出，其余操作失败通过 delegate 事件体现。
//
//  真实实现（RealRTCClient）对接天穹服务端：
//    · REST：/api/meetings/info/:no 入会前校验、/api/rtc/ice 取 STUN/TURN；
//    · Socket.IO：room:join / rtc:signal / media:state / chat / hand / host 事件；
//    · WebRTC：P2P Mesh，Perfect Negotiation + ICE restart，断线自动重连。
//

import Foundation
import UIKit

// MARK: - 连接状态

/// 会议连接状态机。UI 侧据此展示"连接中 / 已连接 / 重连中 / 已断开"的角标。
enum ConnectionState {
    case connecting
    case connected
    case reconnecting
    case disconnected
}

// MARK: - 网络质量

/// 网络质量档位。`bars` 直接给信号格 UI 用，避免各页面自己写 switch 导致规则不一致。
enum NetworkQuality {
    case good
    case fair
    case poor
    case unknown

    /// 信号格数（0~3）。unknown 为 0，UI 应展示为"未知"而不是"极差"。
    var bars: Int {
        switch self {
        case .good:
            return 3
        case .fair:
            return 2
        case .poor:
            return 1
        case .unknown:
            return 0
        }
    }
}

// MARK: - 入会选项

/// 一次入会的全部上下文。与 JoinInfo 的区别：这里承载的是"RTC 层需要的东西"，
/// 不包含 UI 态（标题、头像色等展示字段）。
struct JoinOptions {
    /// 会议号（纯数字 7 位）。
    var no: String
    /// 展示名。为空时服务端会分配"访客xxxx"。
    var name: String
    /// 入会密码（有密码的会议必须提供）。
    var password: String = ""
    /// 登录令牌。空串 = 访客入会。
    var token: String = ""
    /// 入会时麦克风初始状态。
    var audioOn: Bool = true
    /// 入会时摄像头初始状态。
    var videoOn: Bool = true
}

// MARK: - 入会失败

/// join 抛出的错误。message 可直接展示；code 与 Web 端服务端错误码一致，
/// 需要特殊处理（如"会议未开始"提示等待）时用 code 判断。
struct RTCJoinError: LocalizedError {
    let message: String
    let code: String

    init(message: String, code: String = "JOIN_FAILED") {
        self.message = message
        self.code = code
    }

    var errorDescription: String? { message }
}

// MARK: - 品牌信息

/// 会议的品牌上下文。企业专属会议室会带企业名与号模式，
/// 普通会议 isEnterprise = false，界面不显示任何企业标识。
struct MeetingBrand: Equatable {
    var isEnterprise: Bool = false
    var enterpriseName: String = ""
    /// "fixed" = 固定会议号；"random" = 每场结束自动换号。
    var roomMode: String = "fixed"

    var modeText: String { roomMode == "random" ? "随机号" : "固定号" }
}

// MARK: - 事件回调

/// 全部回调保证在主线程（协议与实现方都隔离到 @MainActor）。
@MainActor
protocol RTCClientDelegate: AnyObject {

    /// 参会者列表变化（有人进出、麦克风/摄像头/举手状态变化、发言人变化）。
    /// 每次都是全量快照，实现方保证顺序，UI 无需做增量合并。
    /// 快照中的本机用户 id 是服务端分配的 peerId（socket id），UI 判断"是不是我"
    /// 一律看 `isLocal`，不要拿 id 与本地常量比较。
    func rtcDidUpdateParticipants(_ participants: [MeetingUser])

    /// 当前发言人变化。nil 表示暂时无人说话。
    func rtcDidChangeActiveSpeaker(_ userID: String?)

    /// 本地网络质量变化。
    func rtcDidChangeNetworkQuality(_ quality: NetworkQuality)

    /// 连接状态变化。
    func rtcDidChangeConnectionState(_ state: ConnectionState)

    /// 收到一条聊天消息（包括其他参会者的消息与系统消息）。
    func rtcDidReceiveMessage(_ message: ChatMessage)

    /// 会议品牌变化（企业专属会议室 / 号模式）。
    /// 默认实现为空，Mock 与旧实现不需要改动。
    func rtcDidUpdateMeetingBrand(_ brand: MeetingBrand)

    /// 远端摄像头视频渲染视图可用（RTCMTLVideoView）。
    /// UI 侧拿到 UIView 后用 UIViewRepresentable 放进对应宫格。
    func rtcDidReceiveRemoteVideo(_ view: UIView, for userID: String)

    /// 远端屏幕共享渲染视图可用。
    func rtcDidReceiveRemoteScreen(_ view: UIView, for userID: String)

    /// 远端媒体视图失效（对方离开 / 关闭摄像头 / 停止共享 / 断线）。
    /// 视频与共享共用此回调，UI 按 userID 清掉对应视图。
    func rtcDidLoseRemoteMedia(for userID: String)

    /// 房间级事件：被主持人静音（此时本机麦克风应被强制关闭）。
    func rtcDidGetMutedByHost()

    /// 房间级事件：被移出会议。
    func rtcDidGetKicked(by hostName: String)

    /// 房间级事件：会议被结束（主持人结束 / 系统结束）。
    func rtcDidMeetingEnd(reason: String)

    /// 房间级事件：主持人离开 / 转移。isSelfNowHost = 本机是否成为新主持人。
    func rtcDidHostChange(hostPeerID: String, isSelfNowHost: Bool)

    /// 房间级事件：锁定状态变化。
    func rtcDidRoomLockChange(locked: Bool)

    /// 房间级事件：本账号在别处登录，本连接被顶下线。
    func rtcDidSessionReplaced()

    /// 账号状态被服务端吊销（禁用/密码重置/移出企业），连接被踢。
    func rtcDidSessionRevoked()

    /// 本机屏幕共享被服务端拒绝（他人正在共享 / 主持人关闭了共享权限）。
    /// 客户端已自动停止本地推流，UI 需要同步状态并提示。
    func rtcDidScreenShareRejected(reason: String)

    /// 断线重连后重新入会失败且不可恢复（会议已结束 / 被移出 / 已锁定等）。
    func rtcDidRejoinFail(message: String)

    /// 本地摄像头的**实际**状态与界面请求不一致时回调。
    ///
    /// 典型场景：用户点开摄像头，但系统权限被拒、或设备上没有可用摄像头。
    /// 此时 RTC 层不能默默失败——界面已经乐观地把图标切成了"开"，
    /// 不回调就等于让用户对着一个永远黑屏的格子。
    func rtcDidUpdateLocalCamera(_ enabled: Bool)

    /// 本地麦克风的实时电平（0...1），约每 180ms 一次。
    ///
    /// 用于说话脉冲：服务端不下发音量（Web 端也是各自在本地算的），
    /// 客户端只能从 getStats 的 media-source 统计里拿。
    func rtcDidUpdateLocalAudioLevel(_ level: Float)
}

extension RTCClientDelegate {
    /// 默认空实现：Mock 与旧实现不需要为这个回调改动。
    func rtcDidUpdateLocalCamera(_ enabled: Bool) {}

    func rtcDidUpdateLocalAudioLevel(_ level: Float) {}
}

// MARK: - 客户端能力

/// 客户端协议隔离到 @MainActor：实现方的全部状态与回调都在主线程，
/// 视图层（@MainActor）无需再做线程跳转。
@MainActor
protocol RTCClient: AnyObject {

    /// 弱引用语义由实现方把控（`weak var delegate`），避免 ViewModel 被客户端持有导致不释放。
    var delegate: RTCClientDelegate? { get set }

    /// 加入会议。重复调用应立即返回（幂等），不得产生第二条连接。
    /// 失败抛 RTCJoinError（含服务端错误码）。
    func join(roomID: String, me: MeetingUser, options: JoinOptions) async throws

    /// 离开会议。重复调用无副作用；离开后必须停掉内部所有定时器与回调。
    func leave()

    func setMicEnabled(_ enabled: Bool)
    func setCameraEnabled(_ enabled: Bool)

    /// 切换前后摄像头。
    func switchCamera()

    /// 扬声器 / 听筒。
    func setSpeakerEnabled(_ enabled: Bool)

    /// 本地摄像头预览视图（真实实现返回 RTCCameraPreviewView）。
    /// Mock / 摄像头关闭时返回 nil，UI 回退头像占位卡。
    func localPreviewView() -> UIView?

    /// 开始 / 停止屏幕共享。
    /// 真实实现里 startScreenShare 只是发起广播请求，真正是否在共享要看 ScreenShareBridge，
    /// 不要用这里的调用状态驱动 UI。
    func startScreenShare()
    func stopScreenShare()

    /// Broadcast 扩展确认"正在共享"后开始推帧（真实实现把 App Group 帧
    /// replaceTrack 到每个 peer 的 video sender）；确认停止后恢复摄像头轨。
    func beginScreenFramePush()
    func endScreenFramePush()

    /// 发送一条文本消息。
    func sendMessage(_ text: String)

    /// 举手 / 取消举手。
    func setHandRaised(_ raised: Bool)

    // MARK: 主持人操作（非主持人调用由服务端拒绝，客户端静默）

    /// 强制静音某人。
    func mutePeer(_ userID: String)

    /// 全体静音。
    func muteAllPeers()

    /// 移出某人。
    func removePeer(_ userID: String)

    /// 移交主持人。
    func transferHost(to userID: String)

    /// 锁定 / 解锁会议。
    func setRoomLocked(_ locked: Bool)

    /// 结束会议（通知服务端收尾）。
    func endMeeting()
}

// MARK: - 远端媒体描述

/// 远端用户 id ↔ 渲染视图。UI 层通过 ViewModel 的字典读取，
/// 避免在 SwiftUI 里持有 RTC 对象。
struct RemoteMediaKey: Hashable {
    let userID: String
}


// 默认实现：不关心品牌信息的实现方（Mock / 测试）无需重写。
@MainActor
extension RTCClientDelegate {
    func rtcDidUpdateMeetingBrand(_ brand: MeetingBrand) {}
}
