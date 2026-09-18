// MLRouterService.h
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 协议驱动的服务发现层（组件化核心能力之一）。

 痛点：组件间若直接 import 彼此实现类，会形成硬依赖、无法独立编译/测试。
 解法：组件只依赖「协议头」，实现方用 MLRouterService(Protocol, Impl) 自注册，
       调用方用 [MLRouterService serviceForProtocol:XxxService] 拿到强类型实例。

 注册数据在编译期写入 Mach-O 段（MLServiceSect），由 MLRouter.ensureRoutesLoaded 统一扫描回填，
 因此零配置、多仓/二进制私有仓零接入成本（与页面/方法路由同源机制）。

 🔒 两张表模型（保证测试隔离不误伤组件）：
   - 静态表：编译期段扫描回填，是「应用里真实存在哪些服务」的事实，reset 不会清它；
   - 运行时表：registerService: 写入，优先级高于静态表，reset 只清它。
   被显式 unregisterService: 的协议记账进 tombstone，屏蔽静态表条目；reset 时一并清空即恢复。
   这样 [MLRouterService reset] 才能真正做到「只回滚测试自己造成的变化」，
   而不是把整个 App 的服务发现能力一次性清空且无法恢复（段扫描是幂等的，清掉就再也回填不回来）。
 */
@interface MLRouterService : NSObject

/// 类型安全地获取协议对应的服务实现实例（每次返回新实例，调用方自行管理生命周期）
+ (id _Nullable)serviceForProtocol:(Protocol * _Nonnull)protocol;
/// 是否存在该协议的服务实现
+ (BOOL)hasServiceForProtocol:(Protocol * _Nonnull)protocol;
/// 运行时注册（远程下发 / 测试 mock 用），优先级高于编译期段注册
+ (void)registerService:(Protocol * _Nonnull)protocol implClass:(Class _Nonnull)implClass;
/// 移除服务发现（对编译期段注册的协议会打 tombstone 屏蔽，reset 后恢复）
+ (void)unregisterService:(Protocol * _Nonnull)protocol;
/// 导出全部已注册服务协议名（静态段 ∪ 运行时 − tombstone，CI / 调试用）
+ (NSArray<NSString *> * _Nonnull)exportedServiceProtocols;
/// 测试隔离：只清空运行时注册与 tombstone，编译期段注册的服务保持不变
+ (void)reset;

/// 供 MLRouter.loadAllIsolatedRoutes 扫描 MLServiceSect 时回填（内部使用）
+ (void)_registerServiceProtocolName:(NSString *)protocolName implClassName:(NSString *)implClassName;

@end

NS_ASSUME_NONNULL_END
