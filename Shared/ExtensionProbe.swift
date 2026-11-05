//
//  ExtensionProbe.swift
//  Shared
//
//  广播扩展的"黑匣子"。
//
//  ── 为什么需要它 ─────────────────────────────────────────────────────
//  1.5.4 的真机诊断出现了最难受的一种组合：
//      · App Group（扩展）：未上报      → 扩展没写会话头
//      · 扩展状态：idle · 心跳无         → 扩展没起播
//      · 主 App 读到：6 帧、已推 118 帧  → 却有进程在往容器里写 JPEG
//  这三条同时成立只有两种可能：
//    ① 起播的是**上一场残留的广播进程**（系统仍认为有一场共享在跑，
//       新扩展根本收不到 broadcastStarted）；
//    ② 新扩展进了 broadcastStarted，但在写会话头之前卡死/崩了，
//       而采样回调仍在另一个线程上继续出帧。
//  光看 App Group 里的状态分不出这两种——因为两种情况下状态都是空的。
//
//  所以必须有一个**不依赖 App Group**的通道：App 扩展与宿主 App 共享同一个
//  数据容器，`applicationSupportDirectory` 两边都能读写。扩展每走一步就落一条
//  记录，主 App 读出来直接显示"扩展有没有启动、卡在哪一步"。
//
//  ── 开销 ─────────────────────────────────────────────────────────────
//  一次广播只写十几次、每次几百字节，全部同步写（必须在崩溃/卡死前落盘）。
//  绝不放进每帧路径：只有"第一帧"会写一条。
//

import Foundation

enum ExtensionProbe {

    /// 一次启动的完整轨迹。最后一个写入的 `step` 就是"它停在了哪里"。
    struct Record: Codable {
        /// 本次进程第一次写探针的时间（扩展启动时刻）。
        var launchedAt: Double
        /// 最后一次写入时间。
        var updatedAt: Double
        /// 最后到达的步骤，见 SampleHandler 里的 mark 调用。
        var step: String
        /// 扩展解析到的 App Group（可能为 nil：还没解析到就停了）。
        var appGroup: String?
        /// App Group 容器是否真的可用。
        var containerOK: Bool?
        /// 扩展的 CFBundleShortVersionString，用来确认设备上跑的是新包。
        var version: String?
        var bundleID: String?
        /// 附加说明（错误原因、帧序号等）。
        var note: String?
    }

    private static let fileName = "broadcast-probe.json"
    private static let folderName = "MeetingKitProbe"

    private static let lock = NSLock()
    private static var current: Record?

    /// 宿主 App 数据容器里的几个可写目录。
    ///
    /// 关键点：App 扩展与宿主 App **共用同一个数据容器**，所以扩展写在这里的文件
    /// 主 App 能直接读到，完全不需要 App Group 授权。这也让它成为唯一能在
    /// "App Group 没配好"时仍然工作的诊断通道。
    ///
    /// 写三个目录是因为扩展里对 `applicationSupportDirectory` 的可见性在个别
    /// 系统版本上会返回 nil；Caches 与 tmp 一般都能写。读侧按同一组路径找最新记录，
    /// 任意一个成功就够用。
    private static let hostDirectories: [URL] = {
        let fm = FileManager.default
        let bases: [URL?] = [
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        ]

        var result: [URL] = []
        for base in bases {
            guard let base = base else { continue }
            let dir = base.appendingPathComponent(folderName, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                result.append(dir)
            } catch {
                continue
            }
        }
        return result
    }()

    /// 记录一步。`includeGroup` 为 false 时不碰 AppGroupConfig ——
    /// 第一条 "entered" 必须这样写：如果崩溃/卡死就发生在 App Group 解析里，
    /// 我们仍然要留下"进程进来过"的证据。
    static func mark(
        _ step: String,
        group: String? = nil,
        note: String? = nil,
        includeGroup: Bool = true,
        checkContainer: Bool = true
    ) {
        lock.lock()
        var record: Record
        if let existing = current {
            record = existing
        } else {
            let now = Date().timeIntervalSince1970
            record = Record(
                launchedAt: now,
                updatedAt: now,
                step: step,
                appGroup: nil,
                containerOK: nil,
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                bundleID: Bundle.main.bundleIdentifier,
                note: nil
            )
        }
        record.step = step
        record.updatedAt = Date().timeIntervalSince1970
        if let group = group {
            record.appGroup = group
        }
        if let note = note {
            record.note = note
        }
        if checkContainer {
            record.containerOK = AppGroupConfig.isAvailable
        }
        current = record
        lock.unlock()

        persist(record, includeGroup: includeGroup)
    }

    /// 读出最近一次记录。主 App 在诊断面板里用。
    static func latest() -> Record? {
        var newest: Record?
        for url in candidateFiles() {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(Record.self, from: data)
            else { continue }
            if newest == nil || decoded.updatedAt > newest!.updatedAt {
                newest = decoded
            }
        }
        return newest
    }

    /// 清掉旧记录（新一次会话开始前）。避免把上一场的启动时间当成本次的。
    static func reset() {
        lock.lock()
        current = nil
        lock.unlock()
        for url in candidateFiles() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 落盘

    private static func persist(_ record: Record, includeGroup: Bool) {
        guard let data = try? JSONEncoder().encode(record) else { return }

        var directories = hostDirectories
        if includeGroup, let group = AppGroupConfig.containerURL() {
            directories.append(group)
        }

        for dir in directories {
            try? data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        }
    }

    private static func candidateFiles() -> [URL] {
        var urls = hostDirectories.map { $0.appendingPathComponent(fileName) }
        // 读侧允许 App Group 容器为 nil（签名没授权时就是这个情况）。
        if let group = AppGroupConfig.containerURL() {
            urls.append(group.appendingPathComponent(fileName))
        }
        return urls
    }
}
