// RTInterceptors.m
// 两个拦截器，priority 10 / 90，用于验证「priority 升序 → 先执行」的职责链顺序，
// 以及 reject 之后职责链是否被真正熔断（后续拦截器不再进链）。

#import "RTInterceptors.h"
#import <MLRouter/MLRouterHeader.h>

// URL 命中该前缀即触发阻断，用于验证「被拦截 → 走降级兜底」
static NSString *const RTBlockPrefix = @"rtkit://block";

static NSMutableArray<NSString *> *g_rtInterceptorLog = nil;

@implementation RTInterceptorLog

+ (void)initialize {
    if (self == [RTInterceptorLog class]) {
        g_rtInterceptorLog = [NSMutableArray array];
    }
}

+ (void)append:(NSString *)entry {
    if (entry.length == 0) return;
    @synchronized (g_rtInterceptorLog) {
        [g_rtInterceptorLog addObject:entry];
    }
}

+ (NSArray<NSString *> *)entries {
    @synchronized (g_rtInterceptorLog) {
        return [g_rtInterceptorLog copy];
    }
}

+ (void)reset {
    @synchronized (g_rtInterceptorLog) {
        [g_rtInterceptorLog removeAllObjects];
    }
}

+ (NSInteger)indexOfEntryContaining:(NSString *)keyword {
    NSArray<NSString *> *snapshot = [self entries];
    for (NSInteger i = 0; i < (NSInteger)snapshot.count; i++) {
        if ([snapshot[i] containsString:keyword]) return i;
    }
    return -1;
}

+ (NSString *)reportText {
    NSArray<NSString *> *snapshot = [self entries];
    if (snapshot.count == 0) return @"(拦截器日志为空 —— 说明拦截器没有进链)";
    NSMutableArray *lines = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)snapshot.count; i++) {
        [lines addObject:[NSString stringWithFormat:@"%02ld  %@", (long)i, snapshot[i]]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

@end

#pragma mark - 拦截器 1：priority 10（先执行）

@interface RTEarlyInterceptor : NSObject <MLRouterInterceptor>
@end

@implementation RTEarlyInterceptor

MLRouterInterceptorClass("RTEarlyInterceptor", 10)

- (void)processRequest:(MLRouterRequest *)request
                  next:(MLInterceptorNextBlock)next
                reject:(MLInterceptorRejectBlock)reject {
    [RTInterceptorLog append:[NSString stringWithFormat:@"RTEarlyInterceptor(p10) ← %@", request.urlStr]];
    if ([request.urlStr hasPrefix:RTBlockPrefix]) {
        reject([NSError errorWithDomain:@"RTTestKit"
                                   code:403
                               userInfo:@{NSLocalizedDescriptionKey: @"被 RTEarlyInterceptor 阻断（URL 命中 rtkit://block）"}]);
        return;
    }
    next(request);
}

@end

#pragma mark - 拦截器 2：priority 90（后执行）

@interface RTLateInterceptor : NSObject <MLRouterInterceptor>
@end

@implementation RTLateInterceptor

MLRouterInterceptorClass("RTLateInterceptor", 90)

- (void)processRequest:(MLRouterRequest *)request
                  next:(MLInterceptorNextBlock)next
                reject:(MLInterceptorRejectBlock)reject {
    (void)reject;
    [RTInterceptorLog append:[NSString stringWithFormat:@"RTLateInterceptor(p90)  ← %@", request.urlStr]];
    next(request);
}

@end
