//
//  MKScreenShareBuilder.m
//  MeetingKit
//
//  iOS 27 的 ScreenCaptureKit 只能运行时调用：构建机（macOS 15 / Xcode 26）
//  的 SDK 里没有这个框架的头文件，写 import ScreenCaptureKit 直接编译失败。
//
//  1.6.7 之前，这部分用「IMP 强转成函数指针」在 Swift 里做，出了两个问题：
//
//    1. 方法签名靠猜。CGRect 走 sret、CGFloat 位宽随架构变、CMTime 超过
//       16 字节走内存传递——任何一处猜错，读回来的就是寄存器垃圾（NaN），
//       后面 Int() 一步就 trap。
//    2. Swift 没有 @try/@catch。为了接住 NSException，只能把 block 用
//       unsafeBitCast 塞进 C 函数指针里跨语言调用——而 ARC 不认这个
//       "对象"，编译器可能在调用前就把它释放掉，系统拿到野指针，
//       EXC_BAD_ACCESS，进程直接消失。
//
//  ObjC 天生没有这两个问题：
//   · 发消息按选择子走，参数类型由运行时按真实 type encoding 转换；
//   · @try/@catch 是语言内建的，不需要任何跨语言技巧。
//
//  所以建流这一整段（配置、订阅、启动、停止、换源）都搬到这里。
//

#import <Foundation/Foundation.h>

/// 只声明选择子，不实现。构建机没有 SCK 头文件，但 ObjC 是动态的：
/// 声明只是让编译器允许发消息，真实实现由系统框架在运行时提供。
/// 这样就不用把方法签名抄成函数指针去猜。
@interface NSObject (MKScreenCaptureKitShims)
- (instancetype)initWithFilter:(id)filter configuration:(id)configuration delegate:(id)delegate;
- (BOOL)addStreamOutput:(id)output
                   type:(NSInteger)type
     sampleHandlerQueue:(dispatch_queue_t)queue
                  error:(NSError **)error;
- (void)startCaptureWithCompletionHandler:(void (^)(NSError *_Nullable error))handler;
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *_Nullable error))handler;
- (void)updateContentFilter:(id)filter completionHandler:(void (^)(NSError *_Nullable error))handler;
@end

@interface MKScreenShareBuilder : NSObject

/// 用一套「能设就设、设不进就用默认」的配置建流。
/// 返回 nil 时 error 里是具体原因（已包含失败发生在哪一步）。
+ (nullable id)streamWithFilter:(id)filter
                       delegate:(id)delegate
                          width:(NSInteger)width
                         height:(NSInteger)height
                          error:(NSString *_Nullable *_Nullable)error;

/// 订阅输出。返回 nil 表示成功，否则是错误描述。
+ (nullable NSString *)subscribe:(id)stream
                          output:(id)output
                            type:(NSInteger)type
                           queue:(dispatch_queue_t)queue;

/// 启动捕获。返回 NO 表示这次调用根本没被接受（不是"启动失败"，
/// 是连方法都没调进去）。真正的启动结果用 isCapturing 轮询判断。
+ (BOOL)start:(id)stream;

+ (void)stop:(id)stream;

/// 共享中途换内容。iOS 上这个方法本身标了 API_UNAVAILABLE，
/// 调不通就静默放弃——画面保持原样，总比把进程带走好。
+ (void)updateFilter:(id)stream filter:(id)filter;

@end

@implementation MKScreenShareBuilder

/// 空实现，只为让链接器保留这个类。
///
/// 这个类只被 Swift 用 `NSClassFromString(@"MKScreenShareBuilder")` 引用，
/// 编译期看不到任何静态调用点。开了 dead-strip 的构建配置会把「没人引用」
/// 的 ObjC 类整块裁掉，运行时就会拿到 nil —— 实现 `+load` 的类一定会保留。
+ (void)load {
}

/// 短名找不到时带模块前缀再找一次：Swift 类在 ObjC 运行时里可能叫
/// `ScreenCaptureKit.SCStream`（个别系统版本用这种写法）。
static Class MKResolveClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (cls) {
        return cls;
    }
    return NSClassFromString([@"ScreenCaptureKit." stringByAppendingString:name]);
}

+ (nullable id)streamWithFilter:(id)filter
                       delegate:(id)delegate
                          width:(NSInteger)width
                         height:(NSInteger)height
                          error:(NSString *_Nullable *_Nullable)error {
    NSString *step = @"init";
    @try {
        Class streamClass = MKResolveClass(@"SCStream");
        Class configClass = MKResolveClass(@"SCStreamConfiguration");

        if (!streamClass) {
            if (error) { *error = @"运行时找不到 SCStream"; }
            return nil;
        }
        if (!configClass) {
            if (error) { *error = @"运行时找不到 SCStreamConfiguration"; }
            return nil;
        }

        step = @"config-alloc";
        id config = [[configClass alloc] init];
        if (!config) {
            if (error) { *error = @"SCStreamConfiguration 初始化返回空"; }
            return nil;
        }

        /* 尺寸是可选的优化，不是建流的前提。
           单独包一层 catch：设不进去就用系统默认分辨率，
           绝不让"画质设置"把"能不能共享"拖下水。
           Apple 文档原话：默认配置就能用，只有需要定制时才改属性。 */
        if (width > 1 && height > 1) {
            step = @"config-size";
            @try {
                if ([config respondsToSelector:@selector(setWidth:)]) {
                    [config setValue:@(width) forKey:@"width"];
                }
                if ([config respondsToSelector:@selector(setHeight:)]) {
                    [config setValue:@(height) forKey:@"height"];
                }
            } @catch (NSException *exception) {
                NSLog(@"[MKSCK] 设置输出尺寸失败，改用系统默认：%@", exception.reason);
            }
        }

        step = @"stream-init";
        if (![streamClass instancesRespondToSelector:@selector(initWithFilter:configuration:delegate:)]) {
            if (error) { *error = @"SCStream 没有 initWithFilter:configuration:delegate:"; }
            return nil;
        }

        id stream = [[streamClass alloc] initWithFilter:filter configuration:config delegate:delegate];
        if (!stream) {
            if (error) { *error = @"SCStream 初始化返回空"; }
            return nil;
        }
        return stream;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSString stringWithFormat:@"建流异常（%@）%@：%@",
                      step,
                      exception.name,
                      exception.reason ?: @"无原因"];
        }
        return nil;
    }
}

+ (nullable NSString *)subscribe:(id)stream
                          output:(id)output
                            type:(NSInteger)type
                           queue:(dispatch_queue_t)queue {
    @try {
        if (![stream respondsToSelector:@selector(addStreamOutput:type:sampleHandlerQueue:error:)]) {
            return @"SCStream 没有 addStreamOutput:type:sampleHandlerQueue:error:";
        }
        NSError *error = nil;
        BOOL ok = [stream addStreamOutput:output type:type sampleHandlerQueue:queue error:&error];
        if (!ok) {
            return error.localizedDescription ?: @"addStreamOutput 返回 NO";
        }
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"订阅异常 %@：%@",
                exception.name,
                exception.reason ?: @"无原因"];
    }
}

+ (BOOL)start:(id)stream {
    @try {
        if (![stream respondsToSelector:@selector(startCaptureWithCompletionHandler:)]) {
            return NO;
        }
        /* 这个 block 完全在 ObjC 里，不跨越语言边界，生命周期由 ARC 保证。
           启动结果不在这里判定：SCK 的 completion 可能在很晚才回调，
           调用方会用 isCapturing 轮询确认。 */
        [stream startCaptureWithCompletionHandler:^(NSError *_Nullable error) {
            if (error) {
                NSLog(@"[MKSCK] startCapture 回调失败：%@", error.localizedDescription);
            }
        }];
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[MKSCK] startCapture 异常：%@", exception.reason);
        return NO;
    }
}

+ (void)stop:(id)stream {
    @try {
        if ([stream respondsToSelector:@selector(stopCaptureWithCompletionHandler:)]) {
            [stream stopCaptureWithCompletionHandler:nil];
        }
    } @catch (NSException *exception) {
        NSLog(@"[MKSCK] stopCapture 异常：%@", exception.reason);
    }
}

+ (void)updateFilter:(id)stream filter:(id)filter {
    @try {
        if (![stream respondsToSelector:@selector(updateContentFilter:completionHandler:)]) {
            return;
        }
        [stream updateContentFilter:filter completionHandler:^(NSError *_Nullable error) {
            if (error) {
                NSLog(@"[MKSCK] 更新共享内容失败：%@", error.localizedDescription);
            }
        }];
    } @catch (NSException *exception) {
        NSLog(@"[MKSCK] 更新共享内容异常：%@", exception.reason);
    }
}

@end
