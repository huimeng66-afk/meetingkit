//
//  ShareBreadcrumb.swift
//  MeetingKit
//
//  屏幕共享的"黑匣子"。
//
//  为什么需要它：iOS 27 的 ScreenCaptureKit 是运行时绑定的，所有调用都走
//  objc_msgSend，参数类型错了、选择子对不上、系统在内部抛 NSException，
//  都不会在编译期报错——表现只有一个：**点一下共享，App 直接闪退**。
//  闪退后什么都留不下，只能靠猜。
//
//  这里做两件事：
//    1. 每个关键步骤先把"我走到哪了"落盘（同步写，崩溃也不会丢）；
//       下次启动读出来，就能知道是 setActive、present 还是建流时死的。
//    2. 挂一个 NSException 处理器，把异常名与原因也落盘。
//
//  另外还兼一个保险：如果上次共享没有正常收尾，本次会话就不再尝试 SCK，
//  直接走 in-app 捕获——同一台设备上不会连续闪退两次。
//

import Foundation

/// 上一次共享留下的现场。
enum ShareBreadcrumb {

    // MARK: - 存储位置

    /// Application Support/MeetingKit/。不用 UserDefaults：
    /// 崩溃瞬间的写入必须立即落到磁盘，不能被 cfprefsd 缓存吞掉。
    private static var directoryURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let dir = base.appendingPathComponent("MeetingKit", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static var stepURL: URL? { directoryURL?.appendingPathComponent("share-last-step.txt") }
    private static var crashURL: URL? { directoryURL?.appendingPathComponent("share-last-crash.txt") }
    private static var crashCountURL: URL? { directoryURL?.appendingPathComponent("share-sck-crashes.txt") }

    // MARK: - 启动时读取

    /// 上一次共享有没有收尾。true 表示中途崩溃 / 被杀。
    private(set) static var previousAttemptUnfinished = false
    /// 上一次停在哪个步骤。
    private(set) static var lastStep: String?
    /// 上一次的异常摘要（只有 NSException 才记得到）。
    private(set) static var lastException: String?

    /// SCK 连续崩溃次数，跨启动累计。
    ///
    /// 「下次跳过」只能挡一次：用户杀掉 App 重开，还是会再点共享、再崩。
    /// 这里记死次数，够数就永久改用 in-app——宁可只共享会议画面，
    /// 也不能让用户每次点共享都掉线。
    private(set) static var sckCrashCount = 0
    static let sckCrashLimit = 1

    /// 在 App 启动时调用一次。
    static func loadAtLaunch() {
        if let text = read(stepURL), !text.isEmpty {
            lastStep = text
            // 只有真正开始共享才会写 attempt:；正常停止会删掉文件。
            // 启动时还在，说明上次没走到收尾。
            previousAttemptUnfinished = text.hasPrefix("attempt:")
        }
        if let text = read(crashURL), !text.isEmpty {
            lastException = text
        }

        var count = 0
        let version = currentVersion
        // 计数带版本号：换了新版本就重新给一次机会。
        // 否则 1.6.6 留下的账会算在已经修好的 1.6.7 头上 ——
        // 用户装完新版第一次点共享还是 in-app，等于白装。
        if let stored = read(crashCountURL) {
            let parts = stored.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ":")
            if parts.count == 2, String(parts[0]) == version, let value = Int(parts[1]) {
                count = value
            }
        }
        // 只有死在 SCK 链路上（sck: 前缀）才计数：广播扩展、in-app 的
        // 正常失败不该把 SCK 判死刑。
        if previousAttemptUnfinished, let lastStep, lastStep.hasPrefix("attempt:sck:") {
            count += 1
            write("\(version):\(count)", to: crashCountURL)
            // 现场已消费，清文件避免同一次崩溃被重复计数；
            // lastStep / previousAttemptUnfinished 仍留在内存里给诊断面板用。
            finish()
        }
        sckCrashCount = count
        installExceptionHandler()
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// SCK 真的跑起来了：连续崩溃计数清零。
    static func recordSckSuccess() {
        guard sckCrashCount != 0 else { return }
        sckCrashCount = 0
        write("\(currentVersion):0", to: crashCountURL)
    }

    /// 这台设备还值不值得再试 SCK。
    static var isSckDisabled: Bool { sckCrashCount >= sckCrashLimit }

    // MARK: - 记录

    /// 记一步。同步写盘，崩溃也不丢。
    static func mark(_ step: String) {
        write("attempt:\(step)", to: stepURL)
    }

    /// 这一次共享正常结束了（停止 / 失败降级），清掉现场。
    static func finish() {
        guard let url = stepURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 诊断面板用的一行。没有记录时返回 nil。
    static var diagnosticLine: String? {
        if let lastException {
            return "上次共享异常：\(lastException)"
        }
        if previousAttemptUnfinished, let lastStep {
            let step = lastStep.replacingOccurrences(of: "attempt:", with: "")
            var text = "上次共享崩溃于「\(step)」（没有走到收尾）"
            if sckCrashCount > 0 {
                text += " · 第 \(sckCrashCount) 次"
                if isSckDisabled {
                    text += "，已停用系统捕获"
                }
            }
            return text
        }
        return nil
    }

    /// 记下一条"没崩、但确实出错了"的原因。
    ///
    /// 和崩溃分开存：崩溃是 attempt 文件没被清掉，正常失败是这里写一条。
    /// 两者都会进诊断面板，但只有前者会触发"本次跳过 SCK"。
    static func recordFailure(_ text: String) {
        write(text, to: crashURL)
    }

    fileprivate static func recordException(_ exception: NSException) {
        let text = "\(exception.name.rawValue)：\(exception.reason ?? "无原因")"
        write(text, to: crashURL)
    }

    // MARK: - 底层

    private static func read(_ url: URL?) -> String? {
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func write(_ text: String, to url: URL?) {
        guard let url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler(handleUncaughtException)
    }
}

/// 不能捕获上下文，必须是顶层函数才能转成 C 函数指针。
private func handleUncaughtException(_ exception: NSException) {
    ShareBreadcrumb.recordException(exception)
}
