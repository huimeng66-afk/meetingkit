//
//  UplinkBudget.swift
//  MeetingKit
//
//  P2P Mesh 的上行总预算。
//
//  为什么需要它：Mesh 里每条连接都是一份独立的编码和一份独立的上行。
//  共享 1080p 时每路 8Mbps，3 个人就是 24Mbps——家庭宽带的上行通常
//  只有 10~30Mbps，4G 上行 5~15Mbps，链路会被直接打满。
//  打满之后每条连接的 GCC 各自降码率，用户看到的是"所有人都糊"，
//  还会误以为是服务器不行（其实是本端上行不够）。
//
//  这里按网络类型给一个保守的总预算，再按当前人数均分。
//  宁可主动降一点码率，也不要让编码器把链路压爆后再被动雪崩。
//

import Foundation
import Network

final class UplinkBudget: @unchecked Sendable {

    static let shared = UplinkBudget()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()

    /// 首帧到达前先按 Wi-Fi 处理：NWPathMonitor 的第一次回调有延迟，
    /// 一上来就按 4Mbps 会把正常 Wi-Fi 误判成弱网。
    private var isWiFi = true
    private var isCellular = false
    private var isSatisfied = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.isSatisfied = path.status == .satisfied
            self.isWiFi = path.usesInterfaceType(.wifi)
            self.isCellular = path.usesInterfaceType(.cellular)
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(
            label: "com.tianqiong.meetingkit.netpath",
            qos: .utility
        ))
    }

    /// 总上行预算（bps）。
    ///
    /// Wi-Fi 12M 是"家庭宽带上行常打对折"之后的保守值；
    /// 蜂窝统一按 5M 起步：5G 上限更高，但共享场景要的是稳定，
    /// 一开始就把上行打满，弱信号下会比 5M 还惨。
    var totalBitrate: Int {
        lock.lock()
        defer { lock.unlock() }
        guard isSatisfied else { return 4_000_000 }
        if isWiFi { return 12_000_000 }
        if isCellular { return 5_000_000 }
        return 8_000_000
    }

    /// 每个对端能分到的视频码率。
    ///
    /// 下限 700kbps：再低连"能看清字"的底线都没有了，不如让用户关掉一路视频。
    func perPeer(preferred: Int, peers: Int) -> Int {
        let count = max(peers, 1)
        return max(min(preferred, totalBitrate / count), 700_000)
    }
}
