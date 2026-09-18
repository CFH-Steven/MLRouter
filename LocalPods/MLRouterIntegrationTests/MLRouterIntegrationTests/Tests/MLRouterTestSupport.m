// MLRouterTestSupport.m
#import "MLRouterTestSupport.h"

#pragma mark - TestCapture

static id gLastVC = nil;
static NSDictionary *gLastParams = nil;
static NSMutableArray<NSString *> *gOrderLog = nil;
static id gBlockResult = nil;
static BOOL gFallbackCalled = NO;
static NSMutableArray<NSString *> *gModuleSetupLog = nil;
static NSMutableArray<NSString *> *gModuleInitLog = nil;
static NSMutableArray<NSString *> *gModuleLifecycleLog = nil;
static NSMutableArray<NSString *> *gModulePhaseLog = nil;

// 🔒【线程安全】拦截器是**并发**执行路径：testConcurrentOpenCallsAreSafeAndCorrect 会 24 路并发
// 跑同一条方法路由，链上的 TestOrderInterceptor / TestOrderInterceptorB 会同时往 orderLog 写。
// 不加锁就是多线程并发 NSMutableArray addObject: —— 堆结构被写坏，症状是
// `-[__NSArrayM insertObject:atIndex:]` 里 malloc_report 后 SIGABRT，崩在哪一条用例上完全随机。
// 框架侧对拦截器的契约是「拦截器应无状态，共享状态请自行加锁」，所以这里必须自己上锁。
// 用递归锁：getter 在被持锁的代码路径内被调用时不会自锁死。
static NSRecursiveLock *gCaptureLock = nil;

@implementation TestCapture

+ (void)initialize {
    if (self == [TestCapture class]) {
        gCaptureLock = [[NSRecursiveLock alloc] init];
        gOrderLog = [NSMutableArray array];
        gModuleSetupLog = [NSMutableArray array];
        gModuleInitLog = [NSMutableArray array];
        gModuleLifecycleLog = [NSMutableArray array];
        gModulePhaseLog = [NSMutableArray array];
    }
}

+ (void)reset {
    [gCaptureLock lock];
    gLastVC = nil;
    gLastParams = nil;
    [gOrderLog removeAllObjects];
    gBlockResult = nil;
    gFallbackCalled = NO;
    [gModuleSetupLog removeAllObjects];
    [gModuleInitLog removeAllObjects];
    [gModuleLifecycleLog removeAllObjects];
    [gModulePhaseLog removeAllObjects];
    [gCaptureLock unlock];
}

+ (id)lastVC { [gCaptureLock lock]; id v = gLastVC; [gCaptureLock unlock]; return v; }
+ (void)setLastVC:(id)vc { [gCaptureLock lock]; gLastVC = vc; [gCaptureLock unlock]; }
+ (NSDictionary *)lastParams { [gCaptureLock lock]; NSDictionary *v = gLastParams; [gCaptureLock unlock]; return v; }
+ (void)setLastParams:(NSDictionary *)p { [gCaptureLock lock]; gLastParams = p; [gCaptureLock unlock]; }

// getter 一律返回快照：调用方拿到的是稳定副本，不会在遍历途中被并发写入改变。
+ (NSMutableArray<NSString *> *)orderLog {
    [gCaptureLock lock];
    NSMutableArray *snapshot = [gOrderLog mutableCopy];
    [gCaptureLock unlock];
    return snapshot;
}
+ (void)appendOrder:(NSString *)name {
    if (!name) return;
    [gCaptureLock lock];
    [gOrderLog addObject:name];
    [gCaptureLock unlock];
}

+ (id)blockResult { [gCaptureLock lock]; id v = gBlockResult; [gCaptureLock unlock]; return v; }
+ (void)setBlockResult:(id)r { [gCaptureLock lock]; gBlockResult = r; [gCaptureLock unlock]; }

+ (BOOL)fallbackCalled { [gCaptureLock lock]; BOOL v = gFallbackCalled; [gCaptureLock unlock]; return v; }
+ (void)setFallbackCalled:(BOOL)b { [gCaptureLock lock]; gFallbackCalled = b; [gCaptureLock unlock]; }

+ (NSMutableArray<NSString *> *)moduleSetupLog {
    [gCaptureLock lock]; NSMutableArray *s = [gModuleSetupLog mutableCopy]; [gCaptureLock unlock]; return s;
}
+ (void)appendModuleSetup:(NSString *)name {
    if (!name) return;
    [gCaptureLock lock]; [gModuleSetupLog addObject:name]; [gCaptureLock unlock];
}
+ (NSMutableArray<NSString *> *)moduleInitLog {
    [gCaptureLock lock]; NSMutableArray *s = [gModuleInitLog mutableCopy]; [gCaptureLock unlock]; return s;
}
+ (void)appendModuleInit:(NSString *)name {
    if (!name) return;
    [gCaptureLock lock]; [gModuleInitLog addObject:name]; [gCaptureLock unlock];
}
+ (NSMutableArray<NSString *> *)moduleLifecycleLog {
    [gCaptureLock lock]; NSMutableArray *s = [gModuleLifecycleLog mutableCopy]; [gCaptureLock unlock]; return s;
}
+ (void)appendModuleLifecycle:(NSString *)name {
    if (!name) return;
    [gCaptureLock lock]; [gModuleLifecycleLog addObject:name]; [gCaptureLock unlock];
}
+ (NSMutableArray<NSString *> *)modulePhaseLog {
    [gCaptureLock lock]; NSMutableArray *s = [gModulePhaseLog mutableCopy]; [gCaptureLock unlock]; return s;
}
+ (void)appendModulePhase:(NSString *)phase {
    if (!phase) return;
    [gCaptureLock lock]; [gModulePhaseLog addObject:phase]; [gCaptureLock unlock];
}

@end

#pragma mark - TestMathService

@implementation TestMathService

+ (NSNumber *)addWithParams:(NSDictionary *)params {
    return @([params[@"a"] integerValue] + [params[@"b"] integerValue]);
}

+ (void)asyncAddWithParams:(NSDictionary *)params completion:(void(^)(id))completion {
    if (completion) completion(@([params[@"a"] integerValue] + [params[@"b"] integerValue]));
}

+ (id)makeObjectWithParams:(NSDictionary *)params {
    // ⚠️ 注意：本方法名不在 ARC 保留家族里（不是 alloc/new/copy/mutableCopy/init 开头），
    // 因此 ARC 会在方法返回前对该对象执行 objc_autoreleaseReturnValue —— 返回给调用方的
    // 是 **+0（已自动释放）** 的对象，而不是 +1。框架若一律按 +1 用 __bridge_transfer 接管，
    // 就会在 autorelease pool 排空时对已释放对象二次 release 而崩溃。
    return [NSObject new];
}

+ (id)newBoxedObjectWithParams:(NSDictionary *)params {
    // 方法名以 "new" 开头 ⇒ ARC 保留家族 ⇒ 返回 **+1**，所有权随返回值转移给调用方。
    // 框架此时必须用 __bridge_transfer 接管，若当成 +0 处理则会泄漏。
    return (id)[NSObject new];
}

+ (NSString *)redirectedResult:(NSDictionary *)params {
    return @"redirected";
}

+ (NSString *)echoParamsWithParams:(NSDictionary *)params {
    return params[@"echo"] ?: @"no-echo";
}

+ (id)noArgMethod {
    return @"should-be-rejected-by-signature-check";
}

@end

#pragma mark - 页面 VC

@implementation TestRouteViewController
@end

@implementation TestParamViewController

- (void)setMl_routerParams:(NSDictionary *)params {
    objc_setAssociatedObject(self, @selector(ml_routerParams), params, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [TestCapture setLastVC:self];
    [TestCapture setLastParams:params];
}

- (NSDictionary *)ml_routerParams {
    return objc_getAssociatedObject(self, @selector(ml_routerParams));
}

@end

#pragma mark - 类型化属性 VC

@implementation TestTypedViewController

- (void)setMl_routerParams:(NSDictionary *)params {
    objc_setAssociatedObject(self, @selector(ml_routerParams), params, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [TestCapture setLastVC:self];
    [TestCapture setLastParams:params];
}

- (NSDictionary *)ml_routerParams {
    return objc_getAssociatedObject(self, @selector(ml_routerParams));
}

@end

#pragma mark - 记录转场的导航控制器

static NSUInteger gPushCount = 0;
static BOOL gLastPushAnimated = NO;
static NSUInteger gPresentCount = 0;
static BOOL gLastPresentAnimated = NO;

@implementation TestRecordingNavController

+ (void)resetRecord {
    gPushCount = 0;
    gLastPushAnimated = NO;
    gPresentCount = 0;
    gLastPresentAnimated = NO;
}

+ (NSUInteger)pushCount { return gPushCount; }
+ (BOOL)lastPushAnimated { return gLastPushAnimated; }
+ (NSUInteger)presentCount { return gPresentCount; }
+ (BOOL)lastPresentAnimated { return gLastPresentAnimated; }

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    gPushCount++;
    gLastPushAnimated = animated;
    [super pushViewController:viewController animated:animated];
}

- (void)presentViewController:(UIViewController *)viewControllerToPresent
                     animated:(BOOL)flag
                   completion:(void (^)(void))completion {
    gPresentCount++;
    gLastPresentAnimated = flag;
    [super presentViewController:viewControllerToPresent animated:flag completion:completion];
}

@end

#pragma mark - View 路由目标视图

@implementation TestBadgeView
@end

#pragma mark - 参数类型全覆盖

// 注意：这里**不能**写 @dynamic，也不能手写 getter/setter。
// 全部依赖 clang 的 auto-synthesis 生成真实 ivar + setter —— `class_getProperty` 才能查到元数据，
// KVC `setValue:forKey:` 才有落点。一旦写成 @dynamic，KVC 找不到实现会直接抛
// NSUnknownKeyException，反而把「参数映射」变成崩溃源。
@implementation TestAllTypesViewController

// 重写 ml_routerParams 的 setter **只为测试抓取**：框架在「参数映射完成后」才写这个属性，
// 借着这个时机把实例透给 TestCapture，测试才能断言各标量属性的最终值。
// （注意：这里重写的是 UIViewController (MLRouter) 分类里的属性，不影响本类自身 15 个属性的 auto-synthesis。）
- (void)setMl_routerParams:(NSDictionary *)params {
    objc_setAssociatedObject(self, @selector(ml_routerParams), params, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [TestCapture setLastVC:self];
    [TestCapture setLastParams:params];
}

- (NSDictionary *)ml_routerParams {
    return objc_getAssociatedObject(self, @selector(ml_routerParams));
}

@end

#pragma mark - 异常穿透

@implementation TestThrowService

+ (id)throwingWithParams:(NSDictionary *)params {
    // 模拟真实事故：handler 里访问了越界数组 / 强转失败 / 依赖未初始化，抛 NSException。
    // 路由框架不做异常隔离 ⇒ 异常同步穿透到调用方。这是本次要钉成契约的行为。
    @throw [NSException exceptionWithName:@"TestRouteHandlerException"
                                   reason:@"intentional exception thrown inside a route handler"
                                 userInfo:@{@"params": params ?: @{}}];
}

@end

@implementation TestThrowingInitViewController

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
- (instancetype)init {
    // 页面构造阶段就抛异常（真实场景：VC 依赖的配置缺失 / 初始化断言失败）
    @throw [NSException exceptionWithName:@"TestPageInitException"
                                   reason:@"intentional exception thrown from -init"
                                 userInfo:nil];
}
#pragma clang diagnostic pop

@end

#pragma mark - 拦截器（编译期段注册，全局生效）

@implementation TestAsyncPassInterceptor

- (void)processRequest:(MLRouterRequest *)request
                  next:(MLInterceptorNextBlock)next
                reject:(MLInterceptorRejectBlock)reject {
    if ([request.urlStr containsString:@"asyncchain"]) {
        // 模拟异步鉴权：延迟后放行（同步返回值因此不可用，结果经 completion 回传）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ next(request); });
    } else {
        next(request);
    }
}

MLRouterInterceptorClass("TestAsyncPassInterceptor", 60)

@end

@implementation TestOrderInterceptor

- (void)processRequest:(MLRouterRequest *)request
                  next:(MLInterceptorNextBlock)next
                reject:(MLInterceptorRejectBlock)reject {
    [TestCapture appendOrder:@"TestOrderInterceptor"];
    next(request);
}

MLRouterInterceptorClass("TestOrderInterceptor", 10)

@end

@implementation TestOrderInterceptorB

- (void)processRequest:(MLRouterRequest *)request
                  next:(MLInterceptorNextBlock)next
                reject:(MLInterceptorRejectBlock)reject {
    [TestCapture appendOrder:@"TestOrderInterceptorB"];
    next(request);
}

MLRouterInterceptorClass("TestOrderInterceptorB", 30)

@end

@implementation TestBlockingInterceptor

- (void)processRequest:(MLRouterRequest *)request
                  next:(MLInterceptorNextBlock)next
                reject:(MLInterceptorRejectBlock)reject {
    if ([request.urlStr containsString:@"blocked"]) {
        reject([NSError errorWithDomain:@"MLRouterTest" code:403 userInfo:nil]);
    } else {
        next(request);
    }
}

MLRouterInterceptorClass("TestBlockingInterceptor", 5)

@end

@implementation TestAuthInterceptor

- (void)processRequest:(MLRouterRequest *)request
                  next:(MLInterceptorNextBlock)next
                reject:(MLInterceptorRejectBlock)reject {
    // ⚠️ 只对含 "secure" 的 URL 生效：拦截器全局生效，无条件鉴权会污染其他用例。
    // 注意：拦截器阶段拿不到框架解析出的 query params（那发生在拦截链之后），
    // 真实产品的鉴权切面也是从 URL 字符串 / 自有凭据取 token —— 这里保持同一形态。
    if ([request.urlStr containsString:@"secure"]) {
        if ([request.urlStr containsString:@"token=secret-token"]) {
            next(request);
            return;
        }
        reject([NSError errorWithDomain:@"MLRouterTest" code:403
                    userInfo:@{NSLocalizedDescriptionKey: @"auth required: missing or invalid token"}]);
        return;
    }
    next(request);
}

MLRouterInterceptorClass("TestAuthInterceptor", 20)

@end

@implementation TestEnrichInterceptor

- (void)processRequest:(MLRouterRequest *)request
                  next:(MLInterceptorNextBlock)next
                reject:(MLInterceptorRejectBlock)reject {
    if ([request.urlStr containsString:@"enrich"]) {
        request.params[@"b"] = @100; // 注入公共参数，交由下游路由执行时消费
    }
    next(request);
}

MLRouterInterceptorClass("TestEnrichInterceptor", 70)

@end

@implementation TestThrowingInterceptor

- (void)processRequest:(MLRouterRequest *)request
                  next:(MLInterceptorNextBlock)next
                reject:(MLInterceptorRejectBlock)reject {
    // ⚠️ 必须带 URL 条件：拦截器全局生效，无条件抛会污染其他所有用例。
    if ([request.urlStr containsString:@"throwintercept"]) {
        // 模拟真实事故：切面里访问了 nil 容器 / 断言失败 / 依赖服务未就绪
        @throw [NSException exceptionWithName:@"TestInterceptorException"
                                       reason:@"intentional exception thrown inside an interceptor"
                                     userInfo:@{@"url": request.urlStr}];
    }
    next(request);
}

MLRouterInterceptorClass("TestThrowingInterceptor", 80)

@end

#pragma mark - 编译期段注册（页面 / 方法 / 重定向，无运行时注册 API，必须段注册）

MLRouterPageClass("TestRouteViewController", "mltest://page/basic")
MLRouterPageClass("TestParamViewController", "mltest://page/param")
MLRouterPageClass("TestRouteViewController", "mltest://page/wild/*")   // 静态通配符页面
MLRouterPageClass("TestTypedViewController", "mltest://page/typed")    // 类型化属性映射
MLRouterPageClass("TestParamViewController", "mltest://page/greedy/**") // 静态多级贪婪通配符页面
MLRouterPageClass("TestBadgeViewIsNotAVC", "mltest://page/bogus")      // ⚠️ 故意的错误类名（非 UIViewController 且不存在），验证容错
MLRouterPageClass("TestRouteViewController", "mltest://page/dup")      // 重复注册（last-wins 语义验证）
MLRouterPageClass("TestParamViewController", "mltest://page/dup")

MLRouterViewClass("TestBadgeView", "mltest://view/badge")              // View 路由

MLRouterMethodClass("TestMathService", "mltest://method/add", "addWithParams:")
MLRouterMethodClass("TestMathService", "mltest://method/async", "asyncAddWithParams:completion:")
MLRouterMethodClass("TestMathService", "mltest://method/object", "makeObjectWithParams:")
MLRouterMethodClass("TestMathService", "mltest://method/newobject", "newBoxedObjectWithParams:")
MLRouterMethodClass("TestMathService", "mltest://method/noarg", "noArgMethod")
MLRouterMethodClass("TestMathService", "mltest://r3", "redirectedResult:")
MLRouterMethodClass("TestMathService", "mltest://method/echo", "echoParamsWithParams:") // 回显，验证重定向保留 query

MLRouterRedirect("mltest://r1", "mltest://r2")
MLRouterRedirect("mltest://r2", "mltest://r3")
MLRouterRedirect("mltest://redirq", "mltest://method/echo")            // 重定向到方法路由（带 query）
MLRouterRedirect("mltest://cycle1", "mltest://cycle2")                 // ⚠️ 重定向环（验证防环守卫）
MLRouterRedirect("mltest://cycle2", "mltest://cycle1")
MLRouterRedirect("mltest://rmissing", "mltest://no/such/route")        // ⚠️ 重定向目标不存在

#pragma mark - 深重定向链（钉住 16 跳防环上限的边界，以及超限时的静默截断）

// 链结构：over/4 → over/5 → … → over/20 → method/echo，共 **17 跳**。
// 框架的重定向守卫是 `while (redirectGuard++ < 16)` ⇒ 单次 open 最多走 16 跳。
//   · 从 `mltest://over/5` 起 → 恰好 16 跳 → 命中 method/echo ✓
//   · 从 `mltest://over/4` 起 → 需 17 跳 → 第 17 跳被守卫截断在 over/20，静默变成 404 ✗
// 同一个链只靠起始点差一格，就能同时验证「上限内可用」与「超限即静默失效」。
MLRouterRedirect("mltest://over/4",  "mltest://over/5")
MLRouterRedirect("mltest://over/5",  "mltest://over/6")
MLRouterRedirect("mltest://over/6",  "mltest://over/7")
MLRouterRedirect("mltest://over/7",  "mltest://over/8")
MLRouterRedirect("mltest://over/8",  "mltest://over/9")
MLRouterRedirect("mltest://over/9",  "mltest://over/10")
MLRouterRedirect("mltest://over/10", "mltest://over/11")
MLRouterRedirect("mltest://over/11", "mltest://over/12")
MLRouterRedirect("mltest://over/12", "mltest://over/13")
MLRouterRedirect("mltest://over/13", "mltest://over/14")
MLRouterRedirect("mltest://over/14", "mltest://over/15")
MLRouterRedirect("mltest://over/15", "mltest://over/16")
MLRouterRedirect("mltest://over/16", "mltest://over/17")
MLRouterRedirect("mltest://over/17", "mltest://over/18")
MLRouterRedirect("mltest://over/18", "mltest://over/19")
MLRouterRedirect("mltest://over/19", "mltest://over/20")
MLRouterRedirect("mltest://over/20", "mltest://method/echo")

#pragma mark - 类型全覆盖 / 异常穿透 的段注册

MLRouterPageClass("TestAllTypesViewController", "mltest://page/alltypes")
MLRouterPageClass("TestThrowingInitViewController", "mltest://page/throwinginit")
MLRouterMethodClass("TestThrowService", "mltest://method/throw", "throwingWithParams:")
