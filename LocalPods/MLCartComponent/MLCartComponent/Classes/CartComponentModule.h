// CartComponentModule.h
// 购物车组件模块：段宏自注册 + moduleSetup 自举注册动态路由 + 生命周期转发
//
// ⚠️ 必须显式声明 <MLRouterModule> 协议遵循。
// MLRouterModule(类名) 段宏只负责「告诉框架有哪些模块类」，
// 而 MLRouterModuleManager 在扫描后会做一次 `conformsToProtocol:` 校验 —— 声明了协议才认。
// 只写段宏、漏写协议声明 ⇒ 模块被静默跳过（控制台只有一行 error），
// 表现为 moduleSetup/moduleInit/生命周期钩子全都不执行、动态路由整体缺失，且无任何崩溃提示。

#import <Foundation/Foundation.h>
#import <MLRouter/MLRouterModule.h>

@interface CartComponentModule : NSObject <MLRouterModule>

/// 是否已执行 moduleSetup（观测用）
+ (BOOL)didSetup;
/// 是否已执行 moduleInit（观测用；跨仓依赖拓扑顺序测试依赖此标志）
+ (BOOL)didInit;
/// 生命周期执行日志
+ (NSArray<NSString *> *)lifecycleLog;

@end
