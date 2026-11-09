import Foundation
import UIKit

/// 真机诊断回传。
///
/// **为什么要有它。** 屏幕共享的故障几乎都表现成同一个现象——"对面糊"或者
/// "对面黑"，但成因完全不同：采集没出帧、编码器被 CPU 卡住、GCC 把码率掐到
/// 200kbps、或者流量走了 TURN 中继被服务器限速。这些区别只存在于 `getStats`
/// 里，而让用户手抄一屏文字，既慢又容易漏关键行，一轮排查要耗掉一整天。
///
/// 这里把诊断面板的**原文**加上一组关键指标 POST 到自己的服务端，
/// 开发侧按会议号 / 设备 / 时间就能把现场捞出来。
/// 它不发任何用户内容，也不参与媒体链路——上报失败一律静默，
/// 绝不影响正在进行的通话。
///
/// 1.9.24 起补了三件事，都是为了"把包发给别人测"这个场景：
///   1. `sessionId`：同一进程的所有上报共用一个会话号，服务端能把一次
///      测试完整串起来，不会被同设备的上一场会议混进来；
///   2. `event()`：共享开始/停止、入会/离会这类**时刻**单独发一条，
///      不必等 2 秒心跳——时序是这类故障最关键的证据；
///   3. 失败落盘：手机在电梯里、切后台被挂起时上报会失败，
///      这些记录先写进本地队列，下次网络恢复补发，不会整段丢失。
final class DiagReporter {

    static let shared = DiagReporter()

    /// 内部通道密钥。这不是安全边界：接口只写不读业务数据，
    /// 它的作用是挡住公网扫描器，不是防逆向。
    fileprivate static let key = "tq-diag-7f3a9c"

    /// 本地补发队列的上限。超过就砍掉最旧的一半——
    /// 它是应急通道，不是归档系统，不能让队列把存储吃满。
    private static let queueLimit = 300

    private let stateLock = NSLock()
    private var lastSentAt = Date.distantPast
    private var inFlight = false

    private let workQueue = DispatchQueue(label: "com.tianqiong.diag", qos: .utility)
    private var cachedDevice = ""

    /// 本次运行的会话号：`1109-113245`。
    /// 同一进程内固定，服务端按它分组就能还原"一次完整测试"。
    let sessionId: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMdd-HHmmss"
        return formatter.string(from: Date())
    }()

    /// 客户端时钟。服务端会另记一个 `ts`（到达时间），
    /// 两者一起才能分辨"设备本地时间不对"和"网络延迟很久"。
    private let bootedAt = Date()

    private init() {}

    /// 设备标识。用「机型 + 标识符前 6 位」：`iPhone14,2-A1B2C3`。
    /// 不用 `UIDevice.name`——它大多是 "iPhone"，多台设备分不开；
    /// 也不用完整 UUID，日志里不需要那么长。
    private var deviceName: String {
        if !cachedDevice.isEmpty { return cachedDevice }
        let model = UIDevice.current.model.replacingOccurrences(of: " ", with: "")
        let idfv = UIDevice.current.identifierForVendor?.uuidString.prefix(6) ?? "000000"
        let name = "\(model)-\(idfv)"
        cachedDevice = name
        return name
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)(\(build))"
    }

    // MARK: - 对外入口

    /// 上报一次。内部按 2 秒节流，调用方可以每秒无脑调。
    func report(room: String, uid: String, text: String, stats: [String: Any]) {
        guard !text.isEmpty else { return }
        guard allowSend() else { return }

        var payload = basePayload(room: room, uid: uid)
        payload["text"] = String(text.prefix(8000))
        payload["stats"] = stats
        send(payload)
    }

    /// 时刻型事件：共享开始/停止、入会/离会、连接状态翻转。
    ///
    /// 这类记录不参与 2 秒节流——它们本身就是"什么时候发生了什么"的证据，
    /// 被节流掉就等于丢证据。同类事件自己做 1 秒去重，防止界面抖动刷屏。
    func event(_ name: String, room: String, uid: String, extra: [String: Any] = [:]) {
        let now = Date()
        eventLock.lock()
        let last = lastEventAt[name] ?? .distantPast
        if now.timeIntervalSince(last) < 1.0 {
            eventLock.unlock()
            return
        }
        lastEventAt[name] = now
        eventLock.unlock()

        var payload = basePayload(room: room, uid: uid)
        payload["event"] = name
        payload["text"] = "事件：\(name)"
        var stats = extra
        stats["phase"] = phaseText
        payload["stats"] = stats
        workQueue.async { [weak self] in
            self?.sendNow(payload)
        }
    }

    private var eventLock = NSLock()
    private var lastEventAt: [String: Date] = [:]

    /// 当前阶段。服务端按这一栏能直接筛出"共享中"的样本。
    ///
    /// 存内存 + 低频落 UserDefaults：每次上报都读一次 plist 不值当，
    /// 而 App 被杀后还能保留上一次阶段，方便判断"是不是共享中崩的"。
    private var phaseValue = UserDefaults.standard.string(forKey: "tq.diag.phase") ?? "meeting"

    private var phaseText: String { phaseValue }

    /// 让业务侧告诉诊断通道"现在处在哪个阶段"。
    /// 不进上报路径的判定，只作为标签，供服务端分组。
    func setPhase(_ phase: String) {
        guard phase != phaseValue else { return }
        phaseValue = phase
        UserDefaults.standard.set(phase, forKey: "tq.diag.phase")
    }

    // MARK: - 组装

    private func basePayload(room: String, uid: String) -> [String: Any] {
        [
            "device": deviceName,
            "ver": versionText,
            "room": String(room.prefix(40)),
            "uid": String(uid.prefix(40)),
            "session": sessionId,
            "clientTs": ISO8601DateFormatter().string(from: Date()),
            "uptimeSec": Int(Date().timeIntervalSince(bootedAt)),
        ]
    }

    private func allowSend() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastSentAt) >= 2, !inFlight else { return false }
        lastSentAt = now
        inFlight = true
        return true
    }

    // MARK: - 发送

    private func send(_ payload: [String: Any]) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.flushQueueIfNeeded()
            self.sendNow(payload)
        }
    }

    /// 真发。失败就进本地队列，等下一轮补。
    private func sendNow(_ payload: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            finish()
            return
        }
        var request = URLRequest(
            url: TianqiongAPI.baseURL.appendingPathComponent("diag").appendingPathComponent("report")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DiagReporter.key, forHTTPHeaderField: "x-diag-key")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            /* 只有"确实没送到"才落盘：4xx 是格式/鉴权问题，
               补发一万次也还是 4xx，只会把队列撑爆。 */
            if error != nil || code == 0 || code >= 500 {
                self.enqueue(payload)
            }
            self.finish()
        }.resume()
    }

    private func finish() {
        stateLock.lock()
        inFlight = false
        stateLock.unlock()
    }

    // MARK: - 失败补发

    private var queueURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let dir = base.appendingPathComponent("MeetingKit", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("diag-queue.jsonl")
    }

    private func enqueue(_ payload: [String: Any]) {
        guard let url = queueURL,
              let line = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var data = line
        data.append(0x0A)
        workQueue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
            self.trimQueueIfNeeded(at: url)
        }
    }

    private func trimQueueIfNeeded(at url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > Self.queueLimit else { return }
        let kept = lines.suffix(Self.queueLimit / 2)
        try? kept.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 每次正式上报前，顺手补发一条积压记录。
    /// 一条一条发而不是批量：批量失败会整批重来，慢慢补更稳。
    private func flushQueueIfNeeded() {
        guard let url = queueURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else { return }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first,
              let data = String(first).data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        lines.removeFirst()
        let rest = lines.joined(separator: "\n")
        try? (rest.isEmpty ? "" : rest + "\n").write(to: url, atomically: true, encoding: .utf8)

        var request = URLRequest(
            url: TianqiongAPI.baseURL.appendingPathComponent("diag").appendingPathComponent("report")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DiagReporter.key, forHTTPHeaderField: "x-diag-key")
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error != nil || code == 0 || code >= 500 {
                /* 还是不通：把它塞回队首，下次再试。 */
                var back = first
                back.append("\n")
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seek(toOffset: 0)
                    try? handle.write(contentsOf: Data(back.utf8))
                }
            }
        }.resume()
    }
}
