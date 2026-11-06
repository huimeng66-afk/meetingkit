//
//  MKExceptionCatcher.m
//  MeetingKit
//
//  Swift 接不住 Objective-C 的 NSException：一旦系统框架抛出来，
//  进程直接终止，日志里只留下一个 EXC_CRASH，什么都看不到。
//
//  iOS 27 的 ScreenCaptureKit 全部走运行时绑定，选择子、参数类型都是我们
//  按名字猜的，猜错时最可能的表现就是系统抛 NSInternalInconsistencyException。
//  这个类只有十几行：把一段调用包进 @try/@catch，把异常转成字符串返回，
//  进程继续活着，诊断面板里还能看到原因。
//
//  调用方是 Swift，通过 NSClassFromString + IMP 调，不需要桥接头文件。
//

#import <Foundation/Foundation.h>

@interface MKExceptionCatcher : NSObject

/// 执行 block；抛异常时返回 "异常名：原因"，正常返回 nil。
+ (nullable NSString *)catchException:(void (^)(void))block;

@end

@implementation MKExceptionCatcher

+ (nullable NSString *)catchException:(void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *name = exception.name ?: @"NSException";
        NSString *reason = exception.reason ?: @"无原因";
        return [NSString stringWithFormat:@"%@：%@", name, reason];
    }
}

@end
