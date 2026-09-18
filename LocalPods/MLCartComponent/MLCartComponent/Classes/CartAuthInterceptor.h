// CartAuthInterceptor.h
// 组件拦截器：段宏自注册进全局拦截链（优先级 40，越大越先执行）
//
// ⚠️ 必须显式声明 <MLRouterInterceptor> 协议遵循。
// MLRouterInterceptorClass(类名, 优先级) 只负责把类名写进段表，
// 而 MLRouter 扫描段时用 `conformsToProtocol:@protocol(MLRouterInterceptor)` 作为准入条件。
// 漏写协议声明 ⇒ 拦截器被静默丢弃，既不报错也不进链，全局切面（鉴权/埋点/参数注入）全部失效。

#import <Foundation/Foundation.h>
#import <MLRouter/MLRouterInterceptor.h>

@interface CartAuthInterceptor : NSObject <MLRouterInterceptor>

/// 已处理过的 URL 日志（供集成测试 / 页面展示观测）
+ (NSArray<NSString *> *)processedURLLog;
+ (void)clearLog;

@end
