//
//  AppSettings.swift
//  MeetingKit
//
//  App 级设置的唯一事实源。
//
//  为什么不做成各页面各存一个 @AppStorage：这些开关会被入会页（预置麦克风/摄像头）、
//  会议室（共享时收起控件、离会确认）与 Haptics 同时读取。同一份偏好散落在多个视图里，
//  迟早出现"设置页已经关了、会议室里还在震"这种对不上的状态。
//  集中成一个 ObservableObject 后，界面订阅它、ViewModel 直接读它，改一处就全生效。
//
//  为什么整个类标 @MainActor：写入口只有设置页的开关，读入口也都在主线程
//  （ViewModel / 触觉封装）。用主线程隔离换掉一把锁，也避免 @Published 在后台线程
//  发通知触发 SwiftUI 的运行时警告。
//
//  为什么用 UserDefaults：七条标量，冷启动首帧之前必须读到；任何异步存储方案
//  都会让首页先闪一下默认值。键名统一带 `tianqiong.settings.` 前缀，避免与
//  UserProfileStore / AuthStore / LiquidGlassSettings 的键混在一起。
//

import Combine
import Foundation

// MARK: - 共享画质

/// 屏幕共享的两档画质。
///
/// 只做"流畅 / 清晰"两档而不是给码率滑杆：移动端共享的对象通常是 PPT 与文档，
/// 用户只需要在"字看得清"和"网络扛得住"之间选一次；暴露码率只会增加理解成本，
/// 而且服务端目前也没有按客户端码率自适应的接口。
enum ShareQuality: String, CaseIterable, Identifiable {

    /// 流畅优先。
    case balanced

    /// 清晰优先。
    case sharp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced:
            return "流畅"
        case .sharp:
            return "清晰"
        }
    }

    /// 一句话说明代价。设置项不能只写"清晰"——用户需要知道换来的是什么，
    /// 否则弱网下选了清晰再抱怨卡顿，会变成一次本可避免的客诉。
    var hint: String {
        switch self {
        case .balanced:
            return "弱网下优先保住帧率，共享里的细字会偏软"
        case .sharp:
            return "优先保住文字与图表细节，占用带宽更高"
        }
    }
}

// MARK: - 设置

@MainActor
final class AppSettings: ObservableObject {

    /// 全局唯一实例。所有读取方拿同一份，避免出现两份内存状态。
    static let shared = AppSettings()

    // MARK: 会议

    /// 进入会议时默认打开麦克风。
    @Published var defaultMicOn: Bool {
        didSet { persist(defaultMicOn, for: Keys.defaultMicOn) }
    }

    /// 进入会议时默认打开摄像头。与 JoinInfo 的默认值保持一致（默认关闭）。
    @Published var defaultCameraOn: Bool {
        didSet { persist(defaultCameraOn, for: Keys.defaultCameraOn) }
    }

    /// 进会后自动静音。主持人/企业会议常用：先保证会场安静，再按需开麦。
    @Published var autoMuteOnJoin: Bool {
        didSet { persist(autoMuteOnJoin, for: Keys.autoMuteOnJoin) }
    }

    // MARK: 屏幕共享

    /// 共享画质。存 rawValue 而不是枚举下标：下标会随 case 顺序变化而错位。
    @Published var shareQuality: ShareQuality {
        didSet { UserDefaults.standard.set(shareQuality.rawValue, forKey: Keys.shareQuality) }
    }

    /// 共享时 4 秒无操作自动收起控件。
    @Published var autoHideControlsDuringShare: Bool {
        didSet {
            persist(autoHideControlsDuringShare, for: Keys.autoHideControlsDuringShare)
        }
    }

    // MARK: 通用

    /// 触觉反馈总开关。Haptics 是全局工具，由调用方在读这个值后决定是否触发。
    @Published var hapticsEnabled: Bool {
        didSet { persist(hapticsEnabled, for: Keys.hapticsEnabled) }
    }

    // MARK: - 初始化

    private init() {
        // 初始化阶段给属性赋值不会触发 didSet，所以这里只负责"读"，不会把默认值
        // 反写回存储——"键从未写过"和"用户主动选了默认值"在存储层保持可区分。
        defaultMicOn = Self.readBool(Keys.defaultMicOn, fallback: Defaults.defaultMicOn)
        defaultCameraOn = Self.readBool(Keys.defaultCameraOn, fallback: Defaults.defaultCameraOn)
        autoMuteOnJoin = Self.readBool(Keys.autoMuteOnJoin, fallback: Defaults.autoMuteOnJoin)
        shareQuality = Self.readShareQuality()
        autoHideControlsDuringShare = Self.readBool(
            Keys.autoHideControlsDuringShare,
            fallback: Defaults.autoHideControlsDuringShare
        )
        hapticsEnabled = Self.readBool(Keys.hapticsEnabled, fallback: Defaults.hapticsEnabled)
    }

    // MARK: - 重置

    /// 恢复出厂设置（设置页"恢复默认"用）。
    ///
    /// 逐项赋值而不是批量 removeObject：每个属性的 didSet 会把新值写回存储，
    /// 因此重置后立刻杀进程再启动，读到的仍是这组默认值，而不是依赖 fallback 的"看起来一样"。
    /// 也不能只改内存——那样当前页面看着恢复了，下次冷启动又回到用户改过的值。
    func resetToDefaults() {
        defaultMicOn = Defaults.defaultMicOn
        defaultCameraOn = Defaults.defaultCameraOn
        autoMuteOnJoin = Defaults.autoMuteOnJoin
        shareQuality = Defaults.shareQuality
        autoHideControlsDuringShare = Defaults.autoHideControlsDuringShare
        hapticsEnabled = Defaults.hapticsEnabled
    }

    // MARK: - 非隔离快照

    /// 触觉总开关的只读快照。
    ///
    /// `Haptics` 是全局工具，可能从任意线程被调用（例如 RTC 回调里提示一次失败），
    /// 不能让它为了读一个布尔值去跳主线程——那会把一次触觉变成一次异步派发，
    /// 手感反而变差。这里直接读 UserDefaults，语义与设置页写入的值完全一致。
    nonisolated static var hapticsEnabledSnapshot: Bool {
        readBool(Keys.hapticsEnabled, fallback: Defaults.hapticsEnabled)
    }

    /// 共享时自动收起控件的只读快照。共享舞台是普通 View，不是 MainActor 隔离的
    /// 类型，读实例属性会引入一次跨 actor 访问；布尔偏好没必要为此付出代价。
    nonisolated static var autoHideControlsDuringShareSnapshot: Bool {
        readBool(
            Keys.autoHideControlsDuringShare,
            fallback: Defaults.autoHideControlsDuringShare
        )
    }

    /// 共享画质的只读快照。屏幕共享的启动路径在 RTC 层，
    /// 不在主线程的观察链上；这里直接读 UserDefaults，拿到的一定是设置页刚写入的值。
    nonisolated static var shareQualitySnapshot: ShareQuality {
        let raw = UserDefaults.standard.string(forKey: Keys.shareQuality) ?? ""
        return ShareQuality(rawValue: raw) ?? Defaults.shareQuality
    }

    /// 入会默认音视频的只读快照。
    ///
    /// 首页与入会页在 `init` 里就要给开关赋初值，而 SwiftUI 的 View init 不是
    /// MainActor 隔离的。与其在 onAppear 里补一次赋值（会让首帧闪一下默认值），
    /// 不如提供一个同步、无隔离的读取口。
    nonisolated static var mediaDefaultsSnapshot: (mic: Bool, camera: Bool) {
        (
            readBool(Keys.defaultMicOn, fallback: Defaults.defaultMicOn),
            readBool(Keys.defaultCameraOn, fallback: Defaults.defaultCameraOn)
        )
    }

    // MARK: - 存储键

    /// 所有键集中一处。散在属性里手写下标时，一个字母打错只会静默读到 fallback，
    /// 没有任何编译错误，是设置类最难排查的一类问题。
    private enum Keys {
        private static let prefix = "tianqiong.settings."

        static let defaultMicOn = prefix + "defaultMicOn"
        static let defaultCameraOn = prefix + "defaultCameraOn"
        static let autoMuteOnJoin = prefix + "autoMuteOnJoin"
        static let shareQuality = prefix + "shareQuality"
        static let autoHideControlsDuringShare = prefix + "autoHideControlsDuringShare"
        static let hapticsEnabled = prefix + "hapticsEnabled"
    }

    /// 默认值的唯一来源：初始化读取与"恢复默认"共用，避免两处各维护一份常量。
    private enum Defaults {
        static let defaultMicOn = true

        /// 与 JoinInfo 默认值一致：先听再说，也少一次摄像头授权弹窗。
        static let defaultCameraOn = false

        /// 默认不自动静音：普通参会者进会就想说话，莫名静音会让人以为麦克风坏了。
        static let autoMuteOnJoin = false

        /// 默认清晰：这个 App 的共享场景是文档、代码、表格，
        /// 720p 下 12pt 的正文在网页端放大后完全糊掉——用户第一句反馈就是"很糊"。
        /// 流畅档保留给弱网用户手动切换。
        static let shareQuality: ShareQuality = .sharp

        /// 默认**不**自动收起：观看共享时用户仍要随时能静音、调音量、离开。
        /// 想要沉浸观看的人可以在设置里自己打开。
        static let autoHideControlsDuringShare = false

        static let hapticsEnabled = true
    }

    // MARK: - 读写

    private func persist(_ value: Bool, for key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// `bool(forKey:)` 把"从没写过"和"写过 false"都返回 false，
    /// 所以必须先判断键是否存在；否则默认开启的项在首次启动时会是关闭的。
    ///
    /// 标 nonisolated：上面两个 `Snapshot` 属性要在非主线程上下文里同步读设置，
    /// 而 @MainActor 类里的 static 方法默认也带隔离，不摘掉就只能在主线程调用。
    nonisolated private static func readBool(_ key: String, fallback: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    /// 读到未知的 rawValue（旧版本枚举名、被外部改写的偏好）时回落默认档。
    /// 这里绝不能强解包：偏好数据不是可信输入，读坏了也不能让 App 启动即崩。
    private static func readShareQuality() -> ShareQuality {
        let raw = UserDefaults.standard.string(forKey: Keys.shareQuality) ?? ""
        return ShareQuality(rawValue: raw) ?? .sharp
    }
}
