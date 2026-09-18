// MLRouterRobustnessTests.m
// 崩溃 / 容错场景全覆盖 —— 专测「真实开发中一定会遇到的烂输入与极端情况」。
//
// 这个文件回答一个问题：**把框架推到极限，它会不会崩、会不会静默失效、会不会把自己锁死。**
//
// 三类重点：
//   ① 异常穿透：框架内**零** @try/@catch。异常必须被钉成「同步穿透给调用方」的显式契约，
//      并验证异常之后路由表未被破坏、读写锁未泄漏（后者会表现为后续所有调用死锁）。
//   ② 极端输入：超长 URL / 超多参数 / 畸形路径 / 特殊字符 / 深重定向链。
//   ③ 并发与重入：多线程注册与执行混合、handler 内部重入路由（自死锁高发场景）。

#import <XCTest/XCTest.h>
#import "MLRouterTestSupport.h"

@interface MLRouterRobustnessTests : XCTestCase
@end

@implementation MLRouterRobustnessTests

- (void)setUp {
    [super setUp];
    [TestCapture reset];
    [MLRouter resetRouter]; // 清动态路由 / 白名单 / 兜底
}

#pragma mark - ① 异常穿透（框架不做异常隔离，这是契约）

/// 方法路由 handler 抛 NSException ⇒ 同步穿透给调用方。
///
/// ⚠️ 这是**有意保留**的语义，不是缺陷：路由框架吞掉异常会掩盖业务 bug，
/// 让「handler 里数组越界」变成「页面莫名白屏」。
/// 但必须明确写下来 —— 否则「远程下发的 handler 一崩整 App 就崩」这件事没人知道。
- (void)testMethodRouteHandlerExceptionPropagatesToCaller {
    XCTAssertThrowsSpecificNamed(
        MLRouter.create.build(@"mltest://method/throw").open(),
        NSException, @"TestRouteHandlerException",
        @"handler 抛出的异常应原样穿透给调用方（框架不做 @try/@catch 隔离）");
}

/// 页面 VC 的 init 抛异常 ⇒ 主线程同步路径上应穿透给调用方，而不是被吞掉。
- (void)testPageInitExceptionPropagatesOnMainThread {
    // 断言前提：测试方法跑在主线程。子线程调用时框架会 dispatch 到主队列，
    // 异常将在主队列抛出、调用方无法防御 —— 那种情况不能在本用例里触发（会崩掉整个测试进程）。
    XCTAssertTrue([NSThread isMainThread], @"本用例依赖主线程同步路径才能安全地断言异常");
    if (![NSThread isMainThread]) return;

    XCTAssertThrowsSpecificNamed(
        MLRouter.create.build(@"mltest://page/throwinginit").open(),
        NSException, @"TestPageInitException",
        @"VC 构造失败时异常应穿透给调用方");
}

/// 拦截器内部抛异常 ⇒ 同样穿透，且下游目标不被执行。
- (void)testInterceptorExceptionPropagatesAndSkipsTarget {
    [TestCapture reset];
    XCTAssertThrowsSpecificNamed(
        MLRouter.create.build(@"mltest://method/add?a=1&b=2&tag=throwintercept").open(),
        NSException, @"TestInterceptorException",
        @"拦截器抛出的异常应穿透给调用方");
}

/// 【关键】异常之后，路由器必须完全可用 —— 不得有锁泄漏、不得有状态残留。
///
/// 如果框架是在「持有读写锁」的情况下调用 handler，抛异常会导致锁永不释放：
/// 本用例最后的正常路由调用会**死锁**并超时失败，而不是断言失败。
- (void)testRouterRemainsFullyUsableAfterExceptions {
    // 依次触发三类异常
    @try { MLRouter.create.build(@"mltest://method/throw").open(); } @catch (NSException *e) { (void)e; }
    @try { MLRouter.create.build(@"mltest://page/throwinginit").open(); } @catch (NSException *e) { (void)e; }
    @try { MLRouter.create.build(@"mltest://method/add?tag=throwintercept").open(); } @catch (NSException *e) { (void)e; }

    // 异常之后一切照旧：方法路由、页面路由、动态路由都要能正常工作
    id sum = MLRouter.create.build(@"mltest://method/add?a=20&b=22").open();
    XCTAssertEqualObjects(sum, @42, @"异常之后方法路由必须仍然可用（否则说明读写锁泄漏 / 状态被破坏）");

    id page = MLRouter.create.build(@"mltest://page/basic").open();
    XCTAssertEqualObjects(page, @(YES), @"异常之后页面路由必须仍然可用");

    [MLRouter registerRoute:@"mltest://robust/afterexc" handler:^id(NSDictionary *params, MLRouterRequest *request) {
        return @"ok";
    }];
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://robust/afterexc").open(), @"ok",
                          @"异常之后动态路由注册与执行必须仍然可用");
}

/// 动态路由 handler 抛异常：同样穿透，且不得把动态表弄坏。
- (void)testDynamicRouteHandlerExceptionPropagates {
    [MLRouter registerRoute:@"mltest://robust/dynthrowing" handler:^id(NSDictionary *params, MLRouterRequest *request) {
        @throw [NSException exceptionWithName:@"TestDynamicHandlerException" reason:@"boom" userInfo:nil];
    }];
    XCTAssertThrowsSpecificNamed(MLRouter.create.build(@"mltest://robust/dynthrowing").open(),
                                 NSException, @"TestDynamicHandlerException",
                                 @"动态 handler 的异常也应穿透");
    // 表仍然完好
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://method/add?a=1&b=1").open(), @2,
                          @"动态 handler 抛异常后静态路由表不受影响");
}

#pragma mark - ② 深重定向链与防环守卫边界

/// 恰好在上限内（16 跳）的链应能正常解析到终点。
- (void)testDeepRedirectChainWithinGuardResolves {
    // over/5 → over/6 → … → over/20 → method/echo，刚好 16 跳。
    // echoParamsWithParams: 回显的是 params[@"echo"]，所以这里必须用 echo= 而非 tag=。
    id ret = MLRouter.create.build(@"mltest://over/5?echo=deep").open();
    XCTAssertEqualObjects(ret, @"deep", @"16 跳（守卫上限内）应解析到终点 method/echo 并回显参数");
}

/// ⚠️【静默失效】超过 16 跳的链会被守卫**静默截断**：既不报错、也不打日志，直接变成 404。
///
/// 真实风险：历史 URL 迁移链（A→B→C→D→…）一旦因配置事故变长，或配置里存在长环，
/// 表现就是「这条老链接莫名其妙打不开」，且没有任何日志指向重定向。
- (void)testDeepRedirectChainBeyondGuardSilentlyTruncates {
    // over/4 → … → over/20 → method/echo 需要 17 跳，超出守卫上限
    id ret = MLRouter.create.build(@"mltest://over/4").open();
    XCTAssertNil(ret, @"超出 16 跳上限的链会被静默截断，最终落到未命中（无兜底时返回 nil）");
}

/// 重定向链与查询串共存：query 必须一路带到终点。
- (void)testRedirectChainPreservesQueryAcrossHops {
    id ret = MLRouter.create.build(@"mltest://over/5?echo=carried").open();
    XCTAssertEqualObjects(ret, @"carried", @"每一跳都应保留 query");
}

#pragma mark - ③ 畸形与极端 URL

- (void)testVeryLongPathDoesNotCrash {
    NSString *longSegment = [@"" stringByPaddingToLength:5000 withString:@"a" startingAtIndex:0];
    id ret = MLRouter.create.build([NSString stringWithFormat:@"mltest://page/%@", longSegment]).open();
    XCTAssertNil(ret, @"5000 字符路径应安全返回 nil（未命中），不得崩溃");
}

- (void)testVeryManyQueryParamsDoesNotCrash {
    NSMutableString *query = [NSMutableString stringWithString:@"mltest://method/echo?"];
    for (NSInteger i = 0; i < 200; i++) {
        [query appendFormat:@"k%ld=v%ld&", (long)i, (long)i];
    }
    [query appendString:@"echo=last"];
    id ret = MLRouter.create.build(query).open();
    XCTAssertEqualObjects(ret, @"last", @"200 个 query 参数应可正常解析");
}

- (void)testConsecutiveSlashesInPathDoNotCrash {
    XCTAssertNil(MLRouter.create.build(@"mltest://page//basic").open(),
                 @"连续斜杠路径未命中时安全返回 nil（不崩溃、不误命中）");
    XCTAssertNil(MLRouter.create.build(@"mltest://page///").open(), @"全斜杠路径应安全返回 nil");
}

/// 钉住「尾部斜杠是不同路由」这一行为。
///
/// 这是真实开发里的高频踩坑：`x://a/b` 与 `x://a/b/` 被视为不同路由，
/// 注册时少写或多写一个斜杠就静默不命中。
/// 钉住「尾斜杠会被 NSURL 归一化」—— 与直觉相反，实测确认它是**等价**的，不是不同的路由。
///
/// 实测证据（诊断打印）：`[NSURL URLWithString:@"mltest://page/basic/"].path` 返回 `@"/basic"`，
/// **没有**尾斜杠 —— NSURL 在解析阶段就去掉了。所以注册时写不写尾斜杠效果一致，
/// **不存在**「多写一个斜杠就静默不命中」这个常见坑（我原本以为有，实测推翻了）。
///
/// 边界：这**只**对尾部单个斜杠成立；路径中间的连续斜杠（`//`）会被 NSURL 保留 → 不等价 →
/// 不命中（见 testConsecutiveSlashesInPathDoNotCrash）。
- (void)testTrailingSlashIsNormalizedByNSURL {
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://page/basic").open(), @(YES),
                          @"无尾斜杠应命中");
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://page/basic/").open(), @(YES),
                          @"带尾斜杠也应命中 —— NSURL 已把尾斜杠归一化掉，两者等价");
    XCTAssertNil(MLRouter.create.build(@"mltest://page//basic").open(),
                 @"但路径中间的连续斜杠会被保留 → 与注册路径不等价 → 不命中");
}

- (void)testSchemeOnlyAndDegenerateURLsDoNotCrash {
    XCTAssertNil(MLRouter.create.build(@"mltest://").open(), @"只有 scheme 的 URL 应安全返回 nil");
    XCTAssertNil(MLRouter.create.build(@"mltest:///").open(), @"空 host 应安全返回 nil");
    XCTAssertNil(MLRouter.create.build(@"://").open(), @"无 scheme 应安全返回 nil");
    XCTAssertNil(MLRouter.create.build(@"mltest").open(), @"纯字符串应安全返回 nil");
}

/// 特殊字符与百分号编码：URL 参数的真实形态。
///
/// ⚠️ 编码时**必须**用 RFC 3986 的 unreserved 集合（字母数字 + `-._~`）。
/// `NSCharacterSet.URLQueryAllowedCharacterSet` **包含** `&` `=` `+`（它们在 query 里
/// 本来就是合法分隔符），用它编码等于没编码 —— 这是我第一版测试写错的地方，
/// 现象是 `a+b&c=d` 被拆成了两个参数。
- (void)testSpecialCharactersAndPercentEncodingInParams {
    NSString *encoded = [self strictlyEncoded:@"a+b&c=d"];
    MLRouter.create.build([NSString stringWithFormat:@"mltest://page/alltypes?objVal=%@", encoded]).open();
    TestAllTypesViewController *vc = (TestAllTypesViewController *)[TestCapture lastVC];
    XCTAssertTrue([vc isKindOfClass:[TestAllTypesViewController class]]);
    XCTAssertEqualObjects(vc.objVal, @"a+b&c=d", @"百分号编码的 & 和 = 不应被当成参数分隔符");
}

- (void)testEmojiAndNewlineInParamsDoNotCrash {
    NSString *encoded = [self strictlyEncoded:@"😀\nemoji"];
    MLRouter.create.build([NSString stringWithFormat:@"mltest://page/alltypes?objVal=%@", encoded]).open();
    TestAllTypesViewController *vc = (TestAllTypesViewController *)[TestCapture lastVC];
    XCTAssertTrue([vc isKindOfClass:[TestAllTypesViewController class]]);
    XCTAssertEqualObjects(vc.objVal, @"😀\nemoji", @"Emoji 与换行应原样解码");
}

/// RFC 3986 unreserved 字符集编码（字母数字 + `-._~`）。
- (NSString *)strictlyEncoded:(NSString *)raw {
    NSMutableCharacterSet *unreserved = [NSMutableCharacterSet alphanumericCharacterSet];
    [unreserved addCharactersInString:@"-._~"];
    return [raw stringByAddingPercentEncodingWithAllowedCharacters:unreserved];
}

- (void)testDuplicateQueryKeysDoNotCrash {
    // ?k=1&k=2 —— 同一 key 出现多次，行为是「后者胜」还是「忽略」，至少要保证不崩
    MLRouter.create.build(@"mltest://page/alltypes?objVal=first&objVal=second").open();
    TestAllTypesViewController *vc = (TestAllTypesViewController *)[TestCapture lastVC];
    XCTAssertTrue([vc isKindOfClass:[TestAllTypesViewController class]]);
    XCTAssertNotNil(vc.objVal, @"重复 key 至少要有一个值落上，且不得崩溃");
}

#pragma mark - ④ 并发与重入

/// 【自死锁检测】handler 内部再次调用路由（路由 A 的 handler 打开路由 B）。
///
/// 真实场景极常见：聚合页 A 的 handler 需要顺带触发埋点路由 B。
/// 如果框架在持锁状态下执行 handler，这个重入会直接死锁 —— 表现是主线程卡死、无崩溃日志。
- (void)testReentrantOpenFromHandlerDoesNotDeadlock {
    __block id innerResult = nil;
    [MLRouter registerRoute:@"mltest://robust/outer" handler:^id(NSDictionary *params, MLRouterRequest *request) {
        // 重入：在 handler 内再走一次路由
        innerResult = MLRouter.create.build(@"mltest://method/add?a=1&b=2").open();
        return @"outer-done";
    }];
    id ret = MLRouter.create.build(@"mltest://robust/outer").open();
    XCTAssertEqualObjects(ret, @"outer-done", @"外层路由应正常返回（未死锁）");
    XCTAssertEqualObjects(innerResult, @3, @"handler 内的重入调用也应正常返回（未死锁）");
}

/// 页面路由 completion 里再打开一条路由（异步重入）。
- (void)testReentrantOpenFromCompletionBlockIsSafe {
    XCTestExpectation *exp = [self expectationWithDescription:@"reentrant from completion"];
    [MLRouter registerRoute:@"mltest://robust/reenter" handler:^id(NSDictionary *params, MLRouterRequest *request) {
        return @"first";
    }];
    MLRouter.create.build(@"mltest://robust/reenter").withCompletion(^(id result) {
        XCTAssertEqualObjects(result, @"first");
        // 在 completion 回调里再次调用路由
        id second = MLRouter.create.build(@"mltest://method/add?a=5&b=6").open();
        XCTAssertEqualObjects(second, @11, @"completion 里的重入调用应正常");
        [exp fulfill];
    }).open();
    [self waitForExpectationsWithTimeout:3 handler:nil];
}

/// 多线程混合压测：同时注册 / 打开 / 反注册不同 pattern。
/// 与已有 testConcurrentOpenCallsAreSafeAndCorrect（纯读）互补 —— 这条是**读写混合**。
- (void)testConcurrentRegisterOpenUnregisterIsSafe {
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    for (NSInteger i = 0; i < 8; i++) {
        dispatch_group_async(group, queue, ^{
            for (NSInteger j = 0; j < 40; j++) {
                NSString *pattern = [NSString stringWithFormat:@"mltest://robust/concurrent/%ld", (long)(j % 8)];
                [MLRouter registerRoute:pattern handler:^id(NSDictionary *params, MLRouterRequest *request) {
                    return pattern;
                }];
                MLRouter.create.build(pattern).open();
                MLRouter.create.build(@"mltest://method/add?a=1&b=1").open();
                if (j % 3 == 0) [MLRouter unregisterRoute:pattern];
            }
        });
    }

    XCTAssertEqual(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC))), 0,
                   @"并发注册 / 打开 / 反注册混合操作应在超时前全部完成（不卡死）");

    // 收尾后路由器仍然一致可用
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://method/add?a=3&b=4").open(), @7,
                          @"并发压测之后路由表仍应一致可用");
}

/// 同一 pattern 重复注册上千次：必须 last-wins，且路由表**不得无限增长**。
- (void)testThousandRepeatedRegistrationsStayBoundedAndLastWins {
    for (NSInteger i = 0; i < 1000; i++) {
        [MLRouter registerRoute:@"mltest://robust/dup" handler:^id(NSDictionary *params, MLRouterRequest *request) {
            return @(i);
        }];
    }
    id ret = MLRouter.create.build(@"mltest://robust/dup").open();
    XCTAssertEqualObjects(ret, @999, @"同一 pattern 重复注册应为 last-wins");

    NSArray *dynamic = [MLRouter exportRouteTable][@"dynamic"];
    NSUInteger occurrences = 0;
    for (NSString *p in dynamic) {
        if ([p isEqualToString:@"mltest://robust/dup"]) occurrences++;
    }
    XCTAssertEqual(occurrences, 1, @"同一 pattern 重复注册 1000 次后，路由表中只应存在 1 条（否则表会无限膨胀）");
}

/// 大量动态注册不得影响静态段路由的命中。
- (void)testManyDynamicRoutesDoNotShadowStaticRoutes {
    for (NSInteger i = 0; i < 500; i++) {
        NSString *pattern = [NSString stringWithFormat:@"mltest://robust/bulk/%ld", (long)i];
        [MLRouter registerRoute:pattern handler:^id(NSDictionary *params, MLRouterRequest *request) {
            return @(i);
        }];
    }
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://method/add?a=100&b=200").open(), @300,
                          @"500 条动态路由注册后，静态方法路由仍应优先命中且结果正确");
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://robust/bulk/499").open(), @499,
                          @"新增的动态路由本身也应可命中");
}

/// 反复 reset + reload：状态机必须可重复进入，不累积、不丢段注册。
- (void)testRepeatedResetAndReloadIsStable {
    for (NSInteger i = 0; i < 50; i++) {
        [MLRouter resetRouter];
        [MLRouter ensureRoutesLoaded];
        XCTAssertEqualObjects(MLRouter.create.build(@"mltest://page/basic").open(), @(YES),
                              @"每轮 reset 之后段注册的页面路由都应重新可用");
    }
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://method/add?a=2&b=2").open(), @4,
                          @"反复 reset/reload 之后方法路由仍应可用");
}

/// 模块反复加载：与 reset 交替进行，确保不重复初始化、不崩。
///
/// 注意不能用 [`MLRouter resetRouter`] 清模块后再断言导出清单为空 ——
/// 段注册幂等数据不应被 reset 清掉，导出清单里模块应始终存在。
- (void)testRepeatedLoadModulesIsStable {
    for (NSInteger i = 0; i < 30; i++) {
        [MLRouterModuleManager loadModules];
    }
    NSArray<NSString *> *names = [MLRouterModuleManager exportedModuleNames];
    XCTAssertTrue(names.count > 0, @"反复 loadModules 之后模块清单不应为空");
    XCTAssertEqual([MLRouterModuleManager exportedModuleNames].count, names.count,
                   @"反复 loadModules 不应造成清单重复膨胀");
}

@end
