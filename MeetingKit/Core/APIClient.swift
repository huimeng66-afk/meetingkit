//
//  APIClient.swift
//  MeetingKit
//
//  天穹服务端 API 客户端（最小集：登录 + 会话持久化）。
//
//  与 Web 端同源（https://会议.shop/api）。目标系统是 iOS 14，
//  async/await 需要 iOS 15，因此统一用 completion handler 风格，
//  避免在工程里散落 @available 分支。
//
//  会话存 UserDefaults：token 只用于后续 /auth/me 等接口，属于非敏感用途；
//  生产环境应换 Keychain，本阶段先保持与 UserProfileStore 同一套轻量方案。
//

import Foundation

// MARK: - 服务地址

enum TianqiongAPI {

    /// 服务端根地址：优先取 Info.plist 的 TQServerOrigin，缺省回落到生产域名。
    /// 「会议.shop」在 URL 里必须用 punycode，直接写中文域名 URL(string:) 会得到 nil。
    static let origin: URL = {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "TQServerOrigin") as? String,
           let url = URL(string: raw), url.scheme != nil {
            return url
        }
        return URL(string: "https://xn--6oqu09l.shop")!
    }()

    /// 接口前缀。Web 端同一套服务，路径逐字对齐 server/routes/*.js。
    static let baseURL = origin.appendingPathComponent("api")

    static let defaultTimeout: TimeInterval = 15

    /// 网页入会地址。
    ///
    /// 会中邀请卡、二维码、首页通讯录的邀请链接共用这一个拼法。
    /// 之前三处各自写 `origin.absoluteString + "/room?no="`：只要 Info.plist 里的
    /// `TQServerOrigin` 带了尾部斜杠，就会拼出 `https://host//room`，
    /// 部分服务端会把双斜杠当成路径的一部分，扫码的人直接 404。
    static func roomLink(number: String) -> String {
        let base = origin.absoluteString
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return "\(trimmed)/room?no=\(number)"
    }
}

// MARK: - 会话模型

struct AuthSession: Equatable {
    var token: String
    var name: String
    var account: String
    var role: String

    /// 本次登录所用的设备。由服务端在登录响应里回传，设置页用它展示
    /// 「设备与登录」——名称、系统、登录时间与设备号。
    /// 老版本会话没有这些字段，因此给默认值，保证解码路径不会崩。
    var deviceName: String = ""
    var devicePlatform: String = ""
    var deviceLoginAt: String = ""
    var deviceId: String = ""
}

/// 登录态持久化。load() 必须是同步的：登录页首帧就要判断"是否已登录"。
enum AuthStore {

    /// 登录态变化通知。
    ///
    /// 设置页退出登录、登录页登录成功都会改 AuthStore，但首页是常驻视图，
    /// 不切 tab 就不会重新走 onAppear——不广播的话会出现"设置里退出了，
    /// 回会议页还挂着头像"。谁改谁发，谁显示谁听，比让每个页面自己去轮询干净。
    static let didChangeNotification = Notification.Name("tianqiong.auth.didChange")

    /// 账号在别的设备登录、本机被服务端踢下线。
    /// 与 didChange 分开：didChange 只表示"登录态变了"，这个通知多带一条原因，
    /// 首页收到后要弹一次明确的说明，而不是让用户莫名其妙回到入会页。
    static let deviceKickedNotification = Notification.Name("tianqiong.auth.deviceKicked")

    private static let tokenKey = "tianqiong.auth.token"
    private static let nameKey = "tianqiong.auth.name"
    private static let accountKey = "tianqiong.auth.account"
    private static let roleKey = "tianqiong.auth.role"
    private static let deviceNameKey = "tianqiong.auth.device.name"
    private static let devicePlatformKey = "tianqiong.auth.device.platform"
    private static let deviceLoginAtKey = "tianqiong.auth.device.loginAt"
    private static let deviceIdKey = "tianqiong.auth.device.id"

    static func save(_ session: AuthSession) {
        let defaults = UserDefaults.standard
        defaults.set(session.token, forKey: tokenKey)
        defaults.set(session.name, forKey: nameKey)
        defaults.set(session.account, forKey: accountKey)
        defaults.set(session.role, forKey: roleKey)
        defaults.set(session.deviceName, forKey: deviceNameKey)
        defaults.set(session.devicePlatform, forKey: devicePlatformKey)
        defaults.set(session.deviceLoginAt, forKey: deviceLoginAtKey)
        defaults.set(session.deviceId, forKey: deviceIdKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func load() -> AuthSession? {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: tokenKey), !token.isEmpty else { return nil }
        return AuthSession(
            token: token,
            name: defaults.string(forKey: nameKey) ?? "",
            account: defaults.string(forKey: accountKey) ?? "",
            role: defaults.string(forKey: roleKey) ?? "user",
            deviceName: defaults.string(forKey: deviceNameKey) ?? "",
            devicePlatform: defaults.string(forKey: devicePlatformKey) ?? "",
            deviceLoginAt: defaults.string(forKey: deviceLoginAtKey) ?? "",
            deviceId: defaults.string(forKey: deviceIdKey) ?? ""
        )
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: tokenKey)
        defaults.removeObject(forKey: nameKey)
        defaults.removeObject(forKey: accountKey)
        defaults.removeObject(forKey: roleKey)
        defaults.removeObject(forKey: deviceNameKey)
        defaults.removeObject(forKey: devicePlatformKey)
        defaults.removeObject(forKey: deviceLoginAtKey)
        defaults.removeObject(forKey: deviceIdKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// 处理所有"令牌已经不能再用"的响应：DEVICE_KICKED、BAD_TOKEN、STALE_TOKEN、
    /// NO_USER，以及账号被禁用/待审/驳回。
    ///
    /// 之前只处理 DEVICE_KICKED：令牌自然过期、改密后旧令牌失效、账号被禁用时，
    /// 界面还挂着头像与"已登录"，但每个接口都在 401/403——用户只会觉得软件坏了。
    ///
    /// 关键点在 `token` 比较：首页可能同时有几个请求在飞，用户被踢后立刻重新登录，
    /// 旧请求的 401 会晚到。如果不加判断，它会把刚建立的新会话也清掉，
    /// 表现就是"重新登录后又被踢一次"。
    static func handleSessionInvalid(message: String, token: String?) {
        guard let current = load() else { return }
        if let token = token, !token.isEmpty, token != current.token {
            return
        }

        let text = message.isEmpty ? "登录状态已失效，请重新登录" : message
        clear()
        NotificationCenter.default.post(
            name: deviceKickedNotification,
            object: nil,
            userInfo: ["message": text]
        )
    }
}

// MARK: - 客户端

enum APIClient {

    /// 服务端错误统一转成可展示的中文文案。
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 这些 code 表示"这枚令牌已经不能再用"，而不是"这次操作没权限"。
    /// 与服务端 auth.js 的 verifyToken / attachUser 一一对应，
    /// 新增 code 时两边要一起改。
    ///
    /// 两个刻意不收的：
    ///   · `LOGIN_REQUIRED`（会议仅限企业成员）——访客点进企业会议也会收到它，
    ///     清会话会把本来正常的登录态一起打掉；
    ///   · `FORBIDDEN` —— 只是这一次操作越权，账号本身还有效。
    private static let sessionInvalidCodes: Set<String> = [
        "DEVICE_KICKED",
        "BAD_TOKEN",
        "STALE_TOKEN",
        "NO_TOKEN",
        "NO_USER",
        "DISABLED",
        "PENDING",
        "REJECTED",
    ]

    /// 登录。成功返回会话（token + 用户信息），失败返回服务端文案或网络提示。
    /// 注意：任何情况下都不在客户端校验账号格式——服务端是唯一事实源，
    /// 客户端提前"智能提示"只会在规则变更后变成错误提示。
    static func login(
        account: String,
        password: String,
        completion: @escaping (Result<AuthSession, Error>) -> Void
    ) {
        let url = TianqiongAPI.baseURL.appendingPathComponent("auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TianqiongAPI.defaultTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: [
                "account": account,
                "password": password,
                // 单设备登录：服务端用这两个字段认设备。
                // 新设备登录会把旧设备的令牌顶掉，旧设备下一次请求收到 DEVICE_KICKED。
                "deviceId": DeviceIdentity.id,
                "deviceName": DeviceIdentity.name,
                "platform": DeviceIdentity.platform,
            ]
        )

        URLSession.shared.dataTask(with: request) { data, response, error in
            // 回调统一切回主线程：登录页直接改 @State，不再在视图里二次 dispatch。
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(APIError(message: networkMessage(for: error))))
                    return
                }
                guard
                    let data = data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    completion(.failure(APIError(message: "服务响应异常，请稍后再试")))
                    return
                }
                if let message = json["error"] as? String {
                    completion(.failure(APIError(message: message)))
                    return
                }
                guard
                    let token = json["token"] as? String,
                    let user = json["user"] as? [String: Any],
                    let name = user["name"] as? String
                else {
                    completion(.failure(APIError(message: "登录响应缺少必要字段")))
                    return
                }
                let session = AuthSession(
                    token: token,
                    name: name,
                    account: (user["account"] as? String) ?? account,
                    role: (user["role"] as? String) ?? "user",
                    deviceName: (json["device"] as? [String: Any])?["name"] as? String
                        ?? DeviceIdentity.name,
                    devicePlatform: (json["device"] as? [String: Any])?["platform"] as? String
                        ?? DeviceIdentity.platform,
                    deviceLoginAt: (json["device"] as? [String: Any])?["loginAt"] as? String ?? "",
                    deviceId: (json["device"] as? [String: Any])?["id"] as? String
                        ?? DeviceIdentity.id
                )
                completion(.success(session))
            }
        }.resume()
    }

    /// 把 URLError 转成用户看得懂的话：超时 / 无网络 / 连不上是三种完全不同的提示。
    private static func networkMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return "连接超时，请检查网络后重试"
            case NSURLErrorNotConnectedToInternet:
                return "当前无网络连接"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "无法连接到会议服务器"
            default:
                break
            }
        }
        return "网络异常，请稍后再试"
    }

    // MARK: - 会议信息（入会前校验）

    /// 入会前的会议信息。返回：
    ///   - title / hasPassword / liveCount / settings / status
    /// 404 → "会议不存在"；410 → "会议已取消/已结束"。
    /// iOS 端先校验再进会议室，避免用户在会议室里才发现会议号打错了。
    static func fetchMeetingInfo(
        no: String,
        completion: @escaping (Result<MeetingInfoResponse, Error>) -> Void
    ) {
        let url = TianqiongAPI.baseURL
            .appendingPathComponent("meetings/info")
            .appendingPathComponent(no)
        request(url: url, method: "GET", token: AuthStore.load()?.token) { result in
            switch result {
            case .success(let json):
                guard let meeting = json["meeting"] as? [String: Any] else {
                    completion(.failure(APIError(message: "会议信息格式异常")))
                    return
                }
                let settings = meeting["settings"] as? [String: Any] ?? [:]
                let info = MeetingInfoResponse(
                    title: meeting["title"] as? String ?? "",
                    hostName: meeting["hostName"] as? String ?? "",
                    hasPassword: meeting["hasPassword"] as? Bool ?? false,
                    liveCount: meeting["liveCount"] as? Int ?? 0,
                    locked: settings["lock"] as? Bool ?? false,
                    allowGuest: settings["allowGuest"] as? Bool ?? true,
                    maxParticipants: settings["maxParticipants"] as? Int ?? 9,
                    isHost: meeting["isHost"] as? Bool ?? false,
                    status: meeting["status"] as? String ?? ""
                )
                completion(.success(info))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 入会前取 ICE 服务器（STUN/TURN 临时凭证）。访客也能取（服务端只做 IP 频控）。
    static func fetchIceServers(
        completion: @escaping (Result<[IceServerConfig], Error>) -> Void
    ) {
        let url = TianqiongAPI.baseURL.appendingPathComponent("rtc/ice")
        request(url: url, method: "GET", token: AuthStore.load()?.token) { result in
            switch result {
            case .success(let json):
                guard let rawList = json["iceServers"] as? [[String: Any]] else {
                    completion(.failure(APIError(message: "ICE 配置格式异常")))
                    return
                }
                let servers = rawList.compactMap(IceServerConfig.init)
                guard !servers.isEmpty else {
                    completion(.failure(APIError(message: "ICE 配置为空")))
                    return
                }
                completion(.success(servers))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 创建会议（需要登录）。instant=true 立即开会（主持人随即入会）。
    /// 未登录时服务端返回"请先登录"，直接透传给用户。
    static func createMeeting(
        title: String,
        instant: Bool,
        completion: @escaping (Result<CreatedMeeting, Error>) -> Void
    ) {
        let url = TianqiongAPI.baseURL.appendingPathComponent("meetings")
        var body: [String: Any] = ["instant": instant, "duration": 60]
        if !title.isEmpty {
            body["title"] = title
        }
        request(url: url, method: "POST", token: AuthStore.load()?.token, body: body) { result in
            switch result {
            case .success(let json):
                guard
                    let meeting = json["meeting"] as? [String: Any],
                    let no = meeting["no"] as? String
                else {
                    completion(.failure(APIError(message: "创建会议失败，请稍后重试")))
                    return
                }
                completion(
                    .success(
                        CreatedMeeting(
                            no: no,
                            title: meeting["title"] as? String ?? ""
                        )
                    )
                )
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - 通用请求

    /// 修改登录密码。
    ///
    /// 服务端改密后会作废该用户的所有旧令牌，并给当前设备换发一枚新的；
    /// 因此这一步必须把新 token 写回 AuthStore，否则下一次请求就会 401，
    /// 用户看到的是"改完密码就被踢下线"。
    static func changePassword(
        oldPassword: String,
        newPassword: String,
        token: String,
        completion: @escaping (Result<AuthSession, Error>) -> Void
    ) {
        let url = TianqiongAPI.baseURL.appendingPathComponent("auth/password")

        request(
            url: url,
            method: "POST",
            token: token,
            body: ["oldPassword": oldPassword, "newPassword": newPassword]
        ) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))

            case .success(let json):
                guard
                    let freshToken = json["token"] as? String,
                    let user = json["user"] as? [String: Any]
                else {
                    completion(.failure(APIError(message: "密码已修改，请重新登录")))
                    return
                }

                let session = AuthSession(
                    token: freshToken,
                    name: (user["name"] as? String) ?? "",
                    account: (user["account"] as? String) ?? "",
                    role: (user["role"] as? String) ?? "user",
                    deviceName: (json["device"] as? [String: Any])?["name"] as? String
                        ?? AuthStore.load()?.deviceName ?? DeviceIdentity.name,
                    devicePlatform: (json["device"] as? [String: Any])?["platform"] as? String
                        ?? DeviceIdentity.platform,
                    deviceLoginAt: (json["device"] as? [String: Any])?["loginAt"] as? String
                        ?? AuthStore.load()?.deviceLoginAt ?? "",
                    deviceId: (json["device"] as? [String: Any])?["id"] as? String
                        ?? DeviceIdentity.id
                )
                AuthStore.save(session)
                completion(.success(session))
            }
        }
    }

    /// 更新账号显示名。
    ///
    /// 之前首页"编辑资料"只写本地 UserProfile，服务端 users.name 没动；
    /// 用户改完昵称、退出再登录，LoginView 用服务端 user.name 回填，
    /// 名字又变回旧的——用户会认为"保存根本没生效"。
    /// 这个接口只改姓名；头像色是设备偏好，仍留在本地。
    static func updateProfile(
        name: String,
        token: String,
        completion: @escaping (Result<AuthSession, Error>) -> Void
    ) {
        let url = TianqiongAPI.baseURL.appendingPathComponent("auth/profile")

        request(url: url, method: "PATCH", token: token, body: ["name": name]) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))

            case .success(let json):
                guard
                    let user = json["user"] as? [String: Any],
                    let updatedName = user["name"] as? String
                else {
                    completion(.failure(APIError(message: "资料已提交，但响应格式异常")))
                    return
                }

                // 只有"请求发出时的会话仍然是当前会话"才写回。
                // 否则会出现两种坏状态：请求在飞的时候被其他设备踢掉，回来却把
                // 会话重新写了回去（界面显示已登录，设备信息全是空的）；
                // 或者期间换了账号，旧账号的昵称盖掉了新账号。
                guard let current = AuthStore.load(), current.token == token else {
                    completion(.failure(APIError(message: "登录状态已变更，请重新登录后再试")))
                    return
                }

                let session = AuthSession(
                    token: current.token,
                    name: updatedName,
                    account: (user["account"] as? String) ?? current.account,
                    role: (user["role"] as? String) ?? current.role,
                    deviceName: current.deviceName,
                    devicePlatform: current.devicePlatform,
                    deviceLoginAt: current.deviceLoginAt,
                    deviceId: current.deviceId
                )
                AuthStore.save(session)
                completion(.success(session))
            }
        }
    }

    /// 静默校验当前令牌还能不能用。
    ///
    /// 单设备登录上线后，本地存在 token 不等于还在线：账号可能在别处登录过。
    /// 首页每次出现时探一次 `/auth/me`，被踢就由 request 统一清会话并广播，
    /// 用户会直接回到入会页，而不是点「发起会议」才发现所有接口都 401。
    static func validateSession(token: String, completion: ((Bool) -> Void)? = nil) {
        let url = TianqiongAPI.baseURL.appendingPathComponent("auth/me")
        request(url: url, method: "GET", token: token) { result in
            switch result {
            case .success:
                completion?(true)
            case .failure:
                completion?(false)
            }
        }
    }

    /// 通用 JSON 请求。token 可空（访客接口不需要鉴权）。
    /// 统一处理：网络错误、非 2xx 的业务错误（取 body.error）、JSON 解析。
    /// 回调保证在主线程。
    ///
    /// 对内公开（internal）而不是 private：企业空间、会议列表这些模块各自有独立的
    /// 模型与错误语义，不应该把十几个 endpoint 全塞进这个文件；它们共享同一套
    /// 超时、鉴权头与错误文案，因此只复用这一条请求管线。
    static func request(
        url: URL,
        method: String,
        token: String?,
        body: [String: Any]? = nil,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = TianqiongAPI.defaultTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(APIError(message: networkMessage(for: error))))
                    return
                }
                guard
                    let data = data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    completion(.failure(APIError(message: "服务响应异常，请稍后再试")))
                    return
                }
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let message = json["error"] as? String

                // 会话失效：清本地登录态并让首页退回入会页。
                //
                // 只对"带着凭据发出的请求"生效：登录/注册这类请求本身不带 token，
                // 它们的 401 是"账号密码不对"，不是"当前会话失效"。
                // 已登录用户去登录另一个账号时若也走这条分支，会把现有会话误清掉。
                if statusCode == 401 || statusCode == 403,
                   let sentToken = token, !sentToken.isEmpty {
                    let code = json["code"] as? String ?? ""
                    if Self.sessionInvalidCodes.contains(code) {
                        AuthStore.handleSessionInvalid(message: message ?? "", token: sentToken)
                    }
                }

                if let message = message, !message.isEmpty {
                    completion(.failure(APIError(message: message)))
                    return
                }

                // 非 2xx 又没有 error 字段：绝不能当成功返回，
                // 否则调用方会拿一个空 JSON 当数据，最后表现为"页面空白但没有报错"。
                guard (200...299).contains(statusCode) else {
                    completion(.failure(APIError(message: "服务暂时不可用（\(statusCode)），请稍后再试")))
                    return
                }

                completion(.success(json))
            }
        }.resume()
    }
}

// MARK: - 响应模型

/// 入会前会议信息（server/routes/meetings.js GET /meetings/info/:no）。
struct MeetingInfoResponse {
    var title: String
    var hostName: String
    var hasPassword: Bool
    var liveCount: Int
    var locked: Bool
    var allowGuest: Bool
    var maxParticipants: Int
    /// 当前登录用户是否就是主持人（服务端按 host_id 判定，主持人可绕过锁定与密码）。
    var isHost: Bool
    /// scheduled / live / ended / canceled。
    var status: String
}

/// 服务端 /rtc/ice 下发的一条 ICE 配置。
/// 字段名与服务端返回对齐（urls 是字符串数组，可能带 ?transport= 参数）。
struct IceServerConfig {
    var urls: [String]
    var username: String?
    var credential: String?
}

/// 创建会议的响应。
struct CreatedMeeting {
    var no: String
    var title: String
}

extension IceServerConfig {
    init?(_ raw: [String: Any]) {
        let urls: [String]
        if let single = raw["urls"] as? String {
            urls = [single]
        } else if let list = raw["urls"] as? [String] {
            urls = list
        } else {
            return nil
        }
        guard !urls.isEmpty else { return nil }
        self.urls = urls
        username = raw["username"] as? String
        credential = raw["credential"] as? String
    }
}
