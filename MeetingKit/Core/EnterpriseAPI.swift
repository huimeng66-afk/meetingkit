//
//  EnterpriseAPI.swift
//  MeetingKit
//
//  企业空间的数据层：企业概览、专属会议室、号码模式、企业会议列表。
//
//  为什么独立成文件：这些接口只服务企业空间一个页面，错误语义（未加入企业、
//  仅管理员可改）也只属于这里。全部塞进 APIClient 会让那个文件从"登录与基础
//  会议信息"膨胀成业务杂物间；但请求管线必须复用 APIClient.request —— 超时、
//  Bearer 头、服务端 error 文案只有一份，才能避免某个接口漏带 token。
//
//  模型全部用显式 JSON 解析而不是 Codable：服务端的字段经常是 null 与缺失并存
//  （scheduledAt、startedAt、code、adminId 都可能为空），Codable 的自动合成会把
//  "一个展示字段缺失"升级成"整条响应解码失败"。这里的规则是：字段缺失给安全
//  默认值，只有会议号 no 缺失才算这条数据不可用。
//
//  所有回调都保证主线程：APIClient 已在主线程回调，本文件再兜住"未登录"这类
//  同步提前返回的路径，调用方可以直接写 @State。
//

import Foundation

// MARK: - 号码模式

/// 企业会议室的号码策略，rawValue 与服务端 room_mode 字段逐字对齐。
///
/// 解析失败的兜底是 .fixed：未知值当成固定号，至少不会在 UI 上显示一个服务端
/// 并不认识的选项，也不会因为一个枚举值把整张会议室卡片打成错误态。
enum EnterpriseRoomMode: String, CaseIterable, Hashable {

    case fixed
    case random

    var title: String {
        switch self {
        case .fixed:
            return "固定号"
        case .random:
            return "随机号"
        }
    }

    /// 解释"这个模式意味着什么"，而不是重复模式名。
    /// 用户真正关心的是号码会不会变、什么时候变。
    var hint: String {
        switch self {
        case .fixed:
            return "号码保持不变，成员随时可以进入。"
        case .random:
            return "每场会议结束后自动换号，旧号码随即失效。"
        }
    }
}

// MARK: - 错误

enum EnterpriseError: LocalizedError {

    case notSignedIn
    case server(String)
    case network(String)
    case invalidResponse(String)

    var errorDescription: String? { message }

    var message: String {
        switch self {
        case .notSignedIn:
            return "请先登录后再使用企业空间"
        case .server(let text), .network(let text), .invalidResponse(let text):
            return text
        }
    }

    /// 服务端用 error 文案而不是状态码表达"未加入企业"，而 APIClient.request
    /// 只回传文案、不暴露 HTTP 状态。这里只能按关键词识别：误判的代价只是把
    /// 错误卡显示成"未加入企业"的空态；反过来（把错误当成未加入）则会伪造一个
    /// 服务端并不承认的空态，所以宁可只认服务端自己的原话。
    var isNotInEnterprise: Bool {
        message.contains("未加入企业")
    }

    static func isNotInEnterprise(_ error: Error) -> Bool {
        wrap(error).isNotInEnterprise
    }

    /// 把任意来源的错误收敛成 EnterpriseError。
    ///
    /// 服务端文案必须原样透传：用户看到的"成员名额已满"远比"请求失败"有用。
    /// 网络错误由 APIClient 先转成中文；这里再兜一次 URLError，是为了防止将来
    /// 某条新接口绕过那条管线时，把英文的域名/超时错误直接漏给用户。
    static func wrap(_ error: Error) -> EnterpriseError {
        if let enterprise = error as? EnterpriseError {
            return enterprise
        }
        if let api = error as? APIClient.APIError {
            // APIClient 无法区分"服务端业务错误"与"传输层错误"，
            // 两者的文案都已经是中文，这里统一按服务端语义透传，不再二次猜测。
            return .server(api.message)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .network("连接超时，请检查网络后重试")
            case .notConnectedToInternet:
                return .network("当前无网络连接")
            case .cannotFindHost, .cannotConnectToHost:
                return .network("无法连接到会议服务器")
            default:
                return .network("网络异常，请稍后再试")
            }
        }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return .network(text.isEmpty ? "网络异常，请稍后再试" : text)
    }

    static func message(from error: Error) -> String {
        wrap(error).message
    }
}

// MARK: - 解析工具

/// 服务端的数字可能是 Int、Double 或字符串（SQLite 与 JSON 序列化的边界），
/// 统一在这里收口，避免每个模型各写一遍 `as? Int ?? 0` 的重复分支。
private enum EnterpriseJSON {

    static func string(_ raw: Any?) -> String {
        if let text = raw as? String {
            return text
        }
        if let number = raw as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    static func trimmed(_ raw: Any?) -> String {
        string(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func int(_ raw: Any?) -> Int {
        if let value = raw as? Int {
            return value
        }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let text = raw as? String, let value = Int(text) {
            return value
        }
        return 0
    }

    /// 布尔字段先认真正的 Bool，再认 0/1 与 "true"/"false"。
    /// JSONSerialization 在不同 SDK 上对 __NSCFBoolean 的桥接并不完全一致，
    /// 只写 `as? Bool` 会在某个系统版本上把 true 读成默认值。
    static func bool(_ raw: Any?, fallback: Bool) -> Bool {
        if let value = raw as? Bool {
            return value
        }
        if let number = raw as? NSNumber {
            return number.boolValue
        }
        if let text = raw as? String {
            switch text.lowercased() {
            case "true", "1":
                return true
            case "false", "0":
                return false
            default:
                return fallback
            }
        }
        return fallback
    }
}

// MARK: - 企业档案

struct EnterpriseInfo: Equatable {

    let id: String
    let name: String

    /// 只有企业管理员才会拿到企业码，服务端对普通成员下发 null。
    /// 保留 optional 而不是补空串：空串会让 UI 误以为"有一个空企业码"，
    /// 后续如果要做复制/展示，就会复制出一个不存在的值。
    let code: String?

    let maxMembers: Int
    let maxParticipants: Int
    let createdAt: String
    let note: String
    let adminId: String
    let adminName: String

    init?(json: [String: Any]) {
        let identifier = EnterpriseJSON.trimmed(json["id"])
        let rawName = EnterpriseJSON.trimmed(json["name"])

        // 既没有 id 也没有名字的字典不是一家可展示的企业。
        // 宁可让上层当作"未加入"，也不要渲染一张全是空白的身份卡。
        guard !identifier.isEmpty || !rawName.isEmpty else { return nil }

        id = identifier
        // 名字是纯展示字段，缺失时给一个中性占位，比整页失败更划算。
        name = rawName.isEmpty ? "企业空间" : rawName

        let rawCode = EnterpriseJSON.trimmed(json["code"])
        code = rawCode.isEmpty ? nil : rawCode

        maxMembers = EnterpriseJSON.int(json["maxMembers"])
        maxParticipants = EnterpriseJSON.int(json["maxParticipants"])
        createdAt = EnterpriseJSON.trimmed(json["createdAt"])
        note = EnterpriseJSON.trimmed(json["note"])
        adminId = EnterpriseJSON.trimmed(json["adminId"])
        adminName = EnterpriseJSON.trimmed(json["adminName"])
    }
}

// MARK: - 用量

struct EnterpriseUsage: Equatable {

    let members: Int
    let pending: Int
    let meetings: Int
    let live: Int
    let maxMembers: Int

    init(json: [String: Any]) {
        members = EnterpriseJSON.int(json["members"])
        pending = EnterpriseJSON.int(json["pending"])
        meetings = EnterpriseJSON.int(json["meetings"])
        live = EnterpriseJSON.int(json["live"])
        maxMembers = EnterpriseJSON.int(json["maxMembers"])
    }
}

// MARK: - 概览

struct EnterpriseOverview: Equatable {

    let enterprise: EnterpriseInfo
    let usage: EnterpriseUsage
    let isAdmin: Bool

    /// 成员上限有两份来源：enterprise.maxMembers 是档案值，
    /// usage.maxMembers 是统计接口当时的快照。优先用快照，缺失时回落到档案值，
    /// 避免进度条因为上限为 0 而除零。
    var memberLimit: Int {
        usage.maxMembers > 0 ? usage.maxMembers : enterprise.maxMembers
    }

    init?(json: [String: Any]) {
        guard
            let rawEnterprise = json["enterprise"] as? [String: Any],
            let enterprise = EnterpriseInfo(json: rawEnterprise)
        else { return nil }

        self.enterprise = enterprise
        usage = EnterpriseUsage(json: json["usage"] as? [String: Any] ?? [:])
        isAdmin = EnterpriseJSON.bool(json["isAdmin"], fallback: false)
    }
}

// MARK: - 专属会议室

struct EnterpriseRoom: Equatable {

    let no: String
    let title: String
    let status: String
    let displayStatus: String

    /// 保持服务端原样字符串。这里不做时区猜测：展示层解析失败就干脆不显示，
    /// 用本地时区"猜"一个时间比不显示更容易误导用户。
    let scheduledAt: String

    let duration: Int
    let startedAt: String
    let hostName: String
    let kind: String
    let enterpriseName: String
    let roomMode: EnterpriseRoomMode
    let hasPassword: Bool
    let e2ee: Bool
    let noArchive: Bool
    let liveCount: Int
    let canManage: Bool
    let inviteUrl: String

    var isLive: Bool {
        status == "live" || liveCount > 0
    }

    init?(json: [String: Any]) {
        // no 是唯一不可缺省的字段：没有会议号，卡片上的主按钮就没有去处。
        let number = EnterpriseJSON.trimmed(json["no"])
        guard !number.isEmpty else { return nil }

        no = number
        title = EnterpriseJSON.trimmed(json["title"])
        status = EnterpriseJSON.trimmed(json["status"]).lowercased()

        let rawDisplayStatus = EnterpriseJSON.trimmed(json["displayStatus"]).lowercased()
        displayStatus = rawDisplayStatus.isEmpty ? status : rawDisplayStatus

        scheduledAt = EnterpriseJSON.trimmed(json["scheduledAt"])
        duration = EnterpriseJSON.int(json["duration"])
        startedAt = EnterpriseJSON.trimmed(json["startedAt"])
        hostName = EnterpriseJSON.trimmed(json["hostName"])

        let rawKind = EnterpriseJSON.trimmed(json["kind"]).lowercased()
        kind = rawKind
        enterpriseName = EnterpriseJSON.trimmed(json["enterpriseName"])

        let rawMode = EnterpriseJSON.trimmed(json["roomMode"]).lowercased()
        roomMode = EnterpriseRoomMode(rawValue: rawMode) ?? .fixed
        hasPassword = EnterpriseJSON.bool(json["hasPassword"], fallback: false)

        let settings = json["settings"] as? [String: Any] ?? [:]
        // 服务端 decorate 对 kind=enterprise 默认补 e2ee/noArchive=true；
        // 客户端给同一个默认值，是为了在 settings 整块缺失时仍能如实陈述默认策略。
        let enterpriseDefault = rawKind == "enterprise"
        e2ee = EnterpriseJSON.bool(settings["e2ee"], fallback: enterpriseDefault)
        noArchive = EnterpriseJSON.bool(settings["noArchive"], fallback: enterpriseDefault)

        liveCount = EnterpriseJSON.int(json["liveCount"])
        canManage = EnterpriseJSON.bool(json["canManage"], fallback: false)
        inviteUrl = EnterpriseJSON.trimmed(json["inviteUrl"])
    }
}

// MARK: - 会议列表条目

struct EnterpriseMeetingSummary: Identifiable, Equatable {

    let no: String
    let title: String
    let status: String
    let scheduledAt: String
    let duration: Int
    let hostName: String
    let liveCount: Int
    let createdAt: String
    let endedAt: String

    /// 会议号在同一企业内唯一，直接当列表 id，避免为了 Identifiable 再造一个 UUID。
    var id: String { no }

    var isLive: Bool {
        status == "live" || liveCount > 0
    }

    var scheduledText: String? {
        EnterpriseISO8601.shortText(from: scheduledAt)
    }

    /// 行内副标题：主持人与时间。时间解析失败就只保留主持人，
    /// 不显示 "Invalid Date"，也不拿 createdAt 顶替——创建时间与预定时间语义不同。
    var metaText: String {
        var parts: [String] = []
        if !hostName.isEmpty {
            parts.append("主持人 \(hostName)")
        }
        if let time = scheduledText {
            parts.append(time)
        }
        return parts.joined(separator: " · ")
    }

    init?(json: [String: Any]) {
        let number = EnterpriseJSON.trimmed(json["no"])
        guard !number.isEmpty else { return nil }

        no = number
        title = EnterpriseJSON.trimmed(json["title"])
        status = EnterpriseJSON.trimmed(json["status"]).lowercased()
        scheduledAt = EnterpriseJSON.trimmed(json["scheduledAt"])
        duration = EnterpriseJSON.int(json["duration"])
        hostName = EnterpriseJSON.trimmed(json["hostName"])
        liveCount = EnterpriseJSON.int(json["liveCount"])
        createdAt = EnterpriseJSON.trimmed(json["createdAt"])
        endedAt = EnterpriseJSON.trimmed(json["endedAt"])
    }
}

// MARK: - 时间

/// 服务端用 `new Date().toISOString()` 落库，带毫秒；老数据可能不带。
/// 两个 ISO 解析器配置完成后只读，静态共享是安全的，也避免每行列表重建一次。
enum EnterpriseISO8601 {

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let sameYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let otherYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    static func date(from raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text)
    }

    /// 展示用短格式。解析失败返回 nil，调用方据此直接隐藏时间——
    /// 这比显示一串原始 ISO 字符串更像"没有时间"，而不是"功能坏了"。
    static func shortText(from raw: String) -> String? {
        guard let date = date(from: raw) else { return nil }

        let calendar = Calendar.current
        let isSameYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: Date())
        let formatter = isSameYear ? sameYearFormatter : otherYearFormatter
        return formatter.string(from: date)
    }
}

// MARK: - 服务

enum EnterpriseService {

    // MARK: 企业概览

    /// 未加入企业不是错误，而是企业空间的一种正常空态，因此返回 `.success(nil)`。
    /// 这样视图只需要判断 overview 是否存在，不用再区分"接口失败"与"没有企业"。
    static func fetchOverview(
        completion: @escaping (Result<EnterpriseOverview?, Error>) -> Void
    ) {
        guard let token = currentToken else {
            deliver(.failure(EnterpriseError.notSignedIn), to: completion)
            return
        }

        request(path: "enterprise/overview", method: "GET", token: token) { result in
            switch result {
            case .failure(let error):
                let wrapped = EnterpriseError.wrap(error)
                if wrapped.isNotInEnterprise {
                    deliver(.success(nil), to: completion)
                } else {
                    deliver(.failure(wrapped), to: completion)
                }

            case .success(let json):
                // 服务端对未加入企业的账号直接返回 { enterprise: null }。
                if json["enterprise"] == nil || json["enterprise"] is NSNull {
                    deliver(.success(nil), to: completion)
                    return
                }
                guard let overview = EnterpriseOverview(json: json) else {
                    deliver(
                        .failure(EnterpriseError.invalidResponse("企业信息格式异常，请稍后再试")),
                        to: completion
                    )
                    return
                }
                deliver(.success(overview), to: completion)
            }
        }
    }

    // MARK: 专属会议室

    static func fetchRoom(
        completion: @escaping (Result<EnterpriseRoom, Error>) -> Void
    ) {
        guard let token = currentToken else {
            deliver(.failure(EnterpriseError.notSignedIn), to: completion)
            return
        }

        request(path: "meetings/enterprise-room", method: "GET", token: token) { result in
            switch result {
            case .success(let json):
                deliver(decodeRoom(from: json), to: completion)
            case .failure(let error):
                deliver(.failure(EnterpriseError.wrap(error)), to: completion)
            }
        }
    }

    /// 切换号码模式。服务端在切到 random 且当前无人时会立刻换一次号，
    /// 所以必须用响应里的 meeting 覆盖本地状态，不能只改一个 enum。
    static func updateRoomMode(
        _ mode: EnterpriseRoomMode,
        completion: @escaping (Result<EnterpriseRoom, Error>) -> Void
    ) {
        guard let token = currentToken else {
            deliver(.failure(EnterpriseError.notSignedIn), to: completion)
            return
        }

        request(
            path: "meetings/enterprise-room",
            method: "PATCH",
            token: token,
            body: ["roomMode": mode.rawValue]
        ) { result in
            switch result {
            case .success(let json):
                deliver(decodeRoom(from: json), to: completion)
            case .failure(let error):
                deliver(.failure(EnterpriseError.wrap(error)), to: completion)
            }
        }
    }

    /// 手动换号。服务端在会议室有人时会返回 409，前端虽然已经禁用了按钮，
    /// 这里仍然不做本地短路——状态可能已经被另一端改变，服务端才是事实源。
    static func rotateRoom(
        completion: @escaping (Result<EnterpriseRoom, Error>) -> Void
    ) {
        guard let token = currentToken else {
            deliver(.failure(EnterpriseError.notSignedIn), to: completion)
            return
        }

        request(path: "meetings/enterprise-room/rotate", method: "POST", token: token) { result in
            switch result {
            case .success(let json):
                deliver(decodeRoom(from: json), to: completion)
            case .failure(let error):
                deliver(.failure(EnterpriseError.wrap(error)), to: completion)
            }
        }
    }

    // MARK: 企业会议列表

    static func fetchMeetings(
        completion: @escaping (Result<[EnterpriseMeetingSummary], Error>) -> Void
    ) {
        guard let token = currentToken else {
            deliver(.failure(EnterpriseError.notSignedIn), to: completion)
            return
        }

        request(path: "enterprise/meetings", method: "GET", token: token) { result in
            switch result {
            case .failure(let error):
                deliver(.failure(EnterpriseError.wrap(error)), to: completion)

            case .success(let json):
                // list 缺失按格式异常处理：如果这里静默返回 []，UI 会显示
                // "还没有企业会议"，等于用假空态掩盖了一次服务端故障。
                guard let rawList = json["list"] as? [[String: Any]] else {
                    deliver(
                        .failure(EnterpriseError.invalidResponse("会议列表格式异常，请稍后再试")),
                        to: completion
                    )
                    return
                }
                let list = rawList.compactMap { EnterpriseMeetingSummary(json: $0) }
                deliver(.success(list), to: completion)
            }
        }
    }

    // MARK: 私有

    /// 每次请求都现读 AuthStore：token 可能在别处被刷新或清除，
    /// 缓存一份只会让"退出登录后还带着旧 token 请求"这种问题更难查。
    private static var currentToken: String? {
        guard let token = AuthStore.load()?.token, !token.isEmpty else { return nil }
        return token
    }

    private static func request(
        path: String,
        method: String,
        token: String,
        body: [String: Any]? = nil,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let url = TianqiongAPI.baseURL.appendingPathComponent(path)
        APIClient.request(url: url, method: method, token: token, body: body, completion: completion)
    }

    /// GET / PATCH / rotate 三个接口返回的 meeting 是同一套 decorate 结果，
    /// 解析只写一份，避免某个字段在三条路径上的默认值悄悄分叉。
    private static func decodeRoom(from json: [String: Any]) -> Result<EnterpriseRoom, Error> {
        guard
            let rawMeeting = json["meeting"] as? [String: Any],
            let room = EnterpriseRoom(json: rawMeeting)
        else {
            return .failure(EnterpriseError.invalidResponse("会议室信息格式异常，请稍后再试"))
        }
        return .success(room)
    }

    /// 统一投递口。APIClient 的回调本来就在主线程，这里只在必要时补一次派发，
    /// 让"同步提前失败"和"异步网络失败"两条路径对调用方表现一致。
    private static func deliver<T>(
        _ result: Result<T, Error>,
        to completion: @escaping (Result<T, Error>) -> Void
    ) {
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
