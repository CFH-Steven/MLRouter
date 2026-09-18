// MLRouterEdgeCaseTests.m
// 错误场景 + 边界场景 + 正常场景补全测试。
//
// 覆盖策略：
// - 错误输入：nil/空/纯空白/无 scheme/空 path/含 fragment/含中文的 URL
// - 注册异常：重复注册（动态 last-wins / 段注册不崩溃）、未注册类名容错、反注册不存在项
// - 重定向异常：重定向环（防环守卫）、重定向目标不存在
// - 白名单边界：nil 白名单=全放行、空白名单=全拦截、校验器拒绝
// - 拦截器契约：异步 next 时同步返回值不可用、completion 仍可回传
// - 并发：多线程并发 open 无崩溃、结果正确
// - View 路由：参数映射 + 未知参数容错

#import <XCTest/XCTest.h>
#import "MLRouterTestSupport.h"

#pragma mark - 服务重复注册测试用的协议与双实现

@protocol EdgeDummyService <NSObject>
- (NSString *)tag;
@end

@interface EdgeDummyImplA : NSObject <EdgeDummyService>
@end
@implementation EdgeDummyImplA
- (NSString *)tag { return @"A"; }
@end

@interface EdgeDummyImplB : NSObject <EdgeDummyService>
@end
@implementation EdgeDummyImplB
- (NSString *)tag { return @"B"; }
@end

#pragma mark - 测试

@interface MLRouterEdgeCaseTests : XCTestCase
@end

@implementation MLRouterEdgeCaseTests

- (void)setUp {
    [super setUp];
    [MLRouter resetRouter]; // 清动态路由/白名单/兜底（编译期段注册不受影响）
    [TestCapture reset];
}

#pragma mark - 错误输入：非法 URL 全家桶

- (void)testNilURLOpenReturnsNilWithoutCrash {
    id ret = MLRouter.create.build(nil).open();
    XCTAssertNil(ret, @"nil URL 应安全返回 nil");
}

- (void)testEmptyAndWhitespaceURLsReturnNil {
    XCTAssertNil(MLRouter.create.build(@"").open(), @"空字符串");
    XCTAssertNil(MLRouter.create.build(@"   ").open(), @"纯空白");
    XCTAssertNil(MLRouter.create.build(@"mltest://").open(), @"仅 scheme 无 path");
    XCTAssertNil(MLRouter.create.build(@"://").open(), @"仅分隔符");
    XCTAssertNil(MLRouter.create.build(@"not-a-valid-url").open(), @"无 scheme 裸字符串");
}

- (void)testUnknownSchemeReturnsNil {
    XCTAssertNil(MLRouter.create.build(@"unknownscheme://foo/bar").open(), @"未注册 scheme 应 404");
}

#pragma mark - 正常场景补全：query 解析边界

- (void)testQueryWithFragmentStillParsesParams {
    // fragment 不影响 query 解析
    id ret = MLRouter.create.build(@"mltest://method/add?a=1&b=2#anchor").open();
    XCTAssertEqualObjects(ret, @3, @"带 fragment 的 URL 应正确解析 query 参数");
}

- (void)testPercentEncodedChineseQueryParam {
    // name=%E8%B4%AD%E7%89%A9%E8%BD%A6（"购物车"），只参与 a/b 计算，验证解析不崩、值正确
    id ret = MLRouter.create.build(@"mltest://method/add?a=7&name=%E8%B4%AD%E7%89%A9%E8%BD%A6").open();
    XCTAssertEqualObjects(ret, @7, @"百分号编码的中文 query 应正常解析");
}

- (void)testMethodRouteWithMissingParamsIsSafe {
    // addWithParams 对缺参返回 0，不应崩溃
    id ret = MLRouter.create.build(@"mltest://method/add").open();
    XCTAssertEqualObjects(ret, @0, @"缺参应走默认值 0 而非崩溃");
}

#pragma mark - 注册异常：重复注册与容错

- (void)testDuplicateDynamicRouteRegistrationLastWins {
    [MLRouter registerRoute:@"mltest://dyn/dup" handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
        return @1;
    }];
    [MLRouter registerRoute:@"mltest://dyn/dup" handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
        return @2;
    }];
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://dyn/dup").open(), @2,
                          @"同一 URL 重复注册动态路由应后者覆盖前者（last-wins）");
}

- (void)testDuplicateSegmentPageRegistrationDoesNotCrash {
    // 段注册同 URL 两次（TestSupport 中 mltest://page/dup 注册了两个类）：不崩溃、仍可路由。
    // 双通道契约：open() 回 @(YES)，completion 回被 present 的页面实例（last-wins → TestParamViewController）。
    XCTestExpectation *exp = [self expectationWithDescription:@"dup page present"];
    id openRet = MLRouter.create.build(@"mltest://page/dup").withCompletion(^(id _Nullable result) {
        XCTAssertTrue([result isKindOfClass:[TestParamViewController class]],
                      @"重复段注册的页面应仍可正常 present，且按 last-wins 命中后注册的类");
        [exp fulfill];
    }).open();
    XCTAssertEqualObjects(openRet, @(YES), @"重复段注册的页面路由 open() 仍应返回 @(YES)");
    [self waitForExpectationsWithTimeout:3 handler:nil];
}

- (void)testBogusClassNamePageFailsGracefully {
    // TestSupport 中 mltest://page/bogus 注册了不存在的类名 → NSClassFromString 返回 nil → 404
    __block BOOL fallbackCalled = NO;
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull request, NSError * _Nullable error) {
        fallbackCalled = YES;
        return nil;
    }];
    id ret = MLRouter.create.build(@"mltest://page/bogus").open();
    XCTAssertNil(ret, @"类名无效的页面路由应安全失败");
    XCTAssertTrue(fallbackCalled, @"应进入降级兜底而非崩溃/静默丢失");
}

- (void)testUnregisterNonexistentDynamicRouteNoCrash {
    XCTAssertNoThrow([MLRouter unregisterRoute:@"mltest://never/registered"], @"反注册不存在的路由不应崩溃");
}

- (void)testDuplicateRuntimeServiceRegistrationLastWins {
    [MLRouterService registerService:@protocol(EdgeDummyService) implClass:[EdgeDummyImplA class]];
    [MLRouterService registerService:@protocol(EdgeDummyService) implClass:[EdgeDummyImplB class]];
    id<EdgeDummyService> svc = [MLRouterService serviceForProtocol:@protocol(EdgeDummyService)];
    XCTAssertEqualObjects([svc tag], @"B", @"同协议重复注册应后注册者生效");
    [MLRouterService unregisterService:@protocol(EdgeDummyService)];
}

#pragma mark - 重定向异常

- (void)testRedirectCycleTerminatesByGuard {
    // mltest://cycle1 ⇄ mltest://cycle2 构成环；防环守卫（16 跳）应终止并走 404，绝不能死循环
    __block BOOL fallbackCalled = NO;
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull request, NSError * _Nullable error) {
        fallbackCalled = YES;
        return nil;
    }];
    id ret = MLRouter.create.build(@"mltest://cycle1").open();
    XCTAssertNil(ret, @"重定向环应在守卫上限处终止");
    XCTAssertTrue(fallbackCalled, @"环终止后应进入兜底");
}

- (void)testRedirectToMissingTargetReturnsNil {
    XCTAssertNil(MLRouter.create.build(@"mltest://rmissing").open(),
                 @"重定向到不存在的目标应 404 返回 nil");
}

#pragma mark - 白名单边界

- (void)testNilWhitelistAllowsAllRoutes {
    [MLRouter setAllowedSchemes:nil]; // nil = 未启用 scheme 白名单
    id ret = MLRouter.create.build(@"mltest://method/add?a=1&b=1").open();
    XCTAssertEqualObjects(ret, @2, @"白名单为 nil 时不应拦截任何路由");
}

- (void)testEmptyWhitelistBlocksAllRoutes {
    [MLRouter setAllowedSchemes:[NSSet set]]; // 空集 = 任何 scheme 都不放行
    __block BOOL fallbackCalled = NO;
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull request, NSError * _Nullable error) {
        fallbackCalled = YES;
        return nil;
    }];
    id ret = MLRouter.create.build(@"mltest://method/add?a=1&b=1").open();
    XCTAssertNil(ret, @"空白名单应拦截全部路由");
    XCTAssertTrue(fallbackCalled, @"被白名单拦截应进入兜底");
}

#pragma mark - 拦截器契约：异步 next

- (void)testAsyncInterceptorSyncReturnUnavailableButCompletionDelivers {
    __weak typeof(self) weakSelf = self;
    [MLRouter registerRoute:@"mltest://asyncchain/dyn" handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
        return @42;
    }];
    XCTestExpectation *exp = [self expectationWithDescription:@"async chain completion"];
    id syncRet = MLRouter.create.build(@"mltest://asyncchain/dyn")
        .withCompletion(^(id _Nullable result) {
            XCTAssertEqualObjects(result, @42, @"异步拦截链放行后结果应经 completion 回传");
            [exp fulfill];
        }).open();
    XCTAssertNil(syncRet, @"⚠️ 拦截器异步 next 时同步返回值不可用（返回 nil）——这是框架的明确契约");
    [weakSelf waitForExpectationsWithTimeout:3 handler:nil];
}

#pragma mark - 并发安全

- (void)testConcurrentOpenCallsAreSafeAndCorrect {
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_queue_create("ml.edge.concurrent", DISPATCH_QUEUE_CONCURRENT);
    NSMutableArray<NSNumber *> *results = [NSMutableArray array];
    NSLock *lock = [NSLock new];
    NSInteger total = 24;

    for (NSInteger i = 0; i < total; i++) {
        dispatch_group_enter(group);
        dispatch_async(queue, ^{
            NSNumber *r = MLRouter.create.build(@"mltest://method/add")
                .withParam(@"a", @(i)).withParam(@"b", @(1)).open();
            [lock lock];
            [results addObject:r ?: @-1];
            [lock unlock];
            dispatch_group_leave(group);
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    XCTAssertEqual(results.count, (NSUInteger)total, @"并发 open 不应丢结果");
    NSInteger sum = 0;
    for (NSNumber *r in results) sum += r.integerValue;
    NSInteger expected = total + (total - 1) * total / 2; // Σ(i+1), i∈[0,24)
    XCTAssertEqual(sum, expected, @"全部并发调用的计算结果应正确");
}

#pragma mark - View 路由边界

- (void)testViewRouteParamMapping {
    id ret = MLRouter.create.build(@"mltest://view/badge")
        .withParam(@"badgeText", @"边界测试")
        .open();
    XCTAssertTrue([ret isKindOfClass:[TestBadgeView class]], @"View 路由应返回视图实例");
    XCTAssertEqualObjects(((TestBadgeView *)ret).badgeText, @"边界测试", @"参数应映射到视图属性");
}

- (void)testViewRouteWithUnknownParamsDoesNotCrash {
    // 传入视图上不存在的属性 key：框架映射时应安全跳过
    id ret = MLRouter.create.build(@"mltest://view/badge")
        .withParam(@"notARealProperty", @123)
        .withParam(@"anotherUnknown", @"x")
        .open();
    XCTAssertTrue([ret isKindOfClass:[TestBadgeView class]], @"未知参数不应影响视图创建");
}

#pragma mark - P0 回归：段扫描入口幂等 + 模块加载时序

- (void)testEnsureRoutesLoadedIsIdempotent {
    // ensureRoutesLoaded 是「段扫描 + 静态路由表构建」的唯一入口（+initialize 与
    // MLRouterModuleManager.loadModules 都会调它）。一旦它被误写成每次重扫，静态表会出现
    // 重复条目 —— 通配符表重复尤其危险：同一 URL 命中的页面会随调用次数漂移。
    [MLRouter ensureRoutesLoaded];
    NSDictionary *table1 = [MLRouter exportRouteTable];
    NSUInteger pages1 = [(NSArray *)table1[@"pages"] count];
    NSUInteger wildcards1 = [(NSArray *)table1[@"wildcards"] count];

    [MLRouter ensureRoutesLoaded];
    [MLRouter ensureRoutesLoaded];

    NSDictionary *table2 = [MLRouter exportRouteTable];
    XCTAssertEqual(pages1, [(NSArray *)table2[@"pages"] count],
                   @"重复调用 ensureRoutesLoaded 不得重复注册页面路由");
    XCTAssertEqual(wildcards1, [(NSArray *)table2[@"wildcards"] count],
                   @"重复调用 ensureRoutesLoaded 不得重复注册通配符路由");
}

- (void)testLoadModulesSurvivesAndIsRepeatable {
    // P0 回归：loadModules 必须在扫描模块段之前先确保段扫描已完成。
    // 真机上 loadModules 常是 App 启动后第一个碰路由框架的调用点，而段扫描挂在 MLRouter 的
    // 懒加载 +initialize 上 —— 顺序错了模块清单就是空的，全部 moduleSetup / 生命周期钩子
    // 静默失效。单测里 setUp 先调 resetRouter 已顺带触发过段扫描，掩盖了这个顺序问题，
    // 因此这里只做「调用后清单可用 + 可重复加载」的守门断言，并保留注释说明真机场景。
    [MLRouterModuleManager reset];
    XCTAssertNoThrow([MLRouterModuleManager loadModules], @"loadModules 不得因段扫描未就绪而异常");
    XCTAssertNotNil([MLRouterModuleManager exportedModuleNames], @"loadModules 后模块清单不应为 nil");

    XCTAssertNoThrow([MLRouterModuleManager loadModules], @"loadModules 应可安全重复调用");
    [MLRouterModuleManager loadModules];
    XCTAssertNotNil([MLRouterModuleManager exportedModuleNames], @"重复 loadModules 后清单仍可用");
}

#pragma mark - 正常场景补全：动态路由返回 UIViewController 自动 present

- (void)testDynamicRouteReturningVCPresents {
    // 动态 handler 返回 UIViewController 时：框架必须自动把它送进 UI（默认 Push 样式 → 导航栈顶），
    // open() 同步回 @(YES)，completion 拿到该 VC。
    // （原用例误用了静态页面 URL，其实测不到「动态路由返回 VC」这条路径，这里改用真正的动态注册。）
    //
    // ⚠️【断言姿势 · 踩过的坑】不要用 result.presentingViewController 判断「有没有弹出来」。
    //    该反向引用是 UIKit 在**转场过程中**建立的，而本用例的 completion 是在
    //    `presentViewController:animated:completion:` 调用返回后**同步**回调的 ——
    //    此刻这个引用仍是 nil，会得到一个与框架行为无关的假失败。
    //    正确做法是从**承载容器**侧断言（与 MLRouterDSLAndSemanticsTests 里
    //    nav.presentedViewController / nav.topViewController 的写法一致），
    //    并且用一次性窗口做确定性容器，不依赖宿主 App 的 keyWindow 类型。
    UIWindow *savedWindow = [UIApplication sharedApplication].keyWindow;
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    TestRecordingNavController *nav = [[TestRecordingNavController alloc] init];
    w.rootViewController = nav;
    w.hidden = NO;
    [w makeKeyAndVisible];
    [TestRecordingNavController resetRecord];

    __block UIViewController *landedVC = nil;
    XCTestExpectation *exp = [self expectationWithDescription:@"dynamic VC present"];
    [MLRouter registerRoute:@"mltest://dyn/vc" handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
        return [[TestRouteViewController alloc] init];
    }];
    id openRet = MLRouter.create.build(@"mltest://dyn/vc").withCompletion(^(id _Nullable result) {
        XCTAssertTrue([result isKindOfClass:[TestRouteViewController class]],
                      @"动态 handler 返回的 VC 应被 present，并交给 completion");
        landedVC = (UIViewController *)result;
        [exp fulfill];
    }).open();
    XCTAssertEqualObjects(openRet, @(YES), @"动态路由命中并 present 后 open() 返回 @(YES)");
    XCTAssertFalse([openRet isKindOfClass:[UIViewController class]], @"open() 永不返回 UIViewController");
    [self waitForExpectationsWithTimeout:3 handler:nil];

    // pushViewController 是同步的 ⇒ 这里断言稳定、不依赖转场时序
    XCTAssertEqual([TestRecordingNavController pushCount], 1u, @"默认 Push 样式应走 pushViewController");
    XCTAssertTrue([nav.topViewController isKindOfClass:[TestRouteViewController class]],
                  @"动态 handler 返回的 VC 应真的被送进导航栈");
    XCTAssertEqual(nav.topViewController, landedVC,
                   @"completion 回传的必须是同一个被送进 UI 的实例（双通道指同一对象）");

    [MLRouter unregisterRoute:@"mltest://dyn/vc"];
    w.hidden = YES;
    w.rootViewController = nil;
    [savedWindow makeKeyAndVisible];
}

@end
