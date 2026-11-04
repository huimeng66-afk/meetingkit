//
//  DeviceIdentity.swift
//  MeetingKit
//
//  本机设备身份。
//
//  单设备登录需要两样东西：
//  1. 一个稳定的设备 ID —— 首次启动生成后写入 UserDefaults，之后一直复用。
//     用它而不是 IDFV：IDFV 在同一厂商的 App 之间共享，卸载重装会变；
//     我们要的是"这台设备上的这个 App"，UUID 更贴切，也更好排查。
//  2. 一个人类可读的设备名 —— 写进设置页的「设备与登录」，
//     让用户在别处登录时能认出被踢的是哪台机器。
//
//  iOS 16 起 UIDevice.name 在未获得用户授权时会返回 "iPhone"，
//  所以名称要做一次兜底：能拿到真实名称就用，拿不到就退到机型。
//

import Foundation
import UIKit

enum DeviceIdentity {

    private static let idKey = "tianqiong.device.id"

    /// 持久化的设备 ID。形如 `ios-3f2a...`，服务端会把长度 ≥ 8 的值当作 App 设备。
    static var id: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: idKey), existing.count >= 8 {
            return existing
        }

        let generated = "ios-" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        defaults.set(generated, forKey: idKey)
        return generated
    }

    /// 上报给服务端的设备名称。优先用用户在「设置 → 通用 → 关于本机」里起的名字。
    static var name: String {
        let raw = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let genericNames: Set<String> = ["iPhone", "iPad", "iPod touch", "iPhone 模拟器", "iPad 模拟器"]
        if raw.isEmpty || genericNames.contains(raw) {
            return modelLabel
        }
        return raw
    }

    /// 人类可读机型，例如 "iPhone 15 Pro"。
    static var modelLabel: String {
        let identifier = machineIdentifier
        if let label = modelMap[identifier] {
            return label
        }
        if identifier.hasPrefix("iPhone") {
            return "iPhone"
        }
        if identifier.hasPrefix("iPad") {
            return "iPad"
        }
        return UIDevice.current.model
    }

    /// 系统版本，例如 "iOS 18.2"。
    static var systemVersion: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    /// 系统 + 机型，例如 "iOS 18.2 · iPhone 15 Pro"。
    static var platform: String {
        "\(systemVersion) · \(modelLabel)"
    }

    /// 短设备号，设置页展示用。完整 ID 太长，后 8 位足够人工比对。
    static var shortId: String {
        String(id.suffix(8)).uppercased()
    }

    /// 硬件标识（utsname.machine）。模拟器上会返回 arm64 / x86_64。
    private static var machineIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)

        let mirror = Mirror(reflecting: systemInfo.machine)
        var identifier = ""
        for child in mirror.children {
            guard let value = child.value as? Int8, value != 0 else { break }
            identifier.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier
    }

    /// 常见机型对照表。没收录的型号回落到 "iPhone"/"iPad"，
    /// 不为了一个显示名把整张表维护成半年一更新的负担。
    private static let modelMap: [String: String] = [
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd)",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE (3rd)",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        "iPad13,18": "iPad (10th)",
        "iPad14,1": "iPad mini (6th)",
        "iPad14,3": "iPad Pro 11 (4th)",
        "iPad14,5": "iPad Pro 12.9 (6th)",
        "arm64": "iPhone 模拟器",
        "x86_64": "iPhone 模拟器",
    ]
}
