import Foundation
import UIKit

/// 真机诊断回传。
///
/// **为什么要有它。** 屏幕共享的故障几乎都表现成同一个现象——"对面糊"或者
/// "对面黑"，但成因完全不同：采集没出帧、编码器被 CPU 卡住、GCC 把码率掐到
/// 200kbps、或者流量走了 TURN 中继被服务器限速。这些区别只存在于 `getStats`
/// 里，而让用户手抄一屏文字，既慢又容易漏关键行，一轮排查要耗掉一整天。
///
/// 这里每 2 秒把诊断面板的**原文**加上一组关键指标 POST 到自己的服务端，
/// 开发侧直接 GET 就能看到现场。它不发任何用户内容，也不参与媒体链路——
/// 上报失败一律静默，绝不影响正在进行的通话。
final class DiagReporter {

    static let shared = DiagReporter()

    /// 内部通道密钥。这不是安全边界：接口只写不读业务数据，
    /// 它的作用是挡住公网扫描器，不是防逆向。
    fileprivate static let key = "tq-diag-7f3a9c"

    private let stateLock = NSLock()
    private var lastSentAt = Date.distantPast
    private var inFlight = false

    private let workQueue = DispatchQueue(label: "com.tianqiong.diag", qos: .utility)
    private var cachedDevice = ""

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

    /// 上报一次。内部按 2 秒节流，调用方可以每秒无脑调。
    func report(room: String, uid: String, text: String, stats: [String: Any]) {
        guard !text.isEmpty else { return }

        stateLock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastSentAt) >= 2, !inFlight else {
            stateLock.unlock()
            return
        }
        lastSentAt = now
        inFlight = true
        stateLock.unlock()

        let payload: [String: Any] = [
            "device": deviceName,
            "ver": versionText,
            "room": room,
            "uid": uid,
            "text": text,
            "stats": stats,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            finish()
            return
        }
        var request = URLRequest(url: TianqiongAPI.baseURL.appendingPathComponent("diag").appendingPathComponent("report"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DiagReporter.key, forHTTPHeaderField: "x-diag-key")
        request.httpBody = body

        workQueue.async { [weak self] in
            URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
                /* 失败不重试、不提示。这条通道是给开发看现场的，
                   不能因为它自己不通而制造新的噪音。 */
                self?.finish()
            }.resume()
        }
    }

    private func finish() {
        stateLock.lock()
        inFlight = false
        stateLock.unlock()
    }
}
