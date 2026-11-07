//
//  TianqiongSignaling.swift
//  MeetingKit
//
//  天穹服务端的 Socket.IO 信令封装。事件名与载荷逐字对齐
//  server/realtime.js，iOS 端不发明任何协议。
//
//  职责边界：
//    · 只管"消息怎么发、事件怎么收"，不懂 WebRTC（SDP 原样透传）；
//    · 断线重连交给 Socket.IO 内建机制（无限次重试），重连成功后由上层
//      RealRTCClient 重新 room:join 并做 ICE restart；
//    · 所有 delegate 回调保证在主线程。
//
//  协议速览（与 Web 端 room.js 完全一致）：
//    上行：room:join / rtc:signal / media:state / chat:send / hand:set
//          host:mute / host:muteAll / host:kick / host:transfer / host:lock / meeting:end
//          room:leave
//    下行：peer:joined / peer:left / peer:media / peer:hand / chat:new / reaction
//          screen:state / screen:busy / screen:denied
//          host:mute / host:kick / host:changed / host:away / room:locked
//          meeting:started / meeting:ended / session:replaced
//

import Foundation

/// 信令层的失败原因。
/// Result 的 Failure 必须实现 Error；直接用 String 会报
/// "type 'String' does not conform to protocol 'Error'"。
struct SignalingFailure: Error {
    let message: String
}
import SocketIO

// MARK: - 连接配置

enum TianqiongSignalingConfig {

    /// 服务端地址。与 REST 同域（TianqiongAPI.origin），path=/socket.io。
    static var url: URL { TianqiongAPI.origin }

    static let path = "/socket.io"
}

// MARK: - 事件回调

/// 全部回调保证在主线程（协议与实现方都隔离到 @MainActor）。
@MainActor
protocol TianqiongSignalingDelegate: AnyObject {

    func signalingDidConnect(_ signaling: TianqiongSignaling)
    func signalingDidDisconnect(_ signaling: TianqiongSignaling, reason: String)
    func signalingDidFailToConnect(_ signaling: TianqiongSignaling, reason: String)

    /// 收到对端信令。sdp 与 candidate 二选一非空；restart 表示对端发起的 ICE restart。
    func signaling(
        _ signaling: TianqiongSignaling,
        didReceiveSignalFrom peerID: String,
        sdp: [String: Any]?,
        candidate: [String: Any]?,
        restart: Bool
    )

    /// 入会回执里的完整快照。
    func signaling(
        _ signaling: TianqiongSignaling,
        didJoin selfInfo: [String: Any],
        peers: [[String: Any]],
        messages: [[String: Any]],
        meeting: [String: Any],
        locked: Bool,
        screenPeerID: String?
    )

    func signaling(_ signaling: TianqiongSignaling, peerJoined peer: [String: Any])
    func signaling(_ signaling: TianqiongSignaling, peerLeft peerID: String, name: String, reason: String)
    func signaling(_ signaling: TianqiongSignaling, peerMedia peerID: String, audio: Bool?, video: Bool?, screen: Bool?)
    func signaling(_ signaling: TianqiongSignaling, peerHand peerID: String, name: String, raised: Bool)
    func signaling(_ signaling: TianqiongSignaling, chatMessage message: [String: Any])
    func signaling(_ signaling: TianqiongSignaling, reaction peerID: String, name: String, emoji: String)
    func signaling(_ signaling: TianqiongSignaling, screenState peerID: String, on: Bool, resumed: Bool)
    func signaling(_ signaling: TianqiongSignaling, screenBusy peerID: String)
    func signaling(_ signaling: TianqiongSignaling, screenDenied _: ())
    func signaling(_ signaling: TianqiongSignaling, mutedByHost _: ())
    func signaling(_ signaling: TianqiongSignaling, kickedBy hostName: String)
    func signaling(_ signaling: TianqiongSignaling, hostChanged hostPeerID: String, hostUserID: Int, hostName: String)
    func signaling(_ signaling: TianqiongSignaling, hostAway name: String, graceSeconds: Int)
    func signaling(_ signaling: TianqiongSignaling, roomLocked locked: Bool)
    func signaling(_ signaling: TianqiongSignaling, meetingEnded by: String, reason: String)
    func signaling(_ signaling: TianqiongSignaling, meetingStarted no: String)
    func signalingSessionReplaced(_ signaling: TianqiongSignaling)
    /// 账号被管理员禁用 / 密码被重置 / 移出企业：服务端主动吊销会话并踢线。
    func signalingSessionRevoked(_ signaling: TianqiongSignaling)
}

// MARK: - 信令客户端

/// 隔离到 @MainActor：所有状态与 delegate 回调都在主线程。
/// Socket.IO 的事件闭包在库内部队列执行，统一用 Task { @MainActor } 汇流。
@MainActor
final class TianqiongSignaling {

    weak var delegate: TianqiongSignalingDelegate?

    /// 当前连接是否可用（连接成功且未断开）。
    private(set) var isConnected = false

    /// 最近一次入会回执（重连恢复时上层要重新读取）。
    private(set) var lastJoinSnapshot: JoinSnapshot?

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private let token: String

    init(token: String) {
        self.token = token
    }

    // MARK: - 连接

    func connect() {
        guard manager == nil else {
            // 已在连接流程中：Socket.IO 自己会重试，无需重复建连。
            guard let socket = socket else { return }
            switch socket.status {
            case .connected:
                delegate?.signalingDidConnect(self)
            case .notConnected, .disconnected:
                // 从后台回来时连接可能已经被系统掐断，且指数退避可能已经拉到
                // 10 秒一次。这里立刻拉一次，别让用户对着"正在重连"干等。
                socket.connect()
            default:
                break
            }
            return
        }

        var config: SocketIOClientConfiguration = [
            .path(TianqiongSignalingConfig.path),
            .forceWebsockets(true),
            .reconnects(true),
            .reconnectAttempts(-1),          // 无限重试，直到用户离开会议
            .reconnectWait(1),
            .reconnectWaitMax(10),
            .compress,
            .log(false),
        ]
        if !token.isEmpty {
            // Socket.IO-Client-Swift 16 没有 .auth 配置项（auth 是协议 v5 的能力，
            // 这个库还没暴露），只能走 query 参数；服务端已兼容 handshake.query.token。
            config.insert(.connectParams(["token": token]))
        }

        let manager = SocketManager(
            socketURL: TianqiongSignalingConfig.url,
            config: config
        )
        self.manager = manager
        let socket = manager.defaultSocket
        self.socket = socket

        bindEvents(on: socket)
        socket.connect()
    }

    func disconnect() {
        lastJoinSnapshot = nil
        socket?.removeAllHandlers()
        socket?.disconnect()
        socket = nil
        manager?.disconnect()
        manager = nil
        isConnected = false
    }

    /// 从后台回到前台时用：只在确实断开时重连，不会重复触发 didConnect。
    ///
    /// 为什么不用 `connect()`：它在已连接时会回调 `signalingDidConnect`，
    /// 上层收到就会再走一遍 room:join + 重建 PeerConnection——
    /// 用户只是切了个 App，不该付一次全量重连的代价。
    func reconnectIfNeeded() {
        guard manager != nil, let socket = socket else { return }
        switch socket.status {
        case .notConnected, .disconnected:
            socket.connect()
        default:
            break
        }
    }

    // MARK: - 上行消息

    /// 入会。ack 一定触发（成功或失败），超时也会触发失败回执。
    func join(
        no: String,
        name: String,
        password: String,
        audio: Bool,
        video: Bool,
        screen: Bool = false,
        timeout: TimeInterval = 12,
        completion: @escaping (Result<JoinSnapshot, JoinFailure>) -> Void
    ) {
        guard let socket = socket, socket.status == .connected else {
            completion(.failure(JoinFailure(code: "DISCONNECTED", message: "信令连接未就绪")))
            return
        }

        let media: [String: Bool] = ["audio": audio, "video": video, "screen": screen]
        var payload: [String: Any] = [
            "no": no,
            "name": name,
            "media": media,
            // 稳定设备标识：断线重连时服务端靠它认出"还是同一个人"，
            // 从而静默接管旧记录，而不是先广播离开再广播加入。
            "clientId": DeviceIdentity.id,
        ]
        if !password.isEmpty {
            payload["password"] = password
        }

        socket.emitWithAck("room:join", payload).timingOut(after: timeout) { [weak self] raw in
            // ack 闭包在库内部队列，汇流回主线程再解析。
            let dict = raw.first as? [String: Any]
            Task { @MainActor in
                guard let self = self else { return }
                // 中途 leave() 又重建连接后，旧连接的迟到回执必须丢弃。
                guard self.socket === socket else { return }
                guard let dict = dict else {
                    completion(.failure(JoinFailure(code: "TIMEOUT", message: "入会超时，请检查网络")))
                    return
                }
                if dict["ok"] as? Bool == true {
                    let snapshot = JoinSnapshot(raw: dict)
                    self.lastJoinSnapshot = snapshot
                    completion(.success(snapshot))
                } else {
                    completion(
                        .failure(
                            JoinFailure(
                                code: dict["code"] as? String ?? "JOIN_FAILED",
                                message: dict["error"] as? String ?? "加入会议失败"
                            )
                        )
                    )
                }
            }
        }
    }

    /// 主动离开（让服务端立即释放位置，不等断线宽限）。
    func leaveRoom() {
        socket?.emit("room:leave")
    }

    /// WebRTC 信令透传。
    func sendSignal(
        to peerID: String,
        sdp: [String: Any]?,
        candidate: [String: Any]?,
        restart: Bool = false,
        round: String? = nil
    ) {
        var data: [String: Any] = [:]
        if var sdp = sdp {
            /* 轮次号塞进 sdp 字典：服务器只白名单透传 sdp.type / sdp.sdp，
               放在外层 data 上会被直接丢掉。 */
            if let round = round { sdp["rid"] = round }
            data["sdp"] = sdp
        }
        if let candidate = candidate { data["candidate"] = candidate }
        if restart { data["restart"] = true }
        guard !data.isEmpty else { return }
        socket?.emit("rtc:signal", ["to": peerID, "data": data])
    }

    func sendMediaState(audio: Bool?, video: Bool?, screen: Bool?) {
        var payload: [String: Any] = [:]
        if let audio = audio { payload["audio"] = audio }
        if let video = video { payload["video"] = video }
        if let screen = screen { payload["screen"] = screen }
        guard !payload.isEmpty else { return }
        socket?.emit("media:state", payload)
    }

    func sendChat(
        content: String,
        completion: @escaping (Result<Int, SignalingFailure>) -> Void
    ) {
        socket?.emitWithAck("chat:send", ["content": content]).timingOut(after: 8) { [weak self] raw in
            let dict = raw.first as? [String: Any]
            Task { @MainActor in
                guard let self = self else { return }
                guard let dict = dict else {
                    completion(.failure(SignalingFailure(message: "发送超时，请重试")))
                    return
                }
                if dict["ok"] as? Bool == true {
                    completion(.success(dict["id"] as? Int ?? 0))
                } else {
                    completion(.failure(SignalingFailure(message: dict["error"] as? String ?? "发送失败")))
                }
            }
        }
    }

    func sendHand(raised: Bool) {
        socket?.emit("hand:set", ["raised": raised])
    }

    // MARK: 主持人操作

    func mutePeer(_ peerID: String) {
        socket?.emit("host:mute", ["peerId": peerID])
    }

    func muteAll() {
        socket?.emit("host:muteAll")
    }

    func kickPeer(_ peerID: String) {
        socket?.emit("host:kick", ["peerId": peerID])
    }

    func transferHost(to peerID: String) {
        socket?.emit("host:transfer", ["peerId": peerID])
    }

    func setLocked(_ locked: Bool) {
        socket?.emit("host:lock", ["locked": locked])
    }

    func endMeeting() {
        socket?.emit("meeting:end")
    }

    // MARK: - 事件绑定

    private func bindEvents(on socket: SocketIOClient) {
        // Socket.IO 的事件闭包不保证在主线程（取决于库内部 handleQueue）。
        // 本类隔离到 @MainActor，所有事件统一 Task { @MainActor } 汇流。
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.isConnected = true
                self.delegate?.signalingDidConnect(self)
            }
        }
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.isConnected = false
                self.delegate?.signalingDidDisconnect(self, reason: "socket-disconnect")
            }
        }
        socket.on(clientEvent: .error) { [weak self] data, _ in
            let reason = data.first.map { String(describing: $0) } ?? "socket-error"
            Task { @MainActor in
                guard let self = self else { return }
                // 已连接状态下也可能派发 error（如单个包损坏）：
                // 只有真正掉线（非 connected）才改状态，避免把 UI 误拉进重连态。
                if self.socket?.status != .connected {
                    self.isConnected = false
                    self.delegate?.signalingDidFailToConnect(self, reason: reason)
                }
            }
        }

        socket.on("rtc:signal") { [weak self] data, _ in
            let dict = data.first as? [String: Any]
            let from = dict?["from"] as? String
            let payload = dict?["data"] as? [String: Any]
            Task { @MainActor in
                guard let self = self, let from = from, let payload = payload else { return }
                self.delegate?.signaling(
                    self,
                    didReceiveSignalFrom: from,
                    sdp: payload["sdp"] as? [String: Any],
                    candidate: payload["candidate"] as? [String: Any],
                    restart: payload["restart"] as? Bool ?? false
                )
            }
        }

        socket.on("peer:joined") { [weak self] data, _ in
            let peer = (data.first as? [String: Any])?["peer"] as? [String: Any]
            Task { @MainActor in
                guard let self = self, let peer = peer else { return }
                self.delegate?.signaling(self, peerJoined: peer)
            }
        }

        socket.on("peer:left") { [weak self] data, _ in
            let dict = data.first as? [String: Any]
            let peerID = dict?["peerId"] as? String
            let name = dict?["name"] as? String ?? ""
            let reason = dict?["reason"] as? String ?? "left"
            Task { @MainActor in
                guard let self = self, let peerID = peerID else { return }
                self.delegate?.signaling(self, peerLeft: peerID, name: name, reason: reason)
            }
        }

        socket.on("peer:media") { [weak self] data, _ in
            let dict = data.first as? [String: Any]
            let peerID = dict?["peerId"] as? String
            let audio = dict?["audio"] as? Bool
            let video = dict?["video"] as? Bool
            let screen = dict?["screen"] as? Bool
            Task { @MainActor in
                guard let self = self, let peerID = peerID else { return }
                self.delegate?.signaling(self, peerMedia: peerID, audio: audio, video: video, screen: screen)
            }
        }

        socket.on("peer:hand") { [weak self] data, _ in
            let dict = data.first as? [String: Any]
            let peerID = dict?["peerId"] as? String
            let name = dict?["name"] as? String ?? ""
            let raised = dict?["raised"] as? Bool ?? false
            Task { @MainActor in
                guard let self = self, let peerID = peerID else { return }
                self.delegate?.signaling(self, peerHand: peerID, name: name, raised: raised)
            }
        }

        socket.on("chat:new") { [weak self] data, _ in
            let dict = data.first as? [String: Any]
            Task { @MainActor in
                guard let self = self, let dict = dict else { return }
                self.delegate?.signaling(self, chatMessage: dict)
            }
        }

        socket.on("reaction") { [weak self] data, _ in
            let dict = data.first as? [String: Any]
            let peerID = dict?["peerId"] as? String
            let name = dict?["name"] as? String ?? ""
            let emoji = dict?["emoji"] as? String ?? ""
            Task { @MainActor in
                guard let self = self, let peerID = peerID else { return }
                self.delegate?.signaling(self, reaction: peerID, name: name, emoji: emoji)
            }
        }

        socket.on("screen:state") { [weak self] data, _ in
            let dict = data.first as? [String: Any]
            let peerID = dict?["peerId"] as? String
            let on = dict?["on"] as? Bool ?? false
            let resumed = dict?["resumed"] as? Bool ?? false
            Task { @MainActor in
                guard let self = self, let peerID = peerID else { return }
                self.delegate?.signaling(self, screenState: peerID, on: on, resumed: resumed)
            }
        }

        socket.on("screen:busy") { [weak self] data, _ in
            let peerID = (data.first as? [String: Any])?["peerId"] as? String
            Task { @MainActor in
                guard let self = self, let peerID = peerID else { return }
                self.delegate?.signaling(self, screenBusy: peerID)
            }
        }

        socket.on("screen:denied") { [weak self] _, _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.signaling(self, screenDenied: ())
            }
        }

        socket.on("host:mute") { [weak self] _, _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.signaling(self, mutedByHost: ())
            }
        }

        socket.on("host:kick") { [weak self] data, _ in
            let by = (data.first as? [String: Any])?["by"] as? String ?? "主持人"
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.signaling(self, kickedBy: by)
            }
        }

        socket.on("host:changed") { [weak self] data, _ in
            let dict = data.first as? [String: Any]
            let peerID = dict?["hostPeerId"] as? String
            let hostUserID = dict?["hostUserId"] as? Int ?? 0
            let hostName = dict?["hostName"] as? String ?? ""
            Task { @MainActor in
                guard let self = self, let peerID = peerID else { return }
                self.delegate?.signaling(self, hostChanged: peerID, hostUserID: hostUserID, hostName: hostName)
            }
        }

        socket.on("host:away") { [weak self] data, _ in
            let dict = data.first as? [String: Any]
            let name = dict?["name"] as? String ?? "主持人"
            let grace = dict?["graceSeconds"] as? Int ?? 45
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.signaling(self, hostAway: name, graceSeconds: grace)
            }
        }

        socket.on("room:locked") { [weak self] data, _ in
            let locked = (data.first as? [String: Any])?["locked"] as? Bool ?? false
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.signaling(self, roomLocked: locked)
            }
        }

        socket.on("meeting:started") { [weak self] data, _ in
            let no = (data.first as? [String: Any])?["no"] as? String
            Task { @MainActor in
                guard let self = self, let no = no else { return }
                self.delegate?.signaling(self, meetingStarted: no)
            }
        }

        socket.on("meeting:ended") { [weak self] data, _ in
            let dict = data.first as? [String: Any]
            let by = dict?["by"] as? String ?? "主持人"
            let reason = dict?["reason"] as? String ?? "host"
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.signaling(self, meetingEnded: by, reason: reason)
            }
        }

        socket.on("session:replaced") { [weak self] _, _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.signalingSessionReplaced(self)
            }
        }

        socket.on("session:revoked") { [weak self] _, _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.signalingSessionRevoked(self)
            }
        }
    }
}

// MARK: - 入会回执快照

/// room:join 成功回执的解析结果。字段名与服务端 publicParticipant 一致。
struct JoinSnapshot {

    let selfPeerID: String
    let selfName: String
    let selfRole: String
    let selfInfo: [String: Any]
    let peers: [[String: Any]]
    let messages: [[String: Any]]
    let locked: Bool
    let screenPeerID: String?
    let meeting: [String: Any]
    let resumed: Bool

    init(raw: [String: Any]) {
        let selfInfo = raw["self"] as? [String: Any] ?? [:]
        selfPeerID = selfInfo["peerId"] as? String ?? ""
        selfName = selfInfo["name"] as? String ?? ""
        selfRole = selfInfo["role"] as? String ?? "attendee"
        self.selfInfo = selfInfo
        peers = raw["peers"] as? [[String: Any]] ?? []
        messages = raw["messages"] as? [[String: Any]] ?? []
        locked = raw["locked"] as? Bool ?? false
        screenPeerID = raw["screenPeerId"] as? String
        meeting = raw["meeting"] as? [String: Any] ?? [:]
        resumed = raw["resumed"] as? Bool ?? false
    }
}

/// room:join 失败回执。
struct JoinFailure: Error {
    let code: String
    let message: String
}
