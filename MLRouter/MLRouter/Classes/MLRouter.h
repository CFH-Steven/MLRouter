// MLRouter.h
#import <Foundation/Foundation.h>
#import "MLRouterRequest.h"
#import "MLRouterInterceptor.h"

typedef MLRouterRequest * _Nonnull (^MLRouterBuildBlock)(NSString * _Nonnull urlStr);

@interface MLRouter : NSObject

// 允许局部变量实例直接点出第一发 .build 节点
@property (nonatomic, readonly, copy) MLRouterBuildBlock _Nonnull build;

/**
 核心中枢执行器（供 MLRouterRequest 内部在 .open() 触发时最终回调）
 */
- (id _Nullable)executeRequest:(MLRouterRequest * _Nonnull)request;

+ (MLRouter * _Nonnull)create;

/**
 🔒【初始化时序契约】显式确保「Mach-O 段扫描 + 静态路由表构建」已经完成（幂等，可重复调用）。

 段扫描原先只挂在 +initialize 里，而 +initialize 是**懒触发**的 —— 只有当 MLRouter
 第一次收到消息时才执行。于是出现如下致命时序错位：

     AppDelegate.didFinishLaunching
       → [MLRouterModuleManager loadModules]   // ← 此时 MLRouter 尚未收到过任何消息
                                               //   g_mlModuleClasses 还是空数组
                                               //   → 0 个模块被初始化，且 g_mlModulesLoaded 被置为 YES
       → MLRouter.create.build(...).open()      // ← 到这里才触发 MLRouter +initialize 扫描
                                               //   模块类终于被发现，但 loadModules 已不会再跑

 后果：moduleSetup / moduleInit / App 生命周期转发全部静默失效，模块自举注册的动态路由
 全部缺失（表现为「合法 URL 却走 404 兜底」）。

 因此：任何「依赖静态路由表 / 服务表 / 模块表已就绪」的代码（框架内部的模块管理器、
 宿主调试入口、CI 自检）都必须先显式调用本方法，不能依赖 +initialize 的触发时机。
 */
+ (void)ensureRoutesLoaded;

// ============================================================================
// 🔒 治理层 API（组件化补齐能力）
// ============================================================================

/// 动态路由：运行时 / 远程下发注册（优先级低于编译期静态段，高于 404 兜底）。
/// handler 返回 UIViewController 会被自动 present；返回其他对象作为方法路由结果回传。
+ (void)registerRoute:(NSString * _Nonnull)urlPattern
              handler:(id _Nullable (^_Nonnull)(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request))handler;
/// 反注册动态路由
+ (void)unregisterRoute:(NSString * _Nonnull)urlPattern;

/// 安全白名单：只允许指定 scheme（如 @[@"app"]）通过，其余直接降级
+ (void)setAllowedSchemes:(NSSet<NSString *> * _Nullable)schemes;
/// 安全白名单：只允许精确或前缀匹配的 path 通过（如 @[@"app://safe/"]）
+ (void)setAllowedURLPaths:(NSSet<NSString *> * _Nullable)paths;
/// 自定义校验器：返回 NO 直接降级（最高优先级，覆盖上述两者）
+ (void)setRouteValidator:(BOOL (^_Nullable)(NSURL * _Nonnull url))validator;

/// 降级兜底：路由未命中或被拦截时回调，返回的 UIViewController 会被自动 present
+ (void)setFallbackHandler:(id _Nullable (^_Nullable)(MLRouterRequest * _Nonnull request, NSError * _Nullable error))handler;
/// 降级兜底（便捷版）：统一跳转到指定错误页 VC
+ (void)setFallbackViewControllerClass:(Class _Nullable)cls;

/// 测试隔离：清空动态路由 + 白名单 + 校验器 + 兜底（编译期静态段无法清除，需配合 MLRouterService/Module reset）
/// ⚠️ 注意副作用：模块自举注册的动态路由也会被一并清空（模块动态路由与手动动态路由同表）。
/// 需要恢复时：先 [MLRouterModuleManager reset]，再 [MLRouterModuleManager loadModules]。
+ (void)resetRouter;

/// 测试隔离（细粒度）：只清空白名单 / 校验器 / 兜底治理配置，**保留动态路由**。
/// 场景测试改完 scheme/path 白名单或 validator 后应调用它收尾，避免误伤模块自举注册的动态路由。
+ (void)resetGovernance;

/// 路由表导出（CI / 调试用）：合并静态段 + 动态路由 + 服务 + 模块
+ (NSDictionary * _Nonnull)exportRouteTable;

/// 🔒 敏感参数脱敏：诊断日志（404 灾难级警报等）打印 URL 时，指定 query key 的值替换为
/// `REDACTED`。URL 天然会携带 token / 手机号 / 订单号进日志，这是合规雷区。
/// 默认键集：token / access_token / password / pwd / passwd / phone / mobile / idcard / secret。
/// 传入自定义键集会**整体替换**默认集；传 nil 恢复默认集；传空集关闭脱敏。
/// 匹配对大小写不敏感。只影响日志输出，不影响路由执行与参数传递。
+ (void)setRedactedQueryKeys:(NSSet<NSString *> * _Nullable)keys;

/// 返回 urlStr 的脱敏版本（按当前脱敏键集）：诊断日志 / 业务自建日志统一用这一个入口。
/// 无 query、或 query 中不含敏感键时原样返回。
+ (NSString * _Nonnull)redactedURLString:(NSString * _Nonnull)urlStr;
@end

// UIViewController 分类：底层自注册自愈映射后，将全量混合参数完整留底备份在此字典中
@interface UIViewController (MLRouter)
@property (nonatomic, strong) NSDictionary * _Nullable ml_routerParams;
@end

// 🔥【大厂看家招式：去单例全局内联魔法起点】
// 没有任何普通类方法的压栈函数消耗，每次调用瞬间创建一个轻量执行器，用完即被内存自动销毁。
NS_INLINE MLRouter * _Nonnull MLRouterInstance(void) {
    return [[MLRouter alloc] init];
}
