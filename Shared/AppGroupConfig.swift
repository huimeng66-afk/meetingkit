//
//  AppGroupConfig.swift
//  Shared
//
//  主 App 与广播扩展唯一共享的"常量真相"。两个 Target 都编译这一份文件，
//  任何一处 bundle id 写错都会导致扩展写进去的帧主 App 读不到，
//  所以全部集中在这里，禁止在别处硬编码。
//
//  ── 为什么 identifier 要"运行时探测"而不是写死 ──────────────────────
//  App Group 最终生效的名字，取决于**签名用的那张证书**：
//    · 用本工程自己的开发者账号签 → 生效的是 entitlements 里的
//      group.com.tianqiong.meetingkit；
//    · 用第三方签名工具（轻松签 / SideStore / 代签证书）重签 → 生效的
//      entitlements 完全由证书的 provisioning profile 决定，工程里那份
//      entitlements 根本不参与，profile 里有哪几个 group 就只有哪几个。
//  写死名字的后果：重签后主 App 拿到 nil、扩展写不进状态，界面表现为
//  "点了共享没反应 / 对方一直黑屏"，而且没有任何报错可查。
//
//  ── 1.5.4 的真机根因 ────────────────────────────────────────────────
//  上一版只从 `Bundle.main` 里找 `embedded.mobileprovision`。
//  主 App 的 Bundle.main 就是 .app，能找到；但扩展的 Bundle.main 是
//  `.app/PlugIns/MeetingBroadcast.appex`，而重签工具通常只把 profile
//  放在主 App 根目录，**不会往每个 .appex 里再塞一份**。
//  结果：主 App 探测到 group.e2904eee920f2ee6.3，扩展却回退到
//  group.com.tianqiong.meetingkit，`containerURL` 返回 nil，
//  `broadcastStarted` 第一道 guard 就结束广播 —— 诊断里就是
//  "扩展状态 idle / 心跳无 / 出帧是上一场的旧文件 / 已推 RTC 是旧计数"。
//
//  修复分三层，任何一层命中都能让两个进程拿到同一个 group：
//    1. 扫自己的 profile；
//    2. 扫**主 App 根目录**的 profile（从 .appex 往上两级）；
//    3. 读当前进程代码签名里的 entitlements（SecTask，私有但在 iOS 可用，
//       只作为兜底，且不做任何越权操作）。
//  三层都拿不到才回退 preferredIdentifier，并由扩展明确报错。
//

import Foundation
import Darwin

enum AppGroupConfig {

    /// 工程自身的 App Group。用本工程自己的开发者账号签名时，实际生效的就是它。
    static let preferredIdentifier = "group.com.tianqiong.meetingkit"

    /// 主 App 的 Bundle Identifier（RPSystemBroadcastPickerView 用它确认宿主）。
    ///
    /// 1.5.4 起改为运行时读取：侧载工具重签时可能改写 bundle id，
    /// 写死会让 picker 找不到自己的扩展，系统面板只能列出别的 App 的录制项。
    static let bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.tianqiong.meetingkit"

    /// 广播扩展的 Bundle Identifier，即 `RPSystemBroadcastPickerView.preferredExtension` 的取值。
    ///
    /// 同样不能写死：重签后的扩展 bundle id 可能被改成
    /// `<新主包 id>.Broadcast` 或工具自己的命名。这里直接读
    /// `PlugIns/*.appex` 的 Info.plist，按扩展点类型挑出广播扩展。
    /// 找不到才回退到工程默认值。
    static let broadcastExtensionBundleIdentifier: String = resolveExtensionBundleIdentifier()

    /// 产品展示名，UI 与系统弹窗复用同一份，避免多语言阶段各处改名漏改。
    static let displayName = "MeetingKit"

    /// 当前进程实际可用的 App Group 标识。
    ///
    /// `static let` 在 Swift 里是惰性且线程安全的，这里只会解析一次：
    /// 探测要读 profile 文件并对每个候选查一次容器，不该每帧都跑。
    static let identifier: String = resolveIdentifier()

    /// 当前签名方式是否真的给了我们 App Group 能力。
    ///
    /// 免费 Apple ID 自签、或证书 profile 未授权任何 App Group 时返回 false ——
    /// 这种情况下系统级屏幕共享（ReplayKit 广播扩展）物理上无法工作，
    /// UI 必须提前说清楚，而不是让用户点进去看黑屏。
    static var isAvailable: Bool {
        containerURL() != nil
    }

    /// App Group 的共享容器目录。扩展没有写权限之外的特殊限制，
    /// 但容器 URL 拿不到时说明 entitlements 配错了，调用方必须按 nil 处理。
    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// App Group 共享的 UserDefaults。
    /// 跨进程可见性由 cfprefsd 保证，写入后不需要手动 synchronize()。
    static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// 当前进程探测到的候选 group（诊断面板用）。
    /// 只返回名字，不返回 profile 内容；顺序与 resolveIdentifier 一致。
    static var candidateIdentifiersForDiagnostics: [String] {
        candidateIdentifiers()
    }

    // MARK: - 探测

    /// 从内嵌的 `PlugIns/*.appex` 里解析广播扩展的 bundle id。
    private static func resolveExtensionBundleIdentifier() -> String {
        let fallback = "\(bundleIdentifier).Broadcast"
        guard let pluginsURL = Bundle.main.builtInPlugInsURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: pluginsURL.path)
        else {
            return fallback
        }

        for name in names where name.hasSuffix(".appex") {
            let url = pluginsURL.appendingPathComponent(name)
            guard let bundle = Bundle(url: url) else { continue }
            guard let extensionInfo = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                  (extensionInfo["NSExtensionPointIdentifier"] as? String) == "com.apple.broadcast-services-upload",
                  let identifier = bundle.bundleIdentifier
            else {
                continue
            }
            return identifier
        }
        return fallback
    }

    /// 候选顺序：本工程自己的 group 优先，其次是代码签名 entitlements，
    /// 最后是 profile 里声明的 group。
    private static func resolveIdentifier() -> String {
        for candidate in candidateIdentifiers() {
            // containerURL 是唯一可信的判据：名字写在 entitlements 里但证书
            // 没授权时它返回 nil；UserDefaults(suiteName:) 在这种情况下的行为
            // 各系统版本不一致，不能拿来当依据。
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil {
                return candidate
            }
        }
        return preferredIdentifier
    }

    private static func candidateIdentifiers() -> [String] {
        var list: [String] = [preferredIdentifier]

        // 1.5.4：先看代码签名里真实授予的 entitlements，再看 profile 正文。
        // 两者都只是候选，最终仍由 containerURL 实测把关。
        for id in groupsFromSelfEntitlements() where !list.contains(id) {
            list.append(id)
        }
        for id in groupsFromEmbeddedProfiles() where !list.contains(id) {
            list.append(id)
        }
        return list
    }

    // MARK: - profile 扫描

    /// 收集当前进程能读到的所有 `embedded.mobileprovision`。
    ///
    /// 关键在第二项：扩展的 Bundle.main 是 `.appex`，profile 通常在主 App 根目录。
    /// 从 `.appex` 往上两级正好是 `.app`：
    ///   MeetingKit.app/PlugIns/MeetingBroadcast.appex → MeetingKit.app
    private static func profileURLs() -> [URL] {
        var urls: [URL] = []
        let fm = FileManager.default

        if let own = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") {
            urls.append(own)
        }

        // 主 App 根目录。主 App 自己执行时算出的是 Payload 目录，文件不存在，
        // 下面的 fileExists 会把它过滤掉，不影响。
        var container = Bundle.main.bundleURL
        container.deleteLastPathComponent()
        container.deleteLastPathComponent()
        let hostProfile = container.appendingPathComponent("embedded.mobileprovision")
        if fm.fileExists(atPath: hostProfile.path), !urls.contains(hostProfile) {
            urls.append(hostProfile)
        }

        return urls
    }

    private static func groupsFromEmbeddedProfiles() -> [String] {
        var result: [String] = []
        for url in profileURLs() {
            for id in groupsFromProfile(at: url) where !result.contains(id) {
                result.append(id)
            }
        }
        return result
    }

    /// 从单个 profile 里扫出所有 App Group 名。
    ///
    /// 为什么不解析 CMS：profile 是 CMS 签名包裹的 plist，解开需要完整的
    /// DER/ASN.1 解析，几十行代码还会多出一堆失败分支；而 plist 正文在 CMS 里
    /// 是**明文**存放的，直接按 isoLatin1 扫描 `group.xxx` 就能拿到全部名字。
    /// 扫到的名字只当候选，最终仍由 containerURL 实测把关，误扫不影响正确性。
    ///
    /// 未签名的 IPA 里没有这个文件（返回空数组），此时只剩 preferredIdentifier
    /// 与 entitlements 两个候选 —— 这正是"还没签名就运行"的正常情况。
    private static func groupsFromProfile(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let regex = try? NSRegularExpression(pattern: "group\\.[A-Za-z0-9._-]{3,64}")
        else {
            return []
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var result: [String] = []
        for match in matches {
            let name = nsText.substring(with: match.range)
            if !result.contains(name) {
                result.append(name)
            }
        }
        return result
    }

    // MARK: - 代码签名 entitlements（兜底）

    /// 读当前进程代码签名里的 `com.apple.security.application-groups`。
    ///
    /// `SecTaskCopyValueForEntitlement` 在 iOS 上没有公开头文件，但 Security
    /// 框架里一直存在，且只能读取**自己进程**的签名信息，不涉及越权。
    /// 这里用 dlsym 动态取符号，避免把私有 API 写进链接表：
    ///   · 取不到符号 → 返回空数组，继续走 profile 扫描；
    ///   · 取到但没授权 → 返回空数组，由 containerURL 继续把关。
    ///
    /// 为什么值得用：这是唯一能 100% 反映"这张证书到底给了扩展哪个 group"
    /// 的来源。profile 可能被裁掉、文件可能读不到，entitlements 不会。
    private static func groupsFromSelfEntitlements() -> [String] {
        typealias CreateFromSelf = @convention(c) (CFAllocator?) -> OpaquePointer?
        typealias CopyValue = @convention(c) (
            OpaquePointer?,
            CFString,
            UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFTypeRef>?

        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let createSym = dlsym(handle, "SecTaskCreateFromSelf"),
              let copySym = dlsym(handle, "SecTaskCopyValueForEntitlement")
        else {
            return []
        }

        let create = unsafeBitCast(createSym, to: CreateFromSelf.self)
        let copy = unsafeBitCast(copySym, to: CopyValue.self)

        guard let task = create(kCFAllocatorDefault) else { return [] }
        defer {
            // SecTaskRef 是 +1 的 CF 对象。类型系统里它是不透明指针，
            // 用 Unmanaged 还原成对象再 release，避免 CFTypeRef 桥接差异。
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(task)).release()
        }

        guard let raw = copy(task, "com.apple.security.application-groups" as CFString, nil) else {
            return []
        }
        let value = raw.takeRetainedValue()
        if let groups = value as? [String] {
            return groups
        }
        if let array = value as? NSArray {
            return array.compactMap { $0 as? String }
        }
        return []
    }
}
