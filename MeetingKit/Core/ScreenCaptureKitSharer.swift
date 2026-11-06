//
//  ScreenCaptureKitSharer.swift
//  MeetingKit
//
//  屏幕共享的三条通道，按系统版本自动选择：
//
//    iOS 16 – 26   → 广播扩展（Broadcast Upload Extension + App Group）
//    iOS 27+       → ScreenCaptureKit 的 SCContentSharingPicker（本进程）
//    兜底          → ReplayKit in-app 捕获（只能共享本 App 画面）
//
//  为什么 SCK 这一层是**运行时绑定**而不是普通 import：
//  编译机（GitHub Actions 的 macos-15 / macos-26）最高只有 iOS 26.x SDK，
//  里面根本没有 ScreenCaptureKit。写 `import ScreenCaptureKit` 会直接编译失败，
//  于是产物里一行 SCK 代码都没有，iOS 27 用户装完照样开不了共享——这正是
//  1.6.0 只能在 iOS 27 上退化成 in-app 捕获的原因。
//
//  运行时绑定绕开了这个限制：
//    · dlopen 系统里的 ScreenCaptureKit.framework（设备上有，SDK 里没有也能加载）
//    · NSClassFromString / class_getInstanceMethod 取类与选择子
//    · 用 IMP 强转成 @convention(c) 函数指针调用
//  好处是一份 IPA 通吃 iOS 16–27；代价是所有类型都退化成 AnyObject，
//  编译器帮不上忙，所以每一步都写进 `resolutionLog`，真机上可以直接看到
//  卡在哪一环，而不是又一片黑屏。
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ObjectiveC
import WebRTC

/// 屏幕共享会话的统一抽象。
///
/// ViewModel 只认这个协议，不关心背后是扩展、SCK 还是 in-app 捕获。
protocol ScreenSharingSession: AnyObject {
    var onStateChange: ((ScreenSharingSessionState) -> Void)? { get set }
    /// 已推给编码器的帧数。诊断用。
    var frameCount: Int { get }
    /// 被 SCK 的 idle 帧挡下的次数（画面没变化）。诊断用。
    var idleFrameCount: Int { get }
    var lastFrameAt: Date? { get }
    func start(source: RTCVideoSource)
    func stop()
}

enum ScreenSharingSessionState {
    /// 系统面板已弹出，等用户选内容。
    case picking
    /// 已经在推帧。
    case running(startedAt: Date)
    /// 已停止（用户取消、或从系统共享条点了停止）。
    case stopped
    case failed(String)
}

/// 当前设备实际会用哪条通道。UI 要据此显示不同的操作说明。
enum ScreenSharingBackend: String {
    /// iOS 27+：系统内容面板，可选整个屏幕或单个 App。
    case screenCaptureKit
    /// iOS 27+ 但系统面板不可用：ReplayKit in-app 捕获，只能共享本 App。
    case inApp
    /// 带 inApp 兜底的展示名。
    var displayName: String {
        switch self {
        case .screenCaptureKit: return "ScreenCaptureKit"
        case .inApp: return "in-app 捕获"
        case .broadcastExtension: return "广播扩展"
        }
    }
    /// iOS 26 及以下：广播扩展（App Group + 独立进程）。
    case broadcastExtension
}

enum ScreenSharingSessionFactory {

    /// 当前系统是否支持「本进程内的共享」。
    ///
    /// iOS 26 及以下返回 false：那条路仍然走广播扩展，比 in-app 捕获更强
    /// （能共享整个屏幕、切到别的 App 也不断）。
    static var isSupported: Bool {
        backend != .broadcastExtension
    }

    static var backend: ScreenSharingBackend {
        // 顺序不能反：iOS 27 上广播扩展已经不会被系统拉起，
        // 必须先看 SCK，再退 in-app，最后才轮到扩展。
        guard #available(iOS 27.0, *) else { return .broadcastExtension }

        if ScreenCaptureKitRuntime.isUsable {
            return .screenCaptureKit
        }
        return .inApp
    }

    static func make() -> ScreenSharingSession? {
        guard #available(iOS 27.0, *) else { return nil }

        if ScreenCaptureKitRuntime.isUsable {
            return ScreenCaptureKitSharer()
        }
        return InAppScreenCapturer()
    }
}

// MARK: - 运行时绑定

/// 把 ScreenCaptureKit 的类与选择子按名字解析出来。
///
/// 所有调用都经过这里，好处是解析失败时能给出**具体缺哪一环**，
/// 而不是一个笼统的 "共享失败"。
enum ScreenCaptureKitRuntime {

    /// 框架可能落在这两处（公开框架 / 私有框架），逐个试。
    private static let frameworkPaths = [
        "/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit",
        "/System/Library/PrivateFrameworks/ScreenCaptureKit.framework/ScreenCaptureKit"
    ]

    private static let lock = NSLock()
    private static var didBootstrap = false
    private static var loadedPath: String?
    private static var pickerClass: AnyClass?
    private static var streamClass: AnyClass?
    private static var configurationClass: AnyClass?
    private static var pickerInstance: AnyObject?
    /// 解析过程的人话记录，直接进诊断面板。
    private static var log: [String] = []

    /// 解析结论。诊断面板会原样展示。
    static var resolutionLog: String {
        lock.lock(); defer { lock.unlock() }
        return log.joined(separator: " · ")
    }

    /// 追加一条运行期记录（未识别回调、异常分支都写这里）。
    static func note(_ text: String) {
        lock.lock()
        log.append(text)
        lock.unlock()
    }

    /// 只加载一次。
    ///
    /// 顺序有讲究：先问 NSClassFromString——如果系统 UI 已经把框架装进进程，
    /// 这里就直接命中；没命中再 dlopen（没链接过的框架不会预先加载，
    /// 只查类名永远是 nil，这就是"文档里有 API、运行时却不存在"的坑）；
    /// 最后再用 Bundle.load 兜一次，三条都失败才算这条路不可用。
    private static func bootstrap() {
        lock.lock(); defer { lock.unlock() }
        guard !didBootstrap else { return }
        didBootstrap = true

        if NSClassFromString("SCContentSharingPicker") == nil {
            for path in frameworkPaths where loadedPath == nil {
                if dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil {
                    loadedPath = path
                }
            }
            if NSClassFromString("SCContentSharingPicker") == nil {
                for path in frameworkPaths {
                    if let bundle = Bundle(path: path), bundle.load() {
                        loadedPath = path
                        break
                    }
                }
            }
        } else {
            loadedPath = "已在进程内"
        }

        pickerClass = NSClassFromString("SCContentSharingPicker")
        streamClass = NSClassFromString("SCStream")
        configurationClass = NSClassFromString("SCStreamConfiguration")

        if pickerClass == nil { log.append("框架未加载") }
        if pickerClass == nil { log.append("缺 SCContentSharingPicker") }
        if streamClass == nil { log.append("缺 SCStream") }
        if configurationClass == nil { log.append("缺 SCStreamConfiguration") }
    }

    /// 系统提供的内容选择器单例。取不到就说明这条路不可用。
    static func sharedPicker() -> AnyObject? {
        bootstrap()
        lock.lock(); defer { lock.unlock() }
        if let pickerInstance { return pickerInstance }
        guard let cls = pickerClass else { return nil }

        // 文档写的是 `class var shared`，但 Swift 名字与 ObjC 选择子不一定同名，
        // 多试几个：真机上只要命中一个就够了。
        for name in ["shared", "sharedPicker", "defaultPicker", "sharedInstance"] {
            if let imp = classIMP(cls, name) {
                typealias F = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
                if let value = unsafeBitCast(imp, to: F.self)(
                    cls as AnyObject,
                    NSSelectorFromString(name)
                ) {
                    let picker = value.takeUnretainedValue()
                    pickerInstance = picker
                    log.append("picker=\(name)")
                    return picker
                }
            }
        }
        log.append("取不到 picker 单例")
        return nil
    }

    /// 这条通道到底能不能用：类在、单例在、isAvailable 为真、present 存在。
    static var isUsable: Bool {
        guard let picker = sharedPicker() else { return false }
        // isAvailable 是 SCK 的自我判断（例如设备不支持、被家长控制禁用）。
        if let available = boolValue(picker, "isAvailable"), !available {
            lock.lock(); log.append("picker 报告不可用"); lock.unlock()
            return false
        }
        let canPresent = hasInstanceMethod(picker, "present")
            || hasInstanceMethod(picker, "presentForCurrentApplication")
        if !canPresent {
            lock.lock(); log.append("缺 present"); lock.unlock()
        }
        return canPresent && streamClass != nil && configurationClass != nil
    }

    static var streamType: AnyClass? { bootstrap(); return streamClass }
    static var configurationType: AnyClass? { bootstrap(); return configurationClass }

    // MARK: 底层工具

    static func hasInstanceMethod(_ obj: AnyObject, _ name: String) -> Bool {
        instanceIMP(obj, name) != nil
    }

    static func instanceIMP(_ obj: AnyObject, _ name: String) -> IMP? {
        guard let cls = object_getClass(obj),
              let method = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { return nil }
        return method_getImplementation(method)
    }

    static func classIMP(_ cls: AnyClass, _ name: String) -> IMP? {
        guard let method = class_getClassMethod(cls, NSSelectorFromString(name)) else { return nil }
        return method_getImplementation(method)
    }

    static func boolValue(_ obj: AnyObject, _ name: String) -> Bool? {
        guard let imp = instanceIMP(obj, name) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: F.self)(obj, NSSelectorFromString(name))
    }

    /// 无返回值、无参数。
    static func send(_ obj: AnyObject, _ name: String) {
        guard let imp = instanceIMP(obj, name) else { return }
        typealias F = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(imp, to: F.self)(obj, NSSelectorFromString(name))
    }

    /// 无返回值、一个对象参数。
    static func send(_ obj: AnyObject, _ name: String, _ arg: AnyObject) {
        guard let imp = instanceIMP(obj, name) else { return }
        typealias F = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(imp, to: F.self)(obj, NSSelectorFromString(name), arg)
    }

    static func setInt(_ obj: AnyObject, _ name: String, _ value: Int) {
        guard let imp = instanceIMP(obj, name) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(imp, to: F.self)(obj, NSSelectorFromString(name), value)
    }

    static func setBool(_ obj: AnyObject, _ name: String, _ value: Bool) {
        guard let imp = instanceIMP(obj, name) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: F.self)(obj, NSSelectorFromString(name), value)
    }

    static func setUInt32(_ obj: AnyObject, _ name: String, _ value: UInt32) {
        guard let imp = instanceIMP(obj, name) else { return }
        typealias F = @convention(c) (AnyObject, Selector, UInt32) -> Void
        unsafeBitCast(imp, to: F.self)(obj, NSSelectorFromString(name), value)
    }

    static func setTime(_ obj: AnyObject, _ name: String, _ value: CMTime) {
        guard let imp = instanceIMP(obj, name) else { return }
        typealias F = @convention(c) (AnyObject, Selector, CMTime) -> Void
        unsafeBitCast(imp, to: F.self)(obj, NSSelectorFromString(name), value)
    }

    /// alloc + 无参 init，用于 SCStreamConfiguration。
    static func newInstance(of cls: AnyClass) -> AnyObject? {
        guard let allocIMP = classIMP(cls, "alloc") else { return nil }
        typealias Alloc = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        guard let allocated = unsafeBitCast(allocIMP, to: Alloc.self)(
            cls as AnyObject,
            NSSelectorFromString("alloc")
        )?.takeRetainedValue() else { return nil }

        guard let initIMP = instanceIMP(allocated, "init") else { return allocated }
        typealias Init = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(initIMP, to: Init.self)(allocated, NSSelectorFromString("init"))?
            .takeRetainedValue()
    }

    /// alloc + 三参 init，用于 SCStream(filter:configuration:delegate:)。
    static func newInstance(
        of cls: AnyClass,
        selector name: String,
        _ a1: AnyObject,
        _ a2: AnyObject,
        _ a3: AnyObject?
    ) -> AnyObject? {
        guard let allocIMP = classIMP(cls, "alloc") else { return nil }
        typealias Alloc = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        guard let allocated = unsafeBitCast(allocIMP, to: Alloc.self)(
            cls as AnyObject,
            NSSelectorFromString("alloc")
        )?.takeRetainedValue() else { return nil }
        guard let initIMP = instanceIMP(allocated, name) else { return nil }

        typealias Init = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject?) -> Unmanaged<AnyObject>?
        return unsafeBitCast(initIMP, to: Init.self)(
            allocated,
            NSSelectorFromString(name),
            a1, a2, a3
        )?.takeRetainedValue()
    }

    /// addStreamOutput:type:sampleHandlerQueue:error:
    static func addStreamOutput(
        _ stream: AnyObject,
        output: AnyObject,
        type: Int,
        queue: AnyObject?
    ) -> Bool {
        guard let imp = instanceIMP(stream, "addStreamOutput:type:sampleHandlerQueue:error:") else {
            return false
        }
        typealias F = @convention(c) (
            AnyObject, Selector, AnyObject, Int, AnyObject?, UnsafeMutablePointer<AnyObject?>?
        ) -> Bool
        return unsafeBitCast(imp, to: F.self)(
            stream,
            NSSelectorFromString("addStreamOutput:type:sampleHandlerQueue:error:"),
            output, type, queue, nil
        )
    }

    /// startCaptureWithCompletionHandler:
    static func startCapture(_ stream: AnyObject, completion: @escaping (Error?) -> Void) {
        guard let imp = instanceIMP(stream, "startCaptureWithCompletionHandler:") else {
            completion(NSError(domain: "ScreenCaptureKit", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "系统不支持开始屏幕捕获"
            ]))
            return
        }
        let block: @convention(block) (AnyObject?) -> Void = { error in
            completion(error as? Error)
        }
        typealias F = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(imp, to: F.self)(
            stream,
            NSSelectorFromString("startCaptureWithCompletionHandler:"),
            unsafeBitCast(block, to: AnyObject.self)
        )
    }

    /// stopCaptureWithCompletionHandler:
    static func stopCapture(_ stream: AnyObject) {
        guard let imp = instanceIMP(stream, "stopCaptureWithCompletionHandler:") else { return }
        let block: @convention(block) (AnyObject?) -> Void = { _ in }
        typealias F = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(imp, to: F.self)(
            stream,
            NSSelectorFromString("stopCaptureWithCompletionHandler:"),
            unsafeBitCast(block, to: AnyObject.self)
        )
    }
}

// MARK: - iOS 27+ 的实现

final class ScreenCaptureKitSharer: NSObject, ScreenSharingSession {

    var onStateChange: ((ScreenSharingSessionState) -> Void)?

    /// 已推给编码器的帧数。诊断用。
    private(set) var frameCount = 0
    /// 被 SCK 的 idle 帧挡下的次数。静止画面时这个数会涨、帧数不涨——正常现象。
    private(set) var idleFrameCount = 0
    private(set) var lastFrameAt: Date?
    private(set) var lastError: String?

    /// 运行期解析结果，进诊断面板。
    var resolutionLog: String { ScreenCaptureKitRuntime.resolutionLog }

    private var picker: AnyObject?
    private var stream: AnyObject?
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var running = false
    private let stateLock = NSLock()

    /// 帧回调不挂在主队列：共享时用户很可能正在别的 App 里翻页，
    /// 主线程被降频不该拖住编码输入。
    private let sampleQueue = DispatchQueue(
        label: "com.tianqiong.meetingkit.screencapturekit",
        qos: .userInitiated
    )

    // MARK: - 生命周期

    func start(source: RTCVideoSource) {
        guard !running else { return }
        self.source = source
        self.capturer = RTCVideoCapturer(delegate: source)
        frameCount = 0
        idleFrameCount = 0
        lastFrameAt = nil
        lastError = nil

        guard let picker = ScreenCaptureKitRuntime.sharedPicker() else {
            fail("本机没有可用的系统内容选择器（ScreenCaptureKit 未加载）")
            return
        }
        self.picker = picker

        // 先 remove 再 add：重复点「开始共享」时不会叠加观察者，
        // 否则一次选择会触发多次 startStream。
        // 选择子名不一定和 Swift 名一致，逐个试。
        for name in ["removeObserver:", "removePickerObserver:", "remove:"] {
            if ScreenCaptureKitRuntime.hasInstanceMethod(picker, name) {
                ScreenCaptureKitRuntime.send(picker, name, self)
                break
            }
        }
        var added = false
        for name in ["addObserver:", "addPickerObserver:", "add:"] {
            if ScreenCaptureKitRuntime.hasInstanceMethod(picker, name) {
                ScreenCaptureKitRuntime.send(picker, name, self)
                added = true
                break
            }
        }
        guard added else {
            fail("系统内容选择器没有 addObserver 接口")
            return
        }

        ScreenCaptureKitRuntime.setBool(picker, "setIsActive:", true)
        running = true
        notify(.picking)

        if ScreenCaptureKitRuntime.hasInstanceMethod(picker, "present") {
            ScreenCaptureKitRuntime.send(picker, "present")
        } else if ScreenCaptureKitRuntime.hasInstanceMethod(picker, "presentForCurrentApplication") {
            ScreenCaptureKitRuntime.send(picker, "presentForCurrentApplication")
        } else {
            fail("系统内容选择器没有 present 接口")
        }
    }

    func stop() {
        let runningStream: AnyObject?
        stateLock.lock()
        runningStream = stream
        stream = nil
        running = false
        stateLock.unlock()

        if let runningStream {
            ScreenCaptureKitRuntime.stopCapture(runningStream)
        }
        if let picker {
            ScreenCaptureKitRuntime.setBool(picker, "setIsActive:", false)
            for name in ["removeObserver:", "removePickerObserver:", "remove:"] {
                if ScreenCaptureKitRuntime.hasInstanceMethod(picker, name) {
                    ScreenCaptureKitRuntime.send(picker, name, self)
                    break
                }
            }
        }
        notify(.stopped)
    }

    // MARK: - 建立 SCStream

    private func startStream(with filter: AnyObject) {
        guard let streamClass = ScreenCaptureKitRuntime.streamType,
              let configurationClass = ScreenCaptureKitRuntime.configurationType,
              let configuration = ScreenCaptureKitRuntime.newInstance(of: configurationClass) else {
            fail("无法创建屏幕捕获配置")
            return
        }

        let size = outputSize(for: filter)
        // iOS 上 width/height 的单位是**像素**，不是点。
        // 不显式设置会按内容原始分辨率输出，3x 屏整屏就是 1179x2556，
        // 编码器和上行带宽都吃不消。
        ScreenCaptureKitRuntime.setInt(configuration, "setWidth:", size.width)
        ScreenCaptureKitRuntime.setInt(configuration, "setHeight:", size.height)
        // 30fps 上限：屏幕内容不需要 60fps，省一半码率。
        ScreenCaptureKitRuntime.setTime(
            configuration,
            "setMinimumFrameInterval:",
            CMTime(value: 1, timescale: 30)
        )
        // BGRA 是 RTCCVPixelBuffer 唯一保证能直接吃的格式，避免每帧再做一次转换。
        ScreenCaptureKitRuntime.setUInt32(configuration, "setPixelFormat:", 1_111_970_369)
        ScreenCaptureKitRuntime.setBool(configuration, "setShowsCursor:", true)
        // 音频走独立的 RTCAudioTrack，这里再采一次会双份。
        ScreenCaptureKitRuntime.setBool(configuration, "setCapturesAudio:", false)
        ScreenCaptureKitRuntime.setInt(configuration, "setQueueDepth:", 3)

        guard let newStream = ScreenCaptureKitRuntime.newInstance(
            of: streamClass,
            selector: "initWithFilter:configuration:delegate:",
            filter,
            configuration,
            self
        ) else {
            fail("无法创建屏幕捕获流")
            return
        }

        // SCStreamOutputType.screen 的原始值是 0。
        guard ScreenCaptureKitRuntime.addStreamOutput(
            newStream,
            output: self,
            type: 0,
            queue: sampleQueue as AnyObject
        ) else {
            fail("无法接收屏幕帧（addStreamOutput 被拒绝）")
            return
        }

        stateLock.lock()
        stream = newStream
        stateLock.unlock()

        ScreenCaptureKitRuntime.startCapture(newStream) { [weak self] error in
            guard let self else { return }
            if let error {
                self.stateLock.lock()
                self.stream = nil
                self.running = false
                self.stateLock.unlock()
                self.fail(error.localizedDescription)
                return
            }
            self.notify(.running(startedAt: Date()))
        }
    }

    /// 输出画布：长边 1280，按内容宽高比缩放，且保证是偶数。
    private func outputSize(for filter: AnyObject) -> (width: Int, height: Int) {
        let rect = contentRect(of: filter) ?? CGRect(x: 0, y: 0, width: 16, height: 9)
        let width = max(rect.width, 1)
        let height = max(rect.height, 1)
        let ratio = width / height
        let longEdge: CGFloat = 1280

        if ratio >= 1 {
            return (even(Int(longEdge)), even(Int((longEdge / ratio).rounded())))
        }
        return (even(Int((longEdge * ratio).rounded())), even(Int(longEdge)))
    }

    private func contentRect(of filter: AnyObject) -> CGRect? {
        guard let imp = ScreenCaptureKitRuntime.instanceIMP(filter, "contentRect") else { return nil }
        typealias F = @convention(c) (AnyObject, Selector) -> CGRect
        let rect = unsafeBitCast(imp, to: F.self)(filter, NSSelectorFromString("contentRect"))
        return rect.width > 1 && rect.height > 1 ? rect : nil
    }

    private func even(_ value: Int) -> Int {
        max((value / 2) * 2, 2)
    }

    // MARK: - 收尾

    /// 运行时绑定的最后一道保险。
    ///
    /// 观察者协议的 Swift 名与 ObjC 选择子不一定同名。万一系统调用的是我们
    /// 没猜中的那个变体，NSObject 默认会抛 NSInvalidArgumentException，
    /// 整个会议 App 直接闪退。这里把未识别消息记下来后吞掉：
    /// 最坏结果是"这次选择没生效"，而不是用户在会议里被踢出去。
    override func doesNotRecognizeSelector(_ aSelector: Selector) {
        ScreenCaptureKitRuntime.note("未识别回调 \(NSStringFromSelector(aSelector))")
    }

    private func fail(_ message: String) {
        lastError = message
        running = false
        notify(.failed(message))
    }

    private func notify(_ state: ScreenSharingSessionState) {
        if Thread.isMainThread {
            onStateChange?(state)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(state)
            }
        }
    }
}

// MARK: - SCContentSharingPickerObserver
//
// 选择子用 @objc(名字:) 直接钉死。Swift 的 `func contentSharingPicker(_:didCancelFor:)`
// 未必导入成同名选择子，这里两种常见写法都实现一遍：
// 多实现一个没人调用的方法没有代价，少实现一个就是"点了没反应"。

extension ScreenCaptureKitSharer {

    @objc(contentSharingPicker:didUpdateWithFilter:forStream:)
    func pickerDidUpdateLong(_ picker: AnyObject, didUpdateWithFilter filter: AnyObject, forStream stream: AnyObject?) {
        handleFilterUpdate(filter)
    }

    @objc(contentSharingPicker:didUpdateWith:for:)
    func pickerDidUpdateShort(_ picker: AnyObject, didUpdateWith filter: AnyObject, for stream: AnyObject?) {
        handleFilterUpdate(filter)
    }

    @objc(contentSharingPicker:didCancelForStream:)
    func pickerDidCancelLong(_ picker: AnyObject, didCancelForStream stream: AnyObject?) {
        handleCancel()
    }

    @objc(contentSharingPicker:didCancelFor:)
    func pickerDidCancelShort(_ picker: AnyObject, didCancelFor stream: AnyObject?) {
        handleCancel()
    }

    @objc(contentSharingPickerStartDidFailWithError:)
    func pickerDidFail(_ error: AnyObject) {
        let description = (error as? NSError)?.localizedDescription ?? "系统内容选择器启动失败"
        fail(description)
    }

    private func handleFilterUpdate(_ filter: AnyObject) {
        // 共享中途用户在系统面板里换了内容：更新过滤器即可，
        // 不能重建 SCStream——重建会断流，对端画面黑一下。
        stateLock.lock()
        let existing = stream
        stateLock.unlock()

        if let existing {
            if let imp = ScreenCaptureKitRuntime.instanceIMP(existing, "updateContentFilter:completionHandler:") {
                let block: @convention(block) (AnyObject?) -> Void = { _ in }
                typealias F = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
                unsafeBitCast(imp, to: F.self)(
                    existing,
                    NSSelectorFromString("updateContentFilter:completionHandler:"),
                    filter,
                    unsafeBitCast(block, to: AnyObject.self)
                )
            }
            return
        }
        startStream(with: filter)
    }

    private func handleCancel() {
        // 已经有流在跑时，「取消」只是关掉面板，不代表停止共享。
        stateLock.lock()
        let hasStream = stream != nil
        stateLock.unlock()
        guard !hasStream else { return }
        running = false
        notify(.stopped)
    }
}

// MARK: - SCStreamOutput

extension ScreenCaptureKitSharer {

    /// 参数用 UnsafeRawPointer 而不是 CMSampleBuffer：
    /// @objc 方法的参数类型必须能映射到 ObjC，裸指针是 100% 安全的映射，
    /// 进了函数体再还原成 CMSampleBuffer。
    @objc(stream:didOutputSampleBuffer:ofType:)
    func streamDidOutput(
        _ stream: AnyObject,
        didOutputSampleBuffer sampleBufferPointer: UnsafeRawPointer,
        ofType type: Int
    ) {
        /* 不硬判 type == 0。
           SCStreamOutputType.screen 的原始值在 macOS 上是 0，但 iOS 27 是这个
           框架第一次进手机，枚举顺序没有公开保证。判错一个值就是"有帧但一帧都不推"，
           而音频缓冲没有图像缓冲区，下面的 imageBuffer 检查天然会把它滤掉。 */
        stateLock.lock()
        let isCurrent = self.stream === stream
        let stillRunning = running
        stateLock.unlock()
        guard isCurrent, stillRunning else { return }

        let sampleBuffer = unsafeBitCast(sampleBufferPointer, to: CMSampleBuffer.self)
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }

        /* SCK 与 ReplayKit 最大的语义差别：回调 ≠ 新画面。
           画面没变化时它照样回调，但附带的 status 是 idle，
           底层还是同一块 IOSurface。转发只会让编码器重复编同一张图。
           解析不出 status 时**照常转发**：宁可多推几帧，也不能黑屏。 */
        if let status = frameStatus(of: sampleBuffer), status != 0, status != 4 {
            idleFrameCount += 1
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let source,
              let capturer else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timestamp) * 1_000_000_000)
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timeStampNs)
        source.capturer(capturer, didCapture: frame)

        frameCount += 1
        lastFrameAt = Date()
    }

    /// 从 sample attachments 里找状态位。
    /// 键名常量（SCStreamFrameInfoStatus）是符号，运行时取不到，所以按名字模糊匹配。
    private func frameStatus(of sampleBuffer: CMSampleBuffer) -> Int? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[String: Any]], let first = attachments.first else { return nil }

        for (key, value) in first where key.lowercased().contains("status") {
            if let number = value as? NSNumber { return number.intValue }
            if let raw = value as? Int { return raw }
        }
        return nil
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureKitSharer {

    @objc(stream:didStopWithError:)
    func streamDidStop(_ stream: AnyObject, didStopWithError error: AnyObject) {
        stateLock.lock()
        let isCurrent = self.stream === stream
        if isCurrent {
            self.stream = nil
            running = false
        }
        stateLock.unlock()
        guard isCurrent else { return }

        lastError = (error as? NSError)?.localizedDescription
        notify(.stopped)
    }
}
