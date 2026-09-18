// CartAuthInterceptor.m
// 拦截器自注册：MLRouterInterceptorClass(类名, 优先级)，必须写在 @implementation 内。
// 行为：记录所有经过的 URL；URL 含 "blocked" 时 reject 触发降级兜底，其余放行。

#import "CartAuthInterceptor.h"
#import <MLRouter/MLRouterHeader.h>

static NSMutableArray<NSString *> *g_processedLog = nil;

@implementation CartAuthInterceptor

MLRouterInterceptorClass("CartAuthInterceptor", 40)

+ (void)initialize {
    if (self == [CartAuthInterceptor class]) {
        g_processedLog = [NSMutableArray array];
    }
}

+ (NSArray<NSString *> *)processedURLLog {
    return [g_processedLog copy];
}

+ (void)clearLog {
    @synchronized (g_processedLog) {
        [g_processedLog removeAllObjects];
    }
}

#pragma mark - MLRouterInterceptor

// 注意：拦截器应为无状态切面（框架每次路由重新实例化），共享状态用类级日志 + 锁。
- (void)processRequest:(MLRouterRequest * _Nonnull)request
                  next:(MLInterceptorNextBlock _Nonnull)next
                reject:(MLInterceptorRejectBlock _Nonnull)reject {
    @synchronized (g_processedLog) {
        [g_processedLog addObject:request.urlStr ?: @""];
    }
    if ([request.urlStr containsString:@"blocked"]) {
        reject([NSError errorWithDomain:@"MLCartComponent"
                                   code:403
                               userInfo:@{NSLocalizedDescriptionKey: @"组件拦截器拦截：URL 含 blocked"}]);
    } else {
        next(request);
    }
}

@end
