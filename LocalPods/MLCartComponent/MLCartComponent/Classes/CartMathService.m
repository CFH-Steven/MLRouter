// CartMathService.m
// 方法路由自注册：MLRouterMethodClass(类名, url, selector)。
// 注意：类名必须是字符串字面量（根治「文件名==类名」脆弱约定）。

#import "CartMathService.h"
#import <MLRouter/MLRouterHeader.h>

@implementation CartMathService

MLRouterMethodClass("CartMathService", "mlcomp://cart/total", "sumWithParams:")
MLRouterMethodClass("CartMathService", "mlcomp://cart/asyncSum", "asyncSumWithParams:completion:")

- (NSNumber *)sumWithParams:(NSDictionary *)params {
    NSInteger a = [params[@"a"] integerValue];
    NSInteger b = [params[@"b"] integerValue];
    return @(a + b);
}

- (void)asyncSumWithParams:(NSDictionary *)params completion:(void (^)(id _Nullable result))completion {
    // 模拟异步：延迟 0.1s 回传
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (completion) completion([self sumWithParams:params]);
    });
}

@end
