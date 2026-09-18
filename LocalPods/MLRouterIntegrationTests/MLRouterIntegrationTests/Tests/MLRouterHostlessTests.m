// MLRouterHostlessTests.m
// 扩展进程 / 无宿主 UI 环境维度（测试体系第 10 维）：
// App Extension 进程里 [UIApplication sharedApplication] 无 keyWindow（UI 层级不存在）。
// 框架在此环境下的生存契约：
//   ① 非 UI 路由（方法路由）**零 UIApplication 依赖** —— extension 里可放心用；
//   ② 页面路由在无 keyWindow 时**可诊断 + completion(nil)** —— 绝不静默 no-op，
//      也绝不把未上屏的 VC 冒充「结果对象」从 completion 通道发出去（双通道契约）。
// 模拟方式：swizzle。keyWindow 置 nil 即扩展进程的准确特征（sharedApplication
// 在扩展进程运行时其实存在，缺的是 window 层级）；sharedApplication 计数探针
// 用来钉「非 UI 路由不碰 UIApplication」的依赖边界。
#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "MLRouterTestSupport.h"

static NSInteger g_mltSharedAppCalls;
// 🔒 swizzle 状态标志：手动恢复 + teardown 兜底可能**双重调用**，
// method_exchangeImplementations 是对称交换 —— 换两次等于换回去（状态反转）。
// 必须用标志位做幂等，否则前序测试的恢复会把后序测试的探针「反向安装」。
static BOOL g_mltSharedAppSwizzled = NO;
static BOOL g_mltKeyWindowSwizzled = NO;

// 永不注册的占位协议：hasServiceForProtocol 纯读查询用（零副作用）
@protocol HostlessNeverRegisteredService <NSObject>
@end

@implementation UIApplication (MLTHostlessProbe)
// 交换后：外部调 sharedApplication → 进本方法（计数）；
// 本方法内调 mlt_sharedApplication → 实际执行原 sharedApplication 实现。
+ (UIApplication *)mlt_sharedApplication {
    g_mltSharedAppCalls++;
    return [UIApplication mlt_sharedApplication];
}
// 交换后：外部调 keyWindow → 恒 nil（模拟扩展进程无 window 层级）
- (UIWindow *)mlt_keyWindow {
    return nil;
}
@end

@interface MLRouterHostlessTests : XCTestCase
@end

@implementation MLRouterHostlessTests

- (void)setUp {
    [super setUp];
    [TestCapture reset];
    [MLRouter resetRouter]; // 清动态路由 + 白名单 + 校验器 + 兜底
}

// swizzle 计数探针：返回「解除探针」的 block（幂等，可安全手动调用 + teardown 兜底）
- (void (^)(void))installSharedAppCountingProbe {
    g_mltSharedAppCalls = 0;
    if (!g_mltSharedAppSwizzled) {
        Method orig = class_getClassMethod([UIApplication class], @selector(sharedApplication));
        Method mine = class_getClassMethod([UIApplication class], @selector(mlt_sharedApplication));
        method_exchangeImplementations(orig, mine);
        g_mltSharedAppSwizzled = YES;
    }
    return ^{
        if (g_mltSharedAppSwizzled) {
            Method orig = class_getClassMethod([UIApplication class], @selector(sharedApplication));
            Method mine = class_getClassMethod([UIApplication class], @selector(mlt_sharedApplication));
            method_exchangeImplementations(orig, mine);
            g_mltSharedAppSwizzled = NO;
        }
    };
}

// keyWindow 置 nil 探针：返回「解除探针」的 block（幂等，可安全手动调用 + teardown 兜底）
- (void (^)(void))installNilKeyWindowProbe {
    if (!g_mltKeyWindowSwizzled) {
        Method orig = class_getInstanceMethod([UIApplication class], @selector(keyWindow));
        Method mine = class_getInstanceMethod([UIApplication class], @selector(mlt_keyWindow));
        method_exchangeImplementations(orig, mine);
        g_mltKeyWindowSwizzled = YES;
    }
    return ^{
        if (g_mltKeyWindowSwizzled) {
            Method orig = class_getInstanceMethod([UIApplication class], @selector(keyWindow));
            Method mine = class_getInstanceMethod([UIApplication class], @selector(mlt_keyWindow));
            method_exchangeImplementations(mine, orig);
            g_mltKeyWindowSwizzled = NO;
        }
    };
}

#pragma mark - 1. 依赖边界：非 UI 路由零 UIApplication 依赖

/// 扩展进程生存前提：方法路由全程不碰 UIApplication。
/// 若框架内部有任何「顺手拿 sharedApplication」的代码，extension 里就是未定义行为。
- (void)testMethodRouteDoesNotTouchUIApplication {
    void (^removeProbe)(void) = [self installSharedAppCountingProbe];
    [self addTeardownBlock:removeProbe];   // 双保险：断言之外也必须恢复

    NSInteger before = g_mltSharedAppCalls;
    id ret = MLRouter.create.build(@"mltest://method/add?a=1&b=2").open();
    NSInteger after = g_mltSharedAppCalls;

    XCTAssertEqualObjects(ret, @3, @"方法路由结果不受探针影响");
    XCTAssertEqual(after - before, 0, @"方法路由全程不得触碰 UIApplication.sharedApplication（实测 %ld 次）",
                   (long)(after - before));

    // 服务发现 / 路由表导出（extension 常用能力）同样必须是纯运行时操作
    before = g_mltSharedAppCalls;
    (void)[MLRouter exportRouteTable];
    XCTAssertFalse([MLRouterService hasServiceForProtocol:@protocol(HostlessNeverRegisteredService)],
                   @"未注册协议查询应返回 NO（顺带确认查询可达）");
    after = g_mltSharedAppCalls;
    XCTAssertEqual(after - before, 0, @"导出表 / 服务发现同样不得触碰 UIApplication");
}

#pragma mark - 2. 无 keyWindow 的页面路由：可诊断 + completion(nil)，绝不静默

/// 核心契约钉子（修复的静默失效点）：旧实现 keyWindow 为 nil 时把 present 发给 nil
/// 静默 no-op，却仍把**从未上屏的 VC** 通过 completion 当「结果对象」发出去。
/// 现在必须：completion(nil)（拿不到 VC = 没上屏）+ 诊断日志（PII 脱敏、含归因 URL）。
- (void)testPageRouteWithoutKeyWindowCompletesWithNilAndDiagnosable {
    // stderr 捕获要覆盖 present block 的执行窗口（主队列异步，在 wait 期间跑）
    int savedErr = dup(STDERR_FILENO);
    int pipeFD[2];
    XCTAssertEqual(pipe(pipeFD), 0, @"创建捕获管道失败");
    dup2(pipeFD[1], STDERR_FILENO);

    void (^removeKeyProbe)(void) = [self installNilKeyWindowProbe];
    [self addTeardownBlock:removeKeyProbe];
    XCTAssertNil([UIApplication sharedApplication].keyWindow, @"探针状态自检：安装后 keyWindow 必须为 nil（若失败 = swizzle 状态被污染）");

    __block id completionResult = @"sentinel";
    XCTestExpectation *exp = [self expectationWithDescription:@"page-route-nil-window"];
    // URL 带 token：顺带钉诊断日志的 PII 脱敏
    id ret = MLRouter.create.build(@"mltest://page/basic?token=raw-secret-value")
        .withCompletion(^(id result) {
            completionResult = result;
            removeKeyProbe();   // 拿到结果立刻恢复 keyWindow，别让 nil 环境污染 wait 期间的其它主队列任务
            [exp fulfill];
        }).open();
    XCTAssertEqualObjects(ret, @(YES), @"open() 受理信号语义不变：路由命中并已受理");
    [self waitForExpectationsWithTimeout:5 handler:nil];

    // 恢复 stderr 后再读管道
    dup2(savedErr, STDERR_FILENO);
    close(savedErr);
    close(pipeFD[1]);
    NSMutableString *captured = [NSMutableString string];
    char buf[1024];
    ssize_t n;
    while ((n = read(pipeFD[0], buf, sizeof(buf))) > 0) {
        NSString *chunk = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding];
        if (chunk) [captured appendString:chunk];
        if (captured.length > 64 * 1024) break;
    }
    close(pipeFD[0]);

    XCTAssertNil(completionResult, @"无 keyWindow 时 completion 必须传 nil —— 绝不能把未上屏的 VC 冒充结果对象");
    XCTAssertTrue([captured containsString:@"无 keyWindow"], @"应有可归因诊断日志（长度 %lu）：\n%@",
                  (unsigned long)captured.length, captured);
    XCTAssertTrue([captured containsString:@"REDACTED"], @"诊断日志应脱敏 token：\n%@", captured);
    XCTAssertFalse([captured containsString:@"raw-secret-value"], @"诊断日志绝不能出现原始 token 值：\n%@", captured);
}

#pragma mark - 3. 兜底 VC 路径在同一环境下同样受保护

/// 兜底 VC（handler 返回 VC / setFallbackViewControllerClass）与页面路由共用
/// _presentViewController 入口 —— 无 keyWindow 时必须走同一套「completion(nil) + 诊断」。
- (void)testFallbackPageWithoutKeyWindowCompletesWithNil {
    void (^removeKeyProbe)(void) = [self installNilKeyWindowProbe];
    [self addTeardownBlock:removeKeyProbe];
    XCTAssertNil([UIApplication sharedApplication].keyWindow, @"探针状态自检：安装后 keyWindow 必须为 nil（若失败 = swizzle 状态被污染）");

    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
        return [[TestRouteViewController alloc] init];   // 兜底返回 VC → 自动 present 路径
    }];

    __block id completionResult = @"sentinel";
    XCTestExpectation *exp = [self expectationWithDescription:@"fallback-nil-window"];
    id ret = MLRouter.create.build(@"mltest://no/such/route")
        .withCompletion(^(id result) {
            completionResult = result;
            removeKeyProbe();
            [exp fulfill];
        }).open();
    XCTAssertEqualObjects(ret, @(YES), @"兜底 VC 的受理信号契约不变");
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertNil(completionResult, @"无 keyWindow 时兜底 VC 同样不得冒充结果对象，completion 应为 nil");
}

@end
