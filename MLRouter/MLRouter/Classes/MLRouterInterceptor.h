// MLRouterInterceptor.h
#ifndef MLRouterInterceptor_h
#define MLRouterInterceptor_h

#import <Foundation/Foundation.h>

@class MLRouterRequest;

// 职责链走向 Block 节点强类型定义
typedef void(^MLInterceptorNextBlock)(MLRouterRequest * _Nonnull request);
typedef void(^MLInterceptorRejectBlock)(NSError * _Nullable error);

@protocol MLRouterInterceptor <NSObject>

@required
/**
 拦截器核心切面拦截处理方法

 ⚠️ 契约约束（务必遵守，否则行为未定义）：
 1. 拦截器应为【无状态】的轻量切面。框架每次路由执行都会重新 alloc/init 一个实例，
    不要依赖实例在多次路由间的共享状态；如需共享状态请自行加锁。
 2. next / reject 应在【同步】代码路径内调用（如登录态校验、公共参数注入）。
    若需异步（如网络鉴权后才放行），方法路由的【同步返回值将不可用】
    （executeRequest: 已同步返回，底层尚未执行），请改用 withCompletion 异步回调获取结果。
 3. 必须且只能调用 next 或 reject 一次，二者都不调用会导致路由永远挂起。

 @param request 携带了当前全链式点语法链入的所有参数、URL信息的 Request 构建器
 @param next  绿灯信号：调用 next(request) 将请求交棒给下一位拦截器或最终的寻址内核
 @param reject 红灯信号：调用 reject(error) 强行熔断中途截断该路由跳转，并抛出错误
 */
- (void)processRequest:(MLRouterRequest * _Nonnull)request
                  next:(MLInterceptorNextBlock _Nonnull)next
                reject:(MLInterceptorRejectBlock _Nonnull)reject;

@end

#endif /* MLRouterInterceptor_h */
