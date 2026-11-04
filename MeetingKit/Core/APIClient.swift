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
}

// MARK: - 会话模型

struct AuthSession: Equatable {
    var token: String
    var name: String
    var account: String
    var role: String
}

/// 登录态持久化。load() 必须是同步的：登录页首帧就要判断"是否已登录"。
enum AuthStore {

    private static let tokenKey = "tianqiong.auth.token"
    private static let nameKey = "tianqiong.auth.name"
    private static let accountKey = "tianqiong.auth.account"
    private static let roleKey = "tianqiong.auth.role"

    static func save(_ session: AuthSession) {
        let defaults = UserDefaults.standard
        defaults.set(session.token, forKey: tokenKey)
        defaults.set(session.name, forKey: nameKey)
        defaults.set(session.account, forKey: accountKey)
        defaults.set(session.role, forKey: roleKey)
    }

    static func load() -> AuthSession? {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: tokenKey), !token.isEmpty else { return nil }
        return AuthSession(
            token: token,
            name: defaults.string(forKey: nameKey) ?? "",
            account: defaults.string(forKey: accountKey) ?? "",
            role: defaults.string(forKey: roleKey) ?? "user"
        )
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: tokenKey)
        defaults.removeObject(forKey: nameKey)
        defaults.removeObject(forKey: accountKey)
        defaults.removeObject(forKey: roleKey)
    }
}

// MARK: - 客户端

enum APIClient {

    /// 服务端错误统一转成可展示的中文文案。
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

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
            withJSONObject: ["account": account, "password": password]
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
                    role: (user["role"] as? String) ?? "user"
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
                    role: (user["role"] as? String) ?? "user"
                )
                AuthStore.save(session)
                completion(.success(session))
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
                if let message = json["error"] as? String {
                    completion(.failure(APIError(message: message)))
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
