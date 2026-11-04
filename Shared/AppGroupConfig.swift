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
//  所以改为：先扫当前进程 embedded.mobileprovision 里声明的 group，
//  再逐个用 containerURL 实测，取第一个真正可用的。主 App 与扩展跑同一份
//  代码、读同一份 profile，探测结果必然一致。
//

import Foundation

enum AppGroupConfig {

    /// 工程自身的 App Group。用本工程自己的开发者账号签名时，实际生效的就是它。
    static let preferredIdentifier = "group.com.tianqiong.meetingkit"

    /// 主 App 的 Bundle Identifier（RPSystemBroadcastPickerView 用它确认宿主）。
    static let bundleIdentifier = "com.tianqiong.meetingkit"

    /// 广播扩展的 Bundle Identifier，即 RPSystemBroadcastPickerView.preferredExtension 的取值。
    static let broadcastExtensionBundleIdentifier = "com.tianqiong.meetingkit.Broadcast"

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

    // MARK: - 探测

    /// 候选顺序：本工程自己的 group 优先，其次是当前 profile 里声明的 group。
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
        for id in groupsFromEmbeddedProfile() where !list.contains(id) {
            list.append(id)
        }
        return list
    }

    /// 从当前进程的 embedded.mobileprovision 里扫出所有 App Group 名。
    ///
    /// 为什么不解析 CMS：profile 是 CMS 签名包裹的 plist，解开需要完整的
    /// DER/ASN.1 解析，几十行代码还会多出一堆失败分支；而 plist 正文在 CMS 里
    /// 是**明文**存放的，直接按 isoLatin1 扫描 `group.xxx` 就能拿到全部名字。
    /// 扫到的名字只当候选，最终仍由 containerURL 实测把关，误扫不影响正确性。
    ///
    /// 未签名的 IPA 里没有这个文件（返回空数组），此时只剩 preferredIdentifier
    /// 一个候选 —— 这正是"还没签名就运行"的正常情况。
    private static func groupsFromEmbeddedProfile() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
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
}
