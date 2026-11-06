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
import UIKit
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

        /* 连续两次把进程带走，就不再让用户陪着试了。
           计数按版本存：换新版本会重新给一次机会（见 ShareBreadcrumb）。
           一次崩溃不足以禁用——上一次可能是别的环节，而这次已经修掉了。 */
        if ShareBreadcrumb.isSckDisabled {
            ScreenCaptureKitRuntime.note("SCK 已连续崩溃 \(ShareBreadcrumb.sckCrashCount) 次，本机改用 in-app")
            return .inApp
        }

        if ScreenCaptureKitRuntime.isUsable {
            return .screenCaptureKit
        }
        return .inApp
    }

    static func make(forceInApp: Bool = false) -> ScreenSharingSession? {
        guard #available(iOS 27.0, *) else { return nil }

        if !forceInApp, ScreenCaptureKitRuntime.isUsable {
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
    ///
    /// 同一条只留一次：诊断面板一行显示，重复十遍会把真正的关键信息挤出去。
    static func note(_ text: String) {
        lock.lock()
        if !log.contains(text) {
            log.append(text)
        }
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

        if resolveClass("SCContentSharingPicker") == nil {
            for path in frameworkPaths where loadedPath == nil {
                if dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil {
                    loadedPath = path
                }
            }
            if resolveClass("SCContentSharingPicker") == nil {
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

        pickerClass = resolveClass("SCContentSharingPicker")
        streamClass = resolveClass("SCStream")
        configurationClass = resolveClass("SCStreamConfiguration")

        if pickerClass == nil { log.append("框架未加载") }
        if pickerClass == nil { log.append("缺 SCContentSharingPicker") }
        if streamClass == nil { log.append("缺 SCStream") }
        if configurationClass == nil { log.append("缺 SCStreamConfiguration") }
    }

    /// 按名字取类。
    ///
    /// Swift 原生的类注册名是 `模块名.类名`，纯 `NSClassFromString("SCStream")`
    /// 会返回 nil。SCK 目前是 ObjC 框架，但 iOS 27 是它第一次进手机，
    /// 两种写法都试一遍，省得为一个点号再跑一轮真机。
    private static func resolveClass(_ name: String) -> AnyClass? {
        NSClassFromString(name) ?? NSClassFromString("ScreenCaptureKit.\(name)")
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
        if let available = boolValue(picker, "isAvailable") {
            if !available {
                lock.lock(); log.append("picker 报告不可用"); lock.unlock()
                return false
            }
            lock.lock(); log.append("available=1"); lock.unlock()
        }
        let canPresent = hasInstanceMethod(picker, "present")
            || hasInstanceMethod(picker, "presentForCurrentApplication")
            || hasInstanceMethod(picker, "presentPickerForCurrentApplication")
        if !canPresent {
            lock.lock(); log.append("缺 present"); lock.unlock()
        }
        /* active 开关必须存在。
           头文件里是 `@property (getter=isActive) BOOL active;`，setter 叫 setActive:。
           没有这个开关，present() 会静静地什么都不做——1.6.4 在 iOS 27 真机上
           点了共享没反应，就是把它拼成了 setIsActive: 导致的选择子找不到。 */
        let canActivate = hasInstanceMethod(picker, "setActive:")
            || hasInstanceMethod(picker, "setIsActive:")
        if !canActivate {
            lock.lock(); log.append("缺 active 开关"); lock.unlock()
        }
        return canPresent && canActivate && streamClass != nil && configurationClass != nil
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

    /// 无返回值、一个 NSInteger 参数。
    ///
    /// 用在 `presentPickerUsingContentStyle:`——枚举在 64 位上是 NSInteger，
    /// 与 Swift 的 Int 同位宽，直接按值传即可。
    static func sendInt(_ obj: AnyObject, _ name: String, _ value: Int) {
        guard let imp = instanceIMP(obj, name) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(imp, to: F.self)(obj, NSSelectorFromString(name), value)
    }

    // MARK: 选择器的激活与弹出
    //
    // 这两步是整条 SCK 链路的**唯一入口**，也是 1.6.4 折掉的地方：
    // 属性声明是 `@property (getter=isActive) BOOL active;`，
    // 于是 setter 叫 `setActive:`，而不是按属性名拼出来的 `setIsActive:`。
    // 选择子找不到时 objc_msgSend 什么都不会发生，也不会报错，
    // 表现出来就是"点了共享没弹窗、没反应"。

    // MARK: 异常护盾
    //
    // Swift 没有 @try/@catch，Objective-C 抛出的 NSException 会直接终止进程。
    // MKExceptionCatcher 是项目里唯一的 ObjC 文件，只做一件事：把 block 包进
    // @try/@catch，把异常转成字符串。找不到它（比如被裁掉）就退化成直接调用。

    static func shield(_ block: @escaping () -> Void) -> String? {
        guard let cls = NSClassFromString("MKExceptionCatcher"),
              let imp = classIMP(cls, "catchException:") else {
            block()
            return nil
        }
        /* 参数类型必须声明成 @convention(block)。
           1.6.7 这里是 `unsafeBitCast(boxed, to: AnyObject.self)`：ARC 不认
           这个"对象"，编译器可能在调用前就把它释放掉，系统拿到野指针，
           直接 EXC_BAD_ACCESS —— 闪退就发生在"护盾"自己身上。
           写成 block 类型后，生命周期由编译器按对象规则管理。 */
        let boxed: @convention(block) () -> Void = block
        typealias F = @convention(c) (
            AnyObject, Selector, @convention(block) () -> Void
        ) -> AnyObject?
        let result = unsafeBitCast(imp, to: F.self)(
            cls as AnyObject,
            NSSelectorFromString("catchException:"),
            boxed
        )
        return result as? String
    }

    /// 打开选择器。返回命中的 setter 名，用于诊断。
    static func activatePicker(_ picker: AnyObject) -> String? {
        for name in ["setActive:", "setIsActive:"] where hasInstanceMethod(picker, name) {
            setBool(picker, name, true)
            return String(name.dropLast())
        }
        return nil
    }

    static func deactivatePicker(_ picker: AnyObject) {
        for name in ["setActive:", "setIsActive:"] where hasInstanceMethod(picker, name) {
            setBool(picker, name, false)
            return
        }
    }

    /// 读回 active 标志。读不到返回 nil（不同系统版本可能只有 getter 没 setter）。
    static func isPickerActive(_ picker: AnyObject) -> Bool? {
        boolValue(picker, "isActive")
    }

    /// 弹出系统面板，返回真正调到的选择子。
    ///
    /// 首选无参 `present`（Apple 示例里整屏共享用的就是它）；
    /// 万一 iOS 27 只暴露了带 style 的变体，再按 `presentPickerUsingContentStyle:`
    /// 用 display(3) 直接进整屏选择；最后才是只限本 App 的入口。
    static func presentPicker(_ picker: AnyObject) -> String? {
        let chain = [
            "present",
            "presentPickerUsingContentStyle:",
            "presentForCurrentApplication",
            "presentPickerForCurrentApplication"
        ]
        for name in chain {
            guard hasInstanceMethod(picker, name) else { continue }
            if name.hasSuffix(":") {
                // SCShareableContentStyle.display = 3
                sendInt(picker, name, 3)
            } else {
                send(picker, name)
            }
            return name.hasSuffix(":") ? String(name.dropLast()) : name
        }
        return nil
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

// MARK: - 建流：全部交给 ObjC

/// `MKScreenShareBuilder` 的 Swift 入口。
///
/// 为什么这层这么薄：所有会碰到系统框架的调用（建配置、建流、订阅、启动）
/// 都发生在 ObjC 里面，那里有真正的 `@try/@catch`，参数类型由运行时按
/// 真实 type encoding 决定，不需要把方法签名抄成函数指针去猜。
///
/// 这里只用函数指针调**我们自己写的**类方法，签名由自己定义，
/// 不存在"猜系统 API"的风险。
enum SCKStreamBuilder {

    private static var builderClass: AnyClass? { NSClassFromString("MKScreenShareBuilder") }

    static func makeStream(
        filter: AnyObject,
        delegate: AnyObject,
        width: Int,
        height: Int
    ) -> (stream: AnyObject?, error: String?) {
        guard let cls = builderClass,
              let imp = ScreenCaptureKitRuntime.classIMP(
                cls,
                "streamWithFilter:delegate:width:height:error:"
              ) else {
            return (nil, "找不到 MKScreenShareBuilder")
        }
        typealias F = @convention(c) (
            AnyObject, Selector, AnyObject, AnyObject, Int, Int, UnsafeMutablePointer<NSString?>?
        ) -> AnyObject?
        var error: NSString?
        let stream = unsafeBitCast(imp, to: F.self)(
            cls as AnyObject,
            NSSelectorFromString("streamWithFilter:delegate:width:height:error:"),
            filter,
            delegate,
            width,
            height,
            &error
        )
        return (stream, error.map { $0 as String })
    }

    /// 返回 nil 表示订阅成功。
    static func subscribe(
        _ stream: AnyObject,
        output: AnyObject,
        type: Int,
        queue: DispatchQueue
    ) -> String? {
        guard let cls = builderClass,
              let imp = ScreenCaptureKitRuntime.classIMP(cls, "subscribe:output:type:queue:") else {
            return "找不到 MKScreenShareBuilder.subscribe"
        }
        typealias F = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, Int, AnyObject) -> AnyObject?
        let result = unsafeBitCast(imp, to: F.self)(
            cls as AnyObject,
            NSSelectorFromString("subscribe:output:type:queue:"),
            stream,
            output,
            type,
            queue as AnyObject
        )
        return result as? String
    }

    static func start(_ stream: AnyObject) -> Bool {
        guard let cls = builderClass,
              let imp = ScreenCaptureKitRuntime.classIMP(cls, "start:") else {
            return false
        }
        typealias F = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(imp, to: F.self)(
            cls as AnyObject,
            NSSelectorFromString("start:"),
            stream
        )
    }

    static func stop(_ stream: AnyObject) {
        guard let cls = builderClass,
              let imp = ScreenCaptureKitRuntime.classIMP(cls, "stop:") else { return }
        typealias F = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(imp, to: F.self)(
            cls as AnyObject,
            NSSelectorFromString("stop:"),
            stream
        )
    }

    static func updateFilter(_ stream: AnyObject, filter: AnyObject) {
        guard let cls = builderClass,
              let imp = ScreenCaptureKitRuntime.classIMP(cls, "updateFilter:filter:") else { return }
        typealias F = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        unsafeBitCast(imp, to: F.self)(
            cls as AnyObject,
            NSSelectorFromString("updateFilter:filter:"),
            stream,
            filter
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
    /// 选择器是否已经给过回应（选中或取消）。用于区分"面板还开着"和"面板没起来"。
    private var didReceivePickerCallback = false
    private let stateLock = NSLock()

    /// 帧回调不挂在主队列：共享时用户很可能正在别的 App 里翻页，
    /// 主线程被降频不该拖住编码输入。
    private let sampleQueue = DispatchQueue(
        label: "com.tianqiong.meetingkit.screencapturekit",
        qos: .userInitiated
    )

    // MARK: - 生命周期

    func start(source: RTCVideoSource) {
        // 系统面板由 UIKit 呈现，只认主线程。调用方目前都在主线程，
        // 这里再兜一道：从任意线程点进来也不会变成"什么都没发生"。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start(source: source) }
            return
        }
        guard !running else { return }
        self.source = source
        self.capturer = RTCVideoCapturer(delegate: source)
        frameCount = 0
        idleFrameCount = 0
        lastFrameAt = nil
        lastError = nil
        didReceivePickerCallback = false
        // 黑匣子第一步：之后每推进一步都落盘。
        // 万一系统在某个调用里把进程带走，下次启动就知道死在哪。
        ShareBreadcrumb.mark("sck:start")

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
        ShareBreadcrumb.mark("sck:observer")

        /* 顺序不能反：先把 active 打开，再 present。
           active 默认是 false，为 false 时 present() 什么都不做。
           这两步都套异常护盾：系统如果因为权限/entitlement 抛 NSException，
           护盾能接住并写进诊断，而不是把整个会议 App 带走。 */
        ShareBreadcrumb.mark("sck:activating")
        var setter: String?
        if let reason = ScreenCaptureKitRuntime.shield({
            setter = ScreenCaptureKitRuntime.activatePicker(picker)
        }) {
            ShareBreadcrumb.mark("sck:activate-exception")
            failWithException("打开系统选择器时异常", reason)
            return
        }
        guard let setter else {
            fail("系统内容选择器没有 active 开关")
            return
        }
        ScreenCaptureKitRuntime.note("active=\(setter)")
        ShareBreadcrumb.mark("sck:activated(\(setter))")

        running = true
        notify(.picking)

        ShareBreadcrumb.mark("sck:presenting")
        var presentName: String?
        if let reason = ScreenCaptureKitRuntime.shield({
            presentName = ScreenCaptureKitRuntime.presentPicker(picker)
        }) {
            ShareBreadcrumb.mark("sck:present-exception")
            failWithException("弹出系统面板时异常", reason)
            return
        }
        guard let presentName else {
            fail("系统内容选择器没有 present 接口")
            return
        }
        ScreenCaptureKitRuntime.note("present=\(presentName)")
        ShareBreadcrumb.mark("sck:presented(\(presentName))")

        schedulePresentCheck()
    }

    /// present 之后的体检。
    ///
    /// 正常情况下用户会在几秒内选好内容，filter 回调一到就建流。
    /// 如果 4 秒后既没有回调、active 又被系统复位了，说明面板根本没起来
    /// （选择子缺失、被系统拒绝都会这样）。与其让用户对着"等待选择"发呆，
    /// 不如报一次失败，让上层降级到 in-app 捕获——至少画面能出去。
    private func schedulePresentCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.running, self.stream == nil, !self.didReceivePickerCallback else {
                return
            }
            guard let picker = self.picker else { return }
            let active = ScreenCaptureKitRuntime.isPickerActive(picker)
            if active == false {
                ScreenCaptureKitRuntime.note("present 后 4 秒无回调，active 已被复位")
                self.fail("系统内容面板没有打开")
            } else {
                // 面板可能还开着，用户在看内容列表。只记一笔，不打断。
                ScreenCaptureKitRuntime.note("present 后 4 秒仍无 filter 回调")
            }
        }
    }

    func stop() {
        let runningStream: AnyObject?
        stateLock.lock()
        runningStream = stream
        stream = nil
        running = false
        stateLock.unlock()
        ShareBreadcrumb.finish()

        if let runningStream {
            SCKStreamBuilder.stop(runningStream)
        }
        if let picker {
            ScreenCaptureKitRuntime.deactivatePicker(picker)
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
        ShareBreadcrumb.mark("sck:stream-init")

        /* 尺寸、帧率、像素格式——一个都不设。
           1.6.6 设五个 API_UNAVAILABLE 的属性，崩；1.6.7 只留宽高，还是崩。
           Apple 的 iOS 27 示例和社区实现都是 `SCStreamConfiguration()`
           什么都不配就直接建流。这一版把变量减到零：连 contentRect /
           pointPixelScale 都不再读，建流路径上不碰任何可选属性。 */
        ShareBreadcrumb.mark("sck:cfg-default-size")

        /* 建流整段交给 ObjC（MKScreenShareBuilder）。
           这里不再拼函数指针、不再跨语言传 block —— 1.6.7 的崩溃正是
           发生在「异常护盾」自己身上：block 用 unsafeBitCast 塞进 C 函数
           指针后 ARC 不认它是对象，编译器提前释放，系统拿到野指针，
           EXC_BAD_ACCESS，@try/@catch 也拦不住。 */
        let (built, buildError) = SCKStreamBuilder.makeStream(
            filter: filter,
            delegate: self,
            width: 0,
            height: 0
        )
        if let buildError {
            fail("创建屏幕捕获流失败：\(buildError)")
            return
        }
        guard let newStream = built else {
            fail("创建屏幕捕获流失败")
            return
        }
        ShareBreadcrumb.mark("sck:stream-created")

        // SCStreamOutputType 的原始值：macOS 上是 screen=0 / audio=1。
        // iOS 27 是这个枚举第一次进手机，顺序没有公开保证，所以两种都订阅：
        // 订阅错的那个只会收到音频（没有图像缓冲区，处理时天然被过滤），
        // 比赌一个数字然后整场黑屏划算。
        var subscribed = false
        var lastSubscribeError: String?
        for outputType in [0, 1] {
            if let reason = SCKStreamBuilder.subscribe(
                newStream,
                output: self,
                type: outputType,
                queue: sampleQueue
            ) {
                lastSubscribeError = reason
            } else {
                subscribed = true
            }
        }
        guard subscribed else {
            fail("无法接收屏幕帧：\(lastSubscribeError ?? "addStreamOutput 被拒绝")")
            return
        }
        ShareBreadcrumb.mark("sck:outputs-added")

        stateLock.lock()
        stream = newStream
        stateLock.unlock()

        guard SCKStreamBuilder.start(newStream) else {
            stateLock.lock()
            stream = nil
            stateLock.unlock()
            fail("启动屏幕捕获失败")
            return
        }

        /* 启动结果用 isCapturing 轮询，不等 completion。
           SCK 的 completion 有时很晚才来（1.6.5 就因此让用户对着
           "等待选择"发呆）；读不到 isCapturing（nil）时按成功处理，
           宁可多发几帧，也不能把已经在跑的流误判成失败。 */
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.running else { return }
            self.stateLock.lock()
            let current = self.stream
            self.stateLock.unlock()
            guard let current, current === newStream else { return }

            if ScreenCaptureKitRuntime.boolValue(current, "isCapturing") == false {
                ShareBreadcrumb.mark("sck:capture-not-started")
                self.fail("屏幕捕获没有启动（isCapturing 仍为 false）")
                return
            }
            ShareBreadcrumb.mark("sck:running")
            // 真的跑起来了：把「连续崩溃」计数清零，
            // 否则偶发崩溃会让这台机器永久失去系统捕获。
            ShareBreadcrumb.recordSckSuccess()
            self.notify(.running(startedAt: Date()))
        }
    }

    /// 输出画布：长边 1280，按内容宽高比缩放，且保证是偶数。
    ///
    /// 单位换算踩过一次坑：`contentRect` 是**点**，`width/height` 是**像素**。
    /// 3x 屏整屏是 393×852 点，不乘 pointPixelScale 就只编码到 1/3 分辨率，
    /// 对端看到的是糊的。
    private func outputSize(for filter: AnyObject) -> (width: Int, height: Int) {
        let rect = pixelRect(of: filter)

        // 拿不到 contentRect 时按整屏兜底：分享整屏是最常见的情况，
        // 用 16:9 兜底反而会把手机竖屏画面压成一条。
        let full = screenPixelSize()
        let rawWidth = rect?.width ?? full.width
        let rawHeight = rect?.height ?? full.height
        let width = sanitize(rawWidth, fallback: 390)
        let height = sanitize(rawHeight, fallback: 844)

        let ratio = width / height
        let longEdge: CGFloat = 1280

        if ratio >= 1 {
            return (even(Int(longEdge)), even(Int((longEdge / ratio).rounded())))
        }
        return (even(Int((longEdge * ratio).rounded())), even(Int(longEdge)))
    }

    /// 任何非有限值（NaN / ±Inf）或离谱值都换成安全值。
    ///
    /// 这一行是 1.6.6 闪退的真正元凶：`Int(Double.nan)` 在 Swift 里是
    /// 运行时 trap（"Double value cannot be converted to Int"），
    /// 直接 SIGILL 带走进程，`@try/@catch` 和 NSException 处理器都抓不到，
    /// 表现出来和系统崩没有任何区别。而 `pointPixelScale` 是拿函数指针
    /// 强转读的，一旦 ABI 对不上就会读回寄存器里的垃圾——正好是 NaN。
    private func sanitize(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite, value >= 2, value <= 8192 else { return fallback }
        return value
    }

    private func screenPixelSize() -> CGSize {
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale > 0 ? UIScreen.main.scale : 3
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// contentRect（点）× pointPixelScale → 像素。
    ///
    /// 一律走 KVC 而不是拿 IMP 强转：CGRect 是 32 字节，返回值要走 sret，
    /// CGFloat 的位宽又随架构变。只要有一处和真实签名对不上，读回来的就是
    /// 垃圾（NaN / 天文数字），后面 `Int()` 一步就 trap。KVC 由运行时按
    /// 真实的 type encoding 取值，类型永远不会错。
    private func pixelRect(of filter: AnyObject) -> CGRect? {
        guard let object = filter as? NSObject else { return nil }

        var rect: CGRect?
        _ = ScreenCaptureKitRuntime.shield {
            guard object.responds(to: NSSelectorFromString("contentRect")),
                  let value = object.value(forKey: "contentRect") as? NSValue else { return }
            let candidate = value.cgRectValue
            guard candidate.width.isFinite, candidate.height.isFinite,
                  candidate.width > 1, candidate.height > 1 else { return }
            rect = candidate
        }
        guard var result = rect else { return nil }

        var scale: CGFloat = 1
        _ = ScreenCaptureKitRuntime.shield {
            guard object.responds(to: NSSelectorFromString("pointPixelScale")),
                  let number = object.value(forKey: "pointPixelScale") as? NSNumber else { return }
            let candidate = CGFloat(number.doubleValue)
            guard candidate.isFinite, candidate >= 1, candidate <= 4 else { return }
            scale = candidate
        }

        result.size = CGSize(width: result.width * scale, height: result.height * scale)
        return result
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

    /// 系统抛异常时的收尾：异常写进黑匣子（不随 fail 一起清掉），
    /// 然后走正常的失败路径降级。
    private func failWithException(_ context: String, _ reason: String) {
        ShareBreadcrumb.recordFailure("\(context)：\(reason)")
        fail("\(context)：\(reason)")
    }

    private func fail(_ message: String) {
        lastError = message
        running = false
        // 走到这里是一条完整的失败路径，不是崩溃——把现场清掉，
        // 免得下次启动被误判成"上次闪退"。
        ShareBreadcrumb.finish()
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
        didReceivePickerCallback = true
        // 共享中途用户在系统面板里换了内容：更新过滤器即可，
        // 不能重建 SCStream——重建会断流，对端画面黑一下。
        stateLock.lock()
        let existing = stream
        stateLock.unlock()

        if let existing {
            // 换源也走 ObjC：`updateContentFilter:completionHandler:` 在 iOS 上
            // 标了 API_UNAVAILABLE，调不通会抛异常 —— 以前这里用 IMP 强转
            // 加跨语言 block，抛出来就是闪退。现在最坏是"画面没换"，不是"人掉线"。
            SCKStreamBuilder.updateFilter(existing, filter: filter)
            return
        }

        // 建流必须回主线程。
        // 选择器的回调线程没有公开保证，而 SCStream 的初始化会碰到
        // UIKit / CoreAnimation 一侧的状态（UIScreen、CATransaction），
        // 在后台线程进这一步，运气不好就是一句断言。
        if Thread.isMainThread {
            startStream(with: filter)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running else { return }
                self.startStream(with: filter)
            }
        }
    }

    private func handleCancel() {
        didReceivePickerCallback = true
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
           SCFrameStatus：complete=0、idle=1、blank=2、started=3、suspended=4、stopped=5，
           只有 complete 和 started 是新画面。解析不出 status 时**照常转发**：
           宁可多推几帧，也不能黑屏。 */
        if let status = frameStatus(of: sampleBuffer), status != 0, status != 3 {
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
        ShareBreadcrumb.finish()
        notify(.stopped)
    }
}
