// MLRouterModule.h
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 模块协议：每个业务组件实现一个 Module 类，负责「自举」与「响应 App 生命周期」。

 组件化里模块不应依赖 AppDelegate 去初始化自己，而是由框架在启动时统一扫描、按依赖顺序初始化，
 并把 App 生命周期事件转发给各模块，实现模块对宿主的零侵入。

 约定：
 - moduleSetup   最早执行，用于注册本模块对外提供的服务 / 路由。
 - moduleInit    在全部模块 moduleSetup 之后执行，用于初始化模块私有资源。
 - 其余为 App 生命周期转发钩子（均可选实现）。
 - modulePriority 越大越先初始化；moduleDependencies 声明依赖的其他模块类名。
 */
@protocol MLRouterModule <NSObject>
@optional
+ (NSInteger)modulePriority;                   // 越大越先初始化（默认 0）
+ (NSArray<NSString *> *)moduleDependencies;   // 依赖的其他模块类名，形如 @[@"CartModule"]
- (void)moduleSetup;                           // 注册服务 / 路由
- (void)moduleInit;                            // 初始化模块私有资源
- (void)applicationDidFinishLaunching:(UIApplication *)application;
- (void)applicationDidEnterBackground:(UIApplication *)application;
- (void)applicationWillEnterForeground:(UIApplication *)application;
- (BOOL)applicationOpenURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options;
@end

@interface MLRouterModuleManager : NSObject

/// 扫描段 + 按依赖拓扑排序 + 执行 moduleSetup / moduleInit（AppDelegate 启动时调用一次）
/// 内部会先确保 MLRouter 的段扫描已完成，调用方无需关心初始化顺序。
+ (void)loadModules;
/// App 生命周期转发（在 AppDelegate 对应方法内调用）
+ (void)applicationDidFinishLaunching:(UIApplication *)application;
+ (void)applicationDidEnterBackground:(UIApplication *)application;
+ (void)applicationWillEnterForeground:(UIApplication *)application;
+ (BOOL)applicationOpenURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options;
/// 运行时注册（测试 / 动态模块）
+ (void)registerModuleClass:(Class)moduleClass;
/// 测试隔离：移除全部模块实例并复位加载标志，保留段扫描得到的模块类清单，
/// 之后可再次 loadModules 重新实例化（刻意不清类清单 —— 段扫描幂等，清掉不可恢复）
+ (void)reset;
/// 导出已加载模块名（调试用）
+ (NSArray<NSString *> *)exportedModuleNames;

/// 供 MLRouter.loadAllIsolatedRoutes 扫描 MLModuleSect 时回填（内部使用）
+ (void)_registerModuleClassName:(NSString *)className;

@end

NS_ASSUME_NONNULL_END
