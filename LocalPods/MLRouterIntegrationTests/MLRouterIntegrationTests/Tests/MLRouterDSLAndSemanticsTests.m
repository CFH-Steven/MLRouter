// MLRouterDSLAndSemanticsTests.m
// 补齐此前遗漏的场景：
// 1) 链式 DSL 全集（withParams / withTransitionStyle / withAnimation 三个节点此前零覆盖）
// 2) 执行优先级与语义（静态段 vs 动态路由、重定向保留 query、白名单校验时机、拦截器 reject 兜底契约）
// 3) 参数映射的类型转换分支（T@ / Tq / Td / Tc 四条编码分支）
// 4) 复杂链路：拦截器注入公共参数 → 下游方法路由消费
#import <XCTest/XCTest.h>
#import "MLRouterTestSupport.h"

@interface MLRouterDSLAndSemanticsTests : XCTestCase
@property (nonatomic, strong) UIWindow *testWindow;
@property (nonatomic, strong) UIWindow *savedWindow;
@end

@implementation MLRouterDSLAndSemanticsTests

- (void)setUp {
    [super setUp];
    [TestCapture reset];
    [MLRouter resetRouter];
    [TestRecordingNavController resetRecord];
    // 用一次性窗口承载转场：页面 push/present 会改动导航栈，不能污染宿主 App 的 keyWindow。
    self.savedWindow = [UIApplication sharedApplication].keyWindow;
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.rootViewController = [[TestRecordingNavController alloc] init];
    w.hidden = NO;
    [w makeKeyAndVisible];
    self.testWindow = w;
}

- (void)tearDown {
    self.testWindow.hidden = YES;
    self.testWindow.rootViewController = nil;
    self.testWindow = nil;
    [self.savedWindow makeKeyAndVisible];
    [MLRouter resetRouter];
    [super tearDown];
}

- (TestRecordingNavController *)navRoot {
    return (TestRecordingNavController *)self.testWindow.rootViewController;
}

#pragma mark - 链式 DSL：withParams（批量注入）

- (void)testWithParamsBulkDictionaryMergesIntoParams {
    id ret = MLRouter.create.build(@"mltest://method/add")
        .withParams(@{@"a": @5, @"b": @6})
        .open();
    XCTAssertEqualObjects(ret, @11, @"withParams 应批量注入全部键值");
}

- (void)testWithParamAfterWithParamsOverridesEarlierValue {
    id ret = MLRouter.create.build(@"mltest://method/add")
        .withParams(@{@"a": @1, @"b": @1})
        .withParam(@"a", @9)
        .open();
    XCTAssertEqualObjects(ret, @10, @"后调用的 withParam 应覆盖 withParams 中的同键值");
}

- (void)testWithParamsNilOrEmptyDictionaryIsSafe {
    NSDictionary *nilDict = nil;
    id ret = MLRouter.create.build(@"mltest://method/add")
        .withParams(nilDict)
        .withParams(@{})
        .withParam(@"a", @2)
        .withParam(@"b", @3)
        .open();
    XCTAssertEqualObjects(ret, @5, @"withParams 传 nil / 空字典应安全跳过，不影响后续链式调用");
}

#pragma mark - 链式 DSL：withParam 守卫与内存语义

- (void)testWithParamNilKeyOrValueIsIgnored {
    NSString *nilKey = nil;
    id nilValue = nil;
    id ret = MLRouter.create.build(@"mltest://method/add")
        .withParam(nilKey, @100)
        .withParam(@"a", nilValue)
        .withParam(@"b", @2)
        .open();
    XCTAssertEqualObjects(ret, @2, @"withParam 的 nil 键/值应被静默忽略且不崩溃");
}

/// 在内部作用域里塞入 block 参数，方法返回后该栈帧已销毁
- (MLRouterRequest *)requestWithBlockParamAddedInInnerScope {
    MLRouterRequest *req = MLRouter.create.build(@"mltest://method/echo");
    {
        NSString *captured = @"inner";
        req.withParam(@"blk", ^NSString *(void) { return captured; });
    }
    return req;
}

- (void)testWithParamCopiesBlockSoItSurvivesOutOfScope {
    MLRouterRequest *req = [self requestWithBlockParamAddedInInnerScope];
    id stored = req.params[@"blk"];
    XCTAssertNotNil(stored, @"block 参数应被存入 params");
    XCTAssertTrue([NSStringFromClass([stored class]) containsString:@"Block"],
                  @"应按类名字符串识别 Block（NSClassFromString(@\"NSBlock\") 恒为 nil）");
    NSString *(^callable)(void) = stored;
    XCTAssertEqualObjects(callable(), @"inner", @"栈 block 被 copy 后仍可安全调用（P1 回归）");
}

- (void)testWithParamStoresNonCopyableObjectAsIs {
    id plain = [NSObject new]; // NSObject 未实现 copyWithZone:
    MLRouterRequest *req = MLRouter.create.build(@"mltest://method/echo").withParam(@"obj", plain);
    XCTAssertEqual(req.params[@"obj"], plain, @"不可 copy 的对象应原样存入，不崩溃也不丢引用");
}

#pragma mark - 链式 DSL：withTransitionStyle / withAnimation

- (void)testDefaultStyleIsPushAndDefaultAnimatedIsYES {
    MLRouter.create.build(@"mltest://page/basic").open(); // 不指定样式与动画
    XCTAssertEqual([TestRecordingNavController pushCount], 1u, @"默认转场样式为 Push，应走 pushViewController");
    XCTAssertTrue([TestRecordingNavController lastPushAnimated], @"默认 animated 为 YES");
}

- (void)testPushStylePushesOntoNavigationStackAndPassesAnimatedNO {
    TestRecordingNavController *nav = [self navRoot];
    NSUInteger before = nav.viewControllers.count;
    MLRouter.create.build(@"mltest://page/basic")
        .withTransitionStyle(MLRouteTransitionStylePush)
        .withAnimation(NO)
        .open();
    XCTAssertEqual([TestRecordingNavController pushCount], 1u, @"Push 样式应调用 pushViewController");
    XCTAssertEqual([TestRecordingNavController presentCount], 0u, @"Push 样式不应走 present 分支");
    XCTAssertEqual(nav.viewControllers.count, before + 1, @"导航栈应新增一层");
    XCTAssertTrue([nav.topViewController isKindOfClass:[TestRouteViewController class]], @"栈顶应为目标页面");
    XCTAssertFalse([TestRecordingNavController lastPushAnimated], @"withAnimation(NO) 应把 animated=NO 透传给转场调用");
}

- (void)testPresentStyleWrapsInNavigationControllerAndPresents {
    TestRecordingNavController *nav = [self navRoot];
    MLRouter.create.build(@"mltest://page/basic")
        .withTransitionStyle(MLRouteTransitionStylePresent)
        .withAnimation(NO)
        .open();
    XCTAssertEqual([TestRecordingNavController pushCount], 0u, @"Present 样式不应 push");
    XCTAssertGreaterThanOrEqual([TestRecordingNavController presentCount], 1u, @"Present 样式应调用 presentViewController");
    XCTAssertFalse([TestRecordingNavController lastPresentAnimated], @"withAnimation(NO) 应透传 animated=NO");
    XCTAssertTrue([nav.presentedViewController isKindOfClass:[UINavigationController class]],
                  @"Present 样式应把目标页面包进导航控制器再弹出");
    UINavigationController *presented = (UINavigationController *)nav.presentedViewController;
    XCTAssertTrue([presented.topViewController isKindOfClass:[TestRouteViewController class]],
                  @"包裹后的导航栈顶应为目标页面");
}

#pragma mark - 执行优先级：静态段 vs 动态路由

- (void)testStaticPageRouteWinsOverDynamicRoute {
    __block BOOL dynamicCalled = NO;
    [MLRouter registerRoute:@"mltest://page/basic" handler:^id(NSDictionary *params, MLRouterRequest *req) {
        dynamicCalled = YES;
        return @"dynamic-should-not-win";
    }];
    id ret = MLRouter.create.build(@"mltest://page/basic").open();
    XCTAssertEqualObjects(ret, @(YES), @"编译期静态段注册优先于运行时动态路由");
    XCTAssertFalse(dynamicCalled, @"静态命中时动态 handler 不应被调用");
}

- (void)testStaticWildcardPageWinsOverDynamicExactRoute {
    __block BOOL dynamicCalled = NO;
    [MLRouter registerRoute:@"mltest://page/wild/999" handler:^id(NSDictionary *params, MLRouterRequest *req) {
        dynamicCalled = YES;
        return @"dynamic-should-not-win";
    }];
    id ret = MLRouter.create.build(@"mltest://page/wild/999").open();
    XCTAssertEqualObjects(ret, @(YES), @"静态通配符页面优先于动态精确路由（静态查找先于动态查找）");
    XCTAssertFalse(dynamicCalled, @"静态通配符命中时动态 handler 不应被调用");
}

- (void)testDynamicRouteHandlesStaticMiss {
    [MLRouter registerRoute:@"mltest://dyn/hello" handler:^id(NSDictionary *params, MLRouterRequest *req) {
        return @"dyn-ok";
    }];
    id ret = MLRouter.create.build(@"mltest://dyn/hello").open();
    XCTAssertEqualObjects(ret, @"dyn-ok", @"静态段未命中时应落到动态路由");
}

/// 【契约反转（P1 修复）】动态 handler 一旦被调用过即为「命中」。
/// handler 主动返回 nil 属于合法的业务返回值，**不得**被误判成「路由未命中」而去走 404 兜底。
/// 旧实现用「返回值非 nil」当命中判据，导致返回 nil 的动态路由会被兜底页顶包。
- (void)testDynamicHandlerReturningNilCountsAsHitAndBypassesFallback {
    [MLRouter registerRoute:@"mltest://dyn/nil" handler:^id(NSDictionary *params, MLRouterRequest *req) {
        return nil; // 动态 handler 的合法业务返回值
    }];
    [MLRouter setFallbackHandler:^id(MLRouterRequest *req, NSError *err) {
        [TestCapture setFallbackCalled:YES];
        return @"fallback-after-nil-dynamic";
    }];
    id ret = MLRouter.create.build(@"mltest://dyn/nil").open();
    XCTAssertFalse([TestCapture fallbackCalled], @"命中即为命中：handler 返回 nil 不应走 404 兜底");
    XCTAssertNil(ret, @"未配置 completion 时 open() 直接返回 handler 的业务返回值（此处为 nil）");
}

#pragma mark - 方法路由：同步返回 + completion 双通道

- (void)testSyncMethodRouteDeliversReturnValueViaCompletion {
    __block id captured = nil;
    MLRouter.create.build(@"mltest://method/add")
        .withParam(@"a", @4)
        .withParam(@"b", @5)
        .withCompletion(^(id result) { captured = result; })
        .open();
    XCTAssertEqualObjects(captured, @9, @"同步方法（无 block 参数）也应经 completion 回传返回值");
}

#pragma mark - 重定向语义

- (void)testRedirectPreservesQueryString {
    id ret = MLRouter.create.build(@"mltest://redirq?echo=42").open();
    XCTAssertEqualObjects(ret, @"42", @"重定向应保留原 URL 的 query，再交给重定向目标路由");
}

- (void)testWhitelistIsEvaluatedOnPostRedirectURL {
    // 白名单只放行方法路由前缀，但入口 URL mltest://redirq 本身不在白名单内。
    // 框架在重定向解析「之后」再校验白名单（校验最终 URL），因此该请求应放行。
    [MLRouter setAllowedURLPaths:[NSSet setWithObject:@"mltest://method/"]];
    id ret = MLRouter.create.build(@"mltest://redirq?echo=7").open();
    XCTAssertEqualObjects(ret, @"7", @"白名单校验发生在重定向解析之后（校验的是最终 URL）");
}

#pragma mark - 安全白名单：正向放行路径（此前只测了拦截，未测放行）

- (void)testWhitelistAllowsMatchingScheme {
    [MLRouter setAllowedSchemes:[NSSet setWithObject:@"mltest"]];
    id ret = MLRouter.create.build(@"mltest://method/add").withParam(@"a", @1).withParam(@"b", @1).open();
    XCTAssertEqualObjects(ret, @2, @"白名单命中 scheme 时应正常放行");
}

- (void)testWhitelistAllowsMatchingPathPrefix {
    [MLRouter setAllowedURLPaths:[NSSet setWithObject:@"mltest://method/"]];
    id ret = MLRouter.create.build(@"mltest://method/add").withParam(@"a", @2).withParam(@"b", @3).open();
    XCTAssertEqualObjects(ret, @5, @"白名单前缀命中时应正常放行");
}

- (void)testValidatorReturningYesAllowsRoute {
    [MLRouter setRouteValidator:^BOOL(NSURL *url) {
        return [url.scheme isEqualToString:@"mltest"];
    }];
    id ret = MLRouter.create.build(@"mltest://method/add").withParam(@"a", @3).withParam(@"b", @3).open();
    XCTAssertEqualObjects(ret, @6, @"自定义校验器返回 YES 时应放行");
}

- (void)testValidatorTakesPrecedenceOverSchemeWhitelist {
    // validator 优先级最高（短路返回），即使 scheme 白名单会拦截，也应放行
    [MLRouter setAllowedSchemes:[NSSet setWithObject:@"other-scheme"]];
    [MLRouter setRouteValidator:^BOOL(NSURL *url) { return YES; }];
    id ret = MLRouter.create.build(@"mltest://method/add").withParam(@"a", @1).withParam(@"b", @2).open();
    XCTAssertEqualObjects(ret, @3, @"validator 优先级最高：返回 YES 时不应再被 scheme 白名单拦截");
}

#pragma mark - 降级兜底契约

- (void)testBlockedRouteFallbackReceivesForbiddenError {
    [MLRouter setRouteValidator:^BOOL(NSURL *url) { return NO; }];
    __block NSInteger code = 0;
    [MLRouter setFallbackHandler:^id(MLRouterRequest *req, NSError *err) {
        code = err.code;
        return @"blocked-fallback";
    }];
    id ret = MLRouter.create.build(@"mltest://page/basic").open();
    XCTAssertEqual(code, 403, @"被白名单/校验器拦截的路由应以 403 错误进入兜底");
    XCTAssertEqualObjects(ret, @"blocked-fallback");
}

- (void)testFallbackNotCalledWhenRouteHits {
    [MLRouter setFallbackHandler:^id(MLRouterRequest *req, NSError *err) {
        [TestCapture setFallbackCalled:YES];
        return @"should-not-happen";
    }];
    id ret = MLRouter.create.build(@"mltest://method/add").withParam(@"a", @1).withParam(@"b", @1).open();
    XCTAssertEqualObjects(ret, @2);
    XCTAssertFalse([TestCapture fallbackCalled], @"命中路由时不应触发兜底");
}

- (void)testInterceptorRejectTriggersFallbackWithError {
    // setFallbackHandler: 文档契约：「路由未命中或被拦截时回调」
    __block NSInteger code = 0;
    __block NSString *url = nil;
    [MLRouter setFallbackHandler:^id(MLRouterRequest *req, NSError *err) {
        code = err.code;
        url = req.urlStr;
        [TestCapture setFallbackCalled:YES];
        return @"interceptor-reject-fallback";
    }];
    id ret = MLRouter.create.build(@"mltest://method/add?track=blocked").open();
    XCTAssertTrue([TestCapture fallbackCalled], @"被拦截器 reject 的路由应进入兜底（而非静默返回 nil）");
    XCTAssertEqual(code, 403, @"拦截器 reject 携带的 error 应原样传给兜底");
    XCTAssertTrue([url containsString:@"blocked"], @"兜底应能拿到原始请求 URL");
    XCTAssertEqualObjects(ret, @"interceptor-reject-fallback");
}

- (void)testInterceptorRejectDoesNotExecuteTarget {
    // 未配置兜底时，被拒绝的路由应返回 nil 且不执行目标方法
    id ret = MLRouter.create.build(@"mltest://method/add?track=blocked").open();
    XCTAssertNil(ret, @"被拒绝且无兜底时应返回 nil");
}

#pragma mark - 复杂链路：拦截器注入公共参数 → 下游消费

- (void)testInterceptorCanInjectParamsIntoDownstreamRoute {
    // URL 含 enrich -> TestEnrichInterceptor(70) 注入 b=100；a=1 来自 query，故 1+100=101
    id ret = MLRouter.create.build(@"mltest://method/add?a=1&enrich=1").open();
    XCTAssertEqualObjects(ret, @101, @"拦截器注入的公共参数应参与下游路由执行");
}

- (void)testInterceptorDoesNotInjectParamsForUnrelatedRoutes {
    id ret = MLRouter.create.build(@"mltest://method/add?a=1&b=1").open();
    XCTAssertEqualObjects(ret, @2, @"非 enrich 路由不应被注入参数");
}

#pragma mark - 通配符：静态多级贪婪

- (void)testStaticGreedyWildcardCapturesMultiSegmentPath {
    id ret = MLRouter.create.build(@"mltest://page/greedy/a/b/c").open();
    XCTAssertEqualObjects(ret, @(YES), @"** 应贪婪匹配跨多级路径");
    XCTAssertEqualObjects([TestCapture lastParams][@"wildcard_1"], @"a/b/c",
                          @"多级通配符应把完整剩余路径捕获为 wildcard_1");
}

#pragma mark - 参数映射的类型转换分支

- (void)testTypedPropertyMappingCoversStringIntegerDoubleAndBool {
    MLRouter.create.build(@"mltest://page/typed?count=7&ratio=1.5&enabled=1&name=tom").open();
    id last = [TestCapture lastVC];
    XCTAssertTrue([last isKindOfClass:[TestTypedViewController class]], @"应记录到类型化参数页面实例");
    TestTypedViewController *vc = (TestTypedViewController *)last;
    XCTAssertEqual(vc.count, 7, @"Tq（NSInteger）分支应被正确转换");
    XCTAssertEqualWithAccuracy(vc.ratio, 1.5, 0.0001, @"Td（double）分支应被正确转换");
    XCTAssertTrue(vc.enabled, @"Tc/TB（BOOL）分支应被正确转换");
    XCTAssertEqualObjects(vc.name, @"tom", @"T@（对象）分支应直接赋值");
}

- (void)testTypedBooleanFalseMapping {
    MLRouter.create.build(@"mltest://page/typed?enabled=0").open();
    TestTypedViewController *vc = (TestTypedViewController *)[TestCapture lastVC];
    XCTAssertTrue([vc isKindOfClass:[TestTypedViewController class]]);
    XCTAssertFalse(vc.enabled, @"enabled=0 应映射为 NO");
}

- (void)testTypedMappingSkipsKeysWithoutMatchingProperty {
    // nonexistent 无对应属性：框架靠属性探测跳过，不应 KVC 崩溃
    MLRouter.create.build(@"mltest://page/typed?nonexistent=1&count=3").open();
    TestTypedViewController *vc = (TestTypedViewController *)[TestCapture lastVC];
    XCTAssertEqual(vc.count, 3, @"未知 key 应被跳过，已知 key 仍正常映射");
    XCTAssertEqualObjects([TestCapture lastParams][@"nonexistent"], @"1", @"全量参数仍应留底在 ml_routerParams");
}

@end
