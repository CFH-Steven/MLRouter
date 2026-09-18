// MLRouterTestSupport.h
// 测试公共支撑：TestCapture 跨回调取值、测试协议/服务类、页面 VC、拦截器、模块类。
// 其中【页面/方法/重定向/拦截器】无运行时注册 API，必须靠编译期段宏注册，因此写在本文件。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <MLRouter/MLRouterHeader.h>
#import <MLRouter/MLRouterService.h>
#import <MLRouter/MLRouterModule.h>

NS_ASSUME_NONNULL_BEGIN

/**
 测试取值中转站：框架很多结果是异步/在被调对象内部产生的（如 VC 参数映射、拦截器顺序、
 兜底 VC 实例、异步 completion），用单例静态变量把结果透出来给断言。
 */
@interface TestCapture : NSObject
+ (void)reset;

+ (id)lastVC;
+ (void)setLastVC:(id)vc;

+ (NSDictionary *)lastParams;
+ (void)setLastParams:(NSDictionary *)p;

+ (NSMutableArray<NSString *> *)orderLog;          // 拦截器执行顺序
+ (void)appendOrder:(NSString *)name;

+ (id)blockResult;                                 // 异步/同步 completion 结果
+ (void)setBlockResult:(id)r;

+ (BOOL)fallbackCalled;
+ (void)setFallbackCalled:(BOOL)b;

+ (NSMutableArray<NSString *> *)moduleSetupLog;
+ (void)appendModuleSetup:(NSString *)name;
+ (NSMutableArray<NSString *> *)moduleInitLog;
+ (void)appendModuleInit:(NSString *)name;
+ (NSMutableArray<NSString *> *)moduleLifecycleLog;
+ (void)appendModuleLifecycle:(NSString *)name;
/// 统一阶段日志（"setup:ModX" / "init:ModX"），用于验证「先跑完所有 setup 再统一 init」的全局顺序
+ (NSMutableArray<NSString *> *)modulePhaseLog;
+ (void)appendModulePhase:(NSString *)phase;
@end

/// 方法路由示例服务（类方法，省去实例化）
@interface TestMathService : NSObject
+ (NSNumber *)addWithParams:(NSDictionary *)params;
+ (void)asyncAddWithParams:(NSDictionary *)params completion:(void(^)(id))completion;
/// 返回对象，但选择器名**不属于** ARC 保留家族（不以 alloc/new/copy/mutableCopy/init 开头）
/// ⇒ ARC 编译后返回的是 +0（已自动释放）。这是方法路由最常见的情形，也是 P0 崩溃的现场。
+ (id)makeObjectWithParams:(NSDictionary *)params;
/// 返回对象，且选择器名**属于** `new` 家族 ⇒ 返回 +1（所有权随返回值转移）。
/// 与上一条成对，锁住「框架必须按 ARC 方法家族区分 +1 / +0」这条契约。
+ (id)newBoxedObjectWithParams:(NSDictionary *)params;
+ (NSString *)redirectedResult:(NSDictionary *)params; // 重定向链终点
+ (NSString *)echoParamsWithParams:(NSDictionary *)params; // 回显指定 key，用于验证重定向保留 query
+ (id)noArgMethod;                                  // 无参数（numberOfArguments<3），验证签名校验拒绝
@end

@interface TestRouteViewController : UIViewController
@end

/// 用于验证参数映射：框架会把 params 中 key 匹配的 VC 属性赋值，并把全量 params 写入 ml_routerParams
@interface TestParamViewController : UIViewController
@property (nonatomic, copy) NSString *name;
@end

/// 类型化属性 VC：验证 _safelyMapParameters 的 4 条类型分支
/// （T@ 对象直接赋值、Ti/Tq/TI/TQ 整型、TB/Tc 布尔、Tf/Td 浮点）
@interface TestTypedViewController : UIViewController
@property (nonatomic, assign) NSInteger count;
@property (nonatomic, assign) double ratio;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy) NSString *name;
@end

/// 记录转场调用的自定义导航控制器：把 push / present 的次数与 animated 实参透出来，
/// 用于验证 withTransitionStyle（push vs present 分支）与 withAnimation（animated 透传）。
@interface TestRecordingNavController : UINavigationController
+ (void)resetRecord;
+ (NSUInteger)pushCount;
+ (BOOL)lastPushAnimated;
+ (NSUInteger)presentCount;
+ (BOOL)lastPresentAnimated;
@end

/// View 路由目标视图（验证 View 路由 + 参数映射 + 未知参数容错）
@interface TestBadgeView : UIView
@property (nonatomic, copy) NSString *badgeText;
@end

#pragma mark - 参数类型全覆盖（对应 _safelyMapParameters: 的每一条类型码分支）

/// 全类型属性 VC：**逐一**覆盖 `property_getAttributes` 会返回的每一个标量类型码。
///
/// 旧实现只处理了 Ti / Tq / TI / TQ + TB / Tc + Tf / Td，
/// **漏掉 short(`Ts`) / unsigned short(`TS`) / unsigned char(`TC`)** ——
/// 这三种属性的表现是「路由命中、页面打开、参数就是不生效」，又一处静默失效。
/// 另含两个「必须被安全跳过」的类型：结构体（`T{CGRect=...}`）与 block（`T@?`）。
@interface TestAllTypesViewController : UIViewController
@property (nonatomic, copy) NSString *objVal;                    // T@
@property (nonatomic, assign) NSInteger integerVal;              // Tq（64 位下 NSInteger = long）
@property (nonatomic, assign) long long longLongVal;             // Tq
@property (nonatomic, assign) unsigned long long uLongLongVal;   // TQ
@property (nonatomic, assign) int intVal;                        // Ti
@property (nonatomic, assign) unsigned int uIntVal;              // TI
@property (nonatomic, assign) short shortVal;                    // Ts ← 旧实现漏
@property (nonatomic, assign) unsigned short uShortVal;           // TS ← 旧实现漏
@property (nonatomic, assign) char charVal;                      // Tc
@property (nonatomic, assign) unsigned char uCharVal;            // TC ← 旧实现漏
@property (nonatomic, assign) BOOL boolVal;                      // TB
@property (nonatomic, assign) float floatVal;                    // Tf
@property (nonatomic, assign) double doubleVal;                  // Td
@property (nonatomic, assign) CGRect rectVal;                    // T{CGRect=...} 结构体：必须安全跳过
/// block 属性（编码 `T@?`）：必须被拦下，绝不能把 URL 字符串当成 block 写进去
@property (nonatomic, copy) void (^callback)(void);
@end

#pragma mark - 异常穿透（框架内零 @try/@catch，必须把行为钉成显式契约）

/// 方法路由目标：handler 内部抛 NSException。
/// 框架不做异常隔离 ⇒ 异常同步穿透给调用方。这是**有意保留**的语义（吞掉异常会掩盖业务 bug），
/// 但必须被测出来、写进契约 —— 否则「路由一崩整 App 就崩」这件事没有任何人知道。
@interface TestThrowService : NSObject
+ (id)throwingWithParams:(NSDictionary *)params;
@end

/// init 抛异常的页面：验证页面路由在「VC 构造失败」时的实际行为。
/// 注意：主线程调用时异常可被调用方 catch；**子线程调用时框架会 dispatch 到主队列，
/// 异常将在主队列抛出，调用方完全无法防御**（这是真实风险，见 README）。
@interface TestThrowingInitViewController : UIViewController
@end

/// 异步放行拦截器（优先级 60）：URL 含 "asyncchain" 时延迟放行（模拟异步鉴权），其余同步放行。
/// 不写 orderLog，避免污染拦截器顺序断言。
@interface TestAsyncPassInterceptor : NSObject <MLRouterInterceptor>
@end

#pragma mark - 拦截器（全局生效，编译期段注册）

/// 顺序拦截器 A：优先级 10，默认放行并记录
@interface TestOrderInterceptor : NSObject <MLRouterInterceptor>
@end

/// 顺序拦截器 B：优先级 30，默认放行并记录（应晚于 A 执行）
@interface TestOrderInterceptorB : NSObject <MLRouterInterceptor>
@end

/// 阻断拦截器：优先级 5（最先），URL 含 "blocked" 时 reject，否则放行
@interface TestBlockingInterceptor : NSObject <MLRouterInterceptor>
@end

/// 鉴权拦截器：优先级 20，URL 含 "secure" 时要求 token=secret-token（模拟敏感页鉴权切面）；
/// 缺失 / 错误 token 一律 reject（domain MLRouterTest / code 403），合法 token 放行。
/// 用于验证「外部入口防线」：鉴权失败不得触达任何路由目标（页面 / 方法 / 动态 handler）。
@interface TestAuthInterceptor : NSObject <MLRouterInterceptor>
@end

/// 参数注入拦截器（优先级 70）：URL 含 "enrich" 时向下游注入 params[@"b"] = @100，
/// 验证拦截器可在职责链中补公共参数。不写 orderLog，避免污染顺序断言。
@interface TestEnrichInterceptor : NSObject <MLRouterInterceptor>
@end

/// 抛异常拦截器（优先级 80）：**仅**当 URL 含 "throwintercept" 时抛 NSException，其余一律放行。
/// 之所以要加 URL 条件，是因为拦截器是全局生效的 —— 无条件抛会污染其他所有用例。
/// 用于验证「拦截器内部异常是否会穿透、以及异常后路由器是否还能正常工作（不死锁）」。
@interface TestThrowingInterceptor : NSObject <MLRouterInterceptor>
@end

#pragma mark - 模块（测试内用 runtime registerModuleClass，不在此段注册）

NS_ASSUME_NONNULL_END
