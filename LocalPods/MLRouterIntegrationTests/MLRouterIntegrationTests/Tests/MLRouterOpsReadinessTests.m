// MLRouterOpsReadinessTests.m
// 工程防线维度：冷启动时序 / 错误码可区分性（可观测性）/ 校验器优先级契约 /
// 命名空间冲突契约（动态 vs 静态）/ 契约快照 / fuzz 不崩。
//
// 与 MLRouterGovernanceTests 的分工：那边钉「治理层 API 的基础行为」，
// 这里钉「框架在真实产品里活下去」的工程契约 —— 每条都对应一次真实事故形态或审计缺口。
#import <XCTest/XCTest.h>
#import <unistd.h>
#import "MLRouterTestSupport.h"

@interface MLRouterOpsReadinessTests : XCTestCase
@end

@implementation MLRouterOpsReadinessTests

- (void)setUp {
    [super setUp];
    [TestCapture reset];
    [MLRouter resetRouter]; // 清动态路由 + 白名单 + 校验器 + 兜底
}

#pragma mark - 1. 冷启动时序（路由请求先于模块加载）

/// 外部 deeplink 冷启动的致命时序：路由请求到达时 loadModules 还没跑（或被 reset），
/// 模块自举的动态路由全部缺失 → 合法 URL 走 404。loadModules 之后必须自动恢复。
- (void)testColdStartOpenBeforeLoadModulesGoes404ThenLoadModulesRestores {
    // 模拟「模块尚未加载」的冷启动现场
    [MLRouterModuleManager reset];

    __block NSError *err = nil;
    __block BOOL fb = NO;
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
        fb = YES; err = e; return @"fb";
    }];

    id cold = MLRouter.create.build(@"mluser://user/total").open();
    XCTAssertTrue(fb, @"模块未加载时组件动态路由缺失，应走兜底而非静默 nil");
    XCTAssertEqual(err.code, 404, @"缺失原因应是 404（未命中），便于线上归因");
    XCTAssertEqualObjects(cold, @"fb");

    // 补上模块加载（AppDelegate 正常时序里 didFinishLaunching 的职责）
    [MLRouterModuleManager loadModules];
    id warm = MLRouter.create.build(@"mluser://user/total").open();
    XCTAssertEqualObjects(warm, @3, @"loadModules 后组件动态路由自动恢复，跨仓服务数据可达");
}

/// ensureRoutesLoaded 的幂等契约：调多少次都不应让路由表膨胀或退化
- (void)testEnsureRoutesLoadedIdempotentNoRouteTableGrowth {
    NSDictionary *before = [MLRouter exportRouteTable];
    NSUInteger pagesBefore = [(NSArray *)before[@"pages"] count];
    NSUInteger methodsBefore = [(NSArray *)before[@"methods"] count];

    for (int i = 0; i < 10; i++) [MLRouter ensureRoutesLoaded];

    NSDictionary *after = [MLRouter exportRouteTable];
    XCTAssertEqual([(NSArray *)after[@"pages"] count], pagesBefore, @"重复扫描不应让页面表膨胀");
    XCTAssertEqual([(NSArray *)after[@"methods"] count], methodsBefore, @"重复扫描不应让方法表膨胀");
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://method/add?a=1&b=2").open(), @3,
                          @"幂等扫描后路由能力不退化");
}

#pragma mark - 2. 可观测性：失败路径的错误码必须可区分

/// 线上排障的命脉：404（未命中）与 403（拦截器拒绝 / 白名单拦截）虽然只有两个码，
/// 但每条失败路径都必须产生**确定且正确**的码，不能混用也不能丢失。
- (void)testFailurePathsProduceDistinguishableErrorCodes {
    __block NSError *err = nil;
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
        err = e; return nil;
    }];

    // ① 未命中 → 404
    err = nil;
    MLRouter.create.build(@"mltest://no/such/route").open();
    XCTAssertEqual(err.code, 404, @"未命中应是 404");

    // ② 拦截器 reject → 403
    err = nil;
    MLRouter.create.build(@"mltest://blocked/by-interceptor").open(); // TestBlockingInterceptor 对含 blocked 的 URL reject
    XCTAssertEqual(err.code, 403, @"拦截器拒绝应是 403");

    // ③ 白名单拦截 → 403
    err = nil;
    [MLRouter setAllowedSchemes:[NSSet setWithObject:@"onlythisscheme"]];
    MLRouter.create.build(@"mltest://page/basic").open(); // scheme 不在白名单，且不含 "blocked"
    XCTAssertEqual(err.code, 403, @"白名单拦截应是 403");
}

#pragma mark - 3. 安全校验器优先级契约

/// setRouteValidator 文档契约：「最高优先级，覆盖上述两者」——
/// 校验器存在时应**整体接管**校验，白名单不再参与（哪怕是收紧方向）。
- (void)testValidatorTakesOverFromWhitelist {
    [MLRouter setAllowedURLPaths:[NSSet setWithObject:@"mltest://nomatch/"]]; // 若生效会拦掉一切
    [MLRouter setRouteValidator:^BOOL(NSURL *url) {
        return [url.scheme isEqualToString:@"mltest"]; // 校验器放行 mltest
    }];
    // 校验器放行 ⇒ 尽管路径白名单并不匹配，也必须可达（证明白名单被接管而非叠加）
    id ret = MLRouter.create.build(@"mltest://page/basic").open();
    XCTAssertEqualObjects(ret, @(YES), @"校验器存在时应接管白名单，放行的路由必须可达");
}

#pragma mark - 4. 命名空间冲突契约（动态 vs 静态 vs 后注册）

/// 宿主 / 第三方运行时注册的动态路由与编译期静态段撞 URL：
/// 静态段必须赢（文档契约「动态路由优先级低于编译期静态段」）。
/// 这正是「SDK 被嵌进宿主、宿主乱注册同 URL」时的行为锚点。
- (void)testDynamicRouteLosesToStaticSection {
    [MLRouter registerRoute:@"mltest://page/basic"
                    handler:^id _Nullable(NSDictionary * _Nonnull p, MLRouterRequest * _Nonnull r) {
        return @"dynamic-marker";
    }];
    // 页面 present / completion 都在主队列异步完成 —— 必须用 expectation 等，不能同步断言
    __block BOOL sawStaticVC = NO;
    XCTestExpectation *exp = [self expectationWithDescription:@"static-page-vc"];
    id ret = MLRouter.create.build(@"mltest://page/basic")
        .withCompletion(^(id result) {
            sawStaticVC = [result isKindOfClass:[TestRouteViewController class]];
            [exp fulfill];
        }).open();
    XCTAssertEqualObjects(ret, @(YES), @"静态段命中 ⇒ 页面路由返回 @(YES)，不是动态 handler 的标记值");
    XCTAssertFalse([ret isKindOfClass:[NSString class]], @"绝不能把动态 handler 的返回值透出来");
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertTrue(sawStaticVC, @"命中的应是静态注册的页面实例");

    // 反注册动态路由不得伤及静态段
    [MLRouter unregisterRoute:@"mltest://page/basic"];
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://page/basic").open(), @(YES),
                          @"反注册动态路由后静态段仍可达");
}

/// 同为动态路由时：后注册覆盖先注册（last-wins，与静态段 dup 宏语义对齐）
- (void)testDynamicRouteLaterRegistrationWins {
    [MLRouter registerRoute:@"mltest://dyn/conflict" handler:^id _Nullable(NSDictionary *p, MLRouterRequest *r) {
        return @"v1";
    }];
    [MLRouter registerRoute:@"mltest://dyn/conflict" handler:^id _Nullable(NSDictionary *p, MLRouterRequest *r) {
        return @"v2";
    }];
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://dyn/conflict").open(), @"v2",
                          @"动态路由重复注册应 last-wins");
    [MLRouter unregisterRoute:@"mltest://dyn/conflict"];
    XCTAssertNil(MLRouter.create.build(@"mltest://dyn/conflict").open(), @"反注册后不再命中（无兜底 → nil）");
}

#pragma mark - 5. 降级链路的数据通道

/// 兜底 handler 返回业务数据（非 VC）时：结果必须同时到达 open() 返回值与 completion 两条通道
- (void)testFallbackDataReachesCompletionChannel {
    __block id completed = nil;
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
        return @{@"degraded": @YES};
    }];
    id ret = MLRouter.create.build(@"mltest://no/such/route2")
        .withCompletion(^(id result) { completed = result; })
        .open();
    XCTAssertEqualObjects(ret, (id)@{@"degraded": @YES}, @"open() 返回值应携带兜底数据");
    XCTAssertEqualObjects(completed, (id)@{@"degraded": @YES}, @"completion 通道也应收到兜底数据");
}

#pragma mark - 6. 契约快照（防文档腐烂：路由表被意外增删时立即红）

/// 钉住测试宿主二进制里**编译期静态段**的全量关键 URL。
/// 任何人删除 / 改名一个测试段注册，这条测试会红并逼着他同步文档 —— 路由表就是对外 API。
- (void)testContractSnapshotPinnedStaticRoutes {
    // 模块实例断言要求 loadModules 已跑过（其他测试类可能 reset 过模块）——本测试自给自足
    [MLRouterModuleManager loadModules];
    NSDictionary *table = [MLRouter exportRouteTable];
    NSArray *pages = table[@"pages"];
    NSArray *methods = table[@"methods"];
    NSArray *views = table[@"views"];
    NSArray *wildcards = table[@"wildcards"];   // 存的是通配符的**正则串**，不是原始 URL
    NSDictionary *redirects = table[@"redirects"]; // from → to 字典，key 是源 URL

    NSArray<NSString *> *pinnedPages = @[
        @"mltest://page/basic", @"mltest://page/param", @"mltest://page/typed",
        @"mltest://page/alltypes", @"mltest://page/throwinginit",
    ];
    for (NSString *p in pinnedPages) {
        XCTAssertTrue([pages containsObject:p], @"契约快照缺页面路由：%@", p);
    }
    // 通配符页面在 wildcards 键下（正则串形式）
    __block BOOL sawWild = NO, sawGreedy = NO;
    for (NSString *pattern in wildcards) {
        if ([pattern containsString:@"page/wild"]) sawWild = YES;
        if ([pattern containsString:@"page/greedy"]) sawGreedy = YES;
    }
    XCTAssertTrue(sawWild, @"契约快缺通配符页面（wildcards 正则）");
    XCTAssertTrue(sawGreedy, @"契约快缺贪婪通配符页面（wildcards 正则）");
    NSArray<NSString *> *pinnedMethods = @[
        @"mltest://method/add", @"mltest://method/async", @"mltest://method/object",
        @"mltest://method/newobject", @"mltest://method/noarg", @"mltest://method/throw",
        @"mltest://method/echo",
    ];
    for (NSString *m in pinnedMethods) {
        XCTAssertTrue([methods containsObject:m], @"契约快照缺方法路由：%@", m);
    }
    XCTAssertTrue([views containsObject:@"mltest://view/badge"], @"契约快照缺视图路由");
    // redirects 是 from→to 字典：按 key 断言源 URL
    XCTAssertEqualObjects(redirects[@"mltest://r1"], @"mltest://r2", @"契约快照缺重定向 r1→r2");
    XCTAssertEqualObjects(redirects[@"mltest://redirq"], @"mltest://method/echo", @"契约快照缺重定向 redirq→echo");
    XCTAssertEqualObjects(redirects[@"mltest://over/4"], @"mltest://over/5", @"契约快照缺深重定向链头");
    XCTAssertEqualObjects(redirects[@"mltest://cycle1"], @"mltest://cycle2", @"契约快照缺重定向环");
    // 组件仓段注册（跨仓锚点）
    XCTAssertTrue([pages containsObject:@"mlcomp://cart/index"], @"组件页面注册应在快照内");
    XCTAssertTrue([pages containsObject:@"mluser://user/index"], @"组件页面注册应在快照内");

    // 组件模块永在（编译进宿主）
    NSArray *modules = table[@"modules"];
    XCTAssertTrue([modules containsObject:@"CartComponentModule"], @"Cart 模块应在表内");
    XCTAssertTrue([modules containsObject:@"UserComponentModule"], @"User 模块应在表内");
}

/// 导出的确定性：同一状态下连导两次，页/方法/视图计数必须完全一致（供 CI diff 用）
- (void)testExportRouteTableDeterministicCounts {
    NSDictionary *a = [MLRouter exportRouteTable];
    NSDictionary *b = [MLRouter exportRouteTable];
    XCTAssertEqual([(NSArray *)a[@"pages"] count], [(NSArray *)b[@"pages"] count]);
    XCTAssertEqual([(NSArray *)a[@"methods"] count], [(NSArray *)b[@"methods"] count]);
    XCTAssertEqual([(NSArray *)a[@"views"] count], [(NSArray *)b[@"views"] count]);
}

#pragma mark - 8. 敏感页鉴权切面（外部入口防线）

/// 鉴权拦截器对敏感路由的准入控制：缺 token 必须 reject 且**不得触达路由目标**。
/// reject 的原始 error（domain/code）要原样穿透给兜底 —— 这是线上区分
/// 「没登录被拦」和「路由不存在」的唯一线索。
- (void)testSecureRouteWithoutTokenRejectedByAuthInterceptor {
    __block BOOL dynamicHandlerReached = NO;
    [MLRouter registerRoute:@"mltest://secure/data"
                    handler:^id _Nullable(NSDictionary * _Nonnull p, MLRouterRequest * _Nonnull r) {
        dynamicHandlerReached = YES;
        return @"should-not-happen";
    }];
    __block NSError *err = nil;
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
        err = e; return @"fb";
    }];

    id ret = MLRouter.create.build(@"mltest://secure/data").open();
    XCTAssertEqualObjects(ret, @"fb", @"缺 token 应走兜底");
    XCTAssertEqual(err.code, 403, @"鉴权失败应是 403");
    XCTAssertEqualObjects(err.domain, @"MLRouterTest", @"应透传鉴权拦截器的原始 error（域不变）");
    XCTAssertFalse(dynamicHandlerReached, @"鉴权失败绝不能触达动态 handler");
}

/// 合法 token 放行：鉴权切面通过后路由目标正常执行
- (void)testSecureRouteWithValidTokenReachesTarget {
    __block BOOL dynamicHandlerReached = NO;
    [MLRouter registerRoute:@"mltest://secure/data"
                    handler:^id _Nullable(NSDictionary * _Nonnull p, MLRouterRequest * _Nonnull r) {
        dynamicHandlerReached = YES;
        return @"auth-ok";
    }];
    id ret = MLRouter.create.build(@"mltest://secure/data?token=secret-token").open();
    XCTAssertTrue(dynamicHandlerReached, @"合法 token 应放行到路由目标");
    XCTAssertEqualObjects(ret, @"auth-ok");
}

#pragma mark - 9. 失败可诊断性（错误消息必须携带归因上下文）

/// 降级链优先级契约：handler 与 VC class 同时设置时 **handler 必须赢**，
/// 且 VC class 不得被实例化 —— 两级兜底并存时的行为必须有唯一确定答案。
- (void)testFallbackHandlerTakesPriorityOverFallbackVCClass {
    [TestCapture reset];
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
        return @"handler-wins";
    }];
    [MLRouter setFallbackViewControllerClass:[TestParamViewController class]];

    id ret = MLRouter.create.build(@"mltest://unknown/priority").open();
    XCTAssertEqualObjects(ret, @"handler-wins", @"两级兜底并存时 handler 必须赢");
    XCTAssertEqualObjects([TestCapture lastVC], nil,
                          @"handler 赢的时候绝不该实例化 VC class 兜底页");
}

/// 线上排障全靠这些消息：错误文案是**契约**，改文案 = 改监控规则，必须钉住。
- (void)testErrorMessagesCarryAttributionContext {
    __block NSError *err = nil;
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
        err = e; return nil;
    }];

    // ① 404：消息里必须能直接看到是哪条 URL 挂的
    err = nil;
    MLRouter.create.build(@"mltest://no/such/route").open();
    XCTAssertTrue([err.localizedDescription containsString:@"mltest://no/such/route"],
                  @"404 消息必须携带原始 URL：%@", err.localizedDescription);

    // ② 拦截器拒绝：拦截器自带的 error **原样穿透**（domain/code 不被框架改写）——
    //    通用文案只在拦截器未传 error 时生成。穿透本身就是归因契约。
    err = nil;
    MLRouter.create.build(@"mltest://blocked/by-interceptor").open();
    XCTAssertEqualObjects(err.domain, @"MLRouterTest", @"拦截器自定义 error 域应原样穿透");
    XCTAssertEqual(err.code, 403, @"拦截器拒绝码应原样穿透");

    // ③ 白名单拦截：消息必须说明是被安全策略拦下
    err = nil;
    [MLRouter setAllowedSchemes:[NSSet setWithObject:@"onlythisscheme"]];
    MLRouter.create.build(@"mltest://page/basic").open();
    XCTAssertTrue([err.localizedDescription containsString:@"whitelist"] ||
                  [err.localizedDescription containsString:@"validator"],
                  @"白名单拦截消息必须可归因：%@", err.localizedDescription);
}

#pragma mark - 7. Fuzz：1000 条随机 URL 不崩，框架存活

/// 与手写畸形样本的本质区别：不枚举，只断言「无论输入什么都不得崩」。
/// 随机源固定种子 ⇒ 失败可复现。覆盖字符集含 URL 元字符 / 控制符 / Emoji / 超长段。
- (void)testFuzz1000RandomURLsNoCrashRouterSurvives {
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
        return nil; // 静默兜底：fuzz 只关心不崩，不关心命中
    }];

    NSString *charset = @"abcXYZ019-._~:/?#[]@!$&'()*+,;=%<> \"\n😀🚀";
    srand48(20260918); // 固定种子：任何失败都可复现
    NSUInteger opened = 0;
    for (int i = 0; i < 1000; i++) {
        NSUInteger len = (NSUInteger)(drand48() * 80);
        NSMutableString *s = [NSMutableString string];
        for (NSUInteger k = 0; k < len; k++) {
            unichar c = [charset characterAtIndex:(NSUInteger)(drand48() * charset.length)];
            [s appendFormat:@"%C", c];
        }
        @try {
            MLRouter.create.build(s).open();
            opened++;
        } @catch (NSException *exception) {
            // 契约：fuzz 输入绝不允许以 NSException 的形式炸出框架 —— 直接判失败
            XCTFail(@"fuzz URL 第 %d 条引发异常：%@（URL: %@）", i, exception.name, s);
            return;
        }
    }
    XCTAssertEqual(opened, (NSUInteger)1000, @"1000 条 fuzz URL 应全部被安全受理（含返回 nil）");

    // 存活检查：fuzz 之后框架必须完好如初
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://method/add?a=1&b=2").open(), @3,
                          @"fuzz 之后路由能力不得退化");
    XCTAssertEqualObjects(MLRouter.create.build(@"mltest://page/basic").open(), @(YES),
                          @"fuzz 之后页面路由不得退化");
}

#pragma mark - 10. PII 日志脱敏（合规红线）

/// 默认脱敏键集：token / password / phone 等值必须被替换，非敏感参数原样保留
- (void)testRedactedURLStringDefaults {
    NSString *raw = @"mltest://page/x?token=super-secret-token&phone=13800138000&keep=visible";
    NSString *red = [MLRouter redactedURLString:raw];
    XCTAssertFalse([red containsString:@"super-secret-token"], @"token 值必须被脱敏：%@", red);
    XCTAssertFalse([red containsString:@"13800138000"], @"手机号必须被脱敏：%@", red);
    XCTAssertTrue([red containsString:@"REDACTED"], @"脱敏占位符应存在：%@", red);
    XCTAssertTrue([red containsString:@"keep=visible"], @"非敏感参数必须原样保留：%@", red);
    XCTAssertTrue([red containsString:@"mltest://page/x"], @"scheme/host/path 必须原样保留：%@", red);

    // 无 query 的 URL 原样返回
    XCTAssertEqualObjects([MLRouter redactedURLString:@"mltest://page/basic"], @"mltest://page/basic");
}

/// 自定义键集**整体替换**默认集；resetGovernance 恢复默认
- (void)testCustomRedactedKeysAndResetRestoresDefaults {
    [MLRouter setRedactedQueryKeys:[NSSet setWithObject:@"sessionid"]];
    NSString *red = [MLRouter redactedURLString:@"mltest://x?sessionid=abc123&token=keep-me-now"];
    XCTAssertFalse([red containsString:@"abc123"], @"自定义键必须脱敏：%@", red);
    XCTAssertTrue([red containsString:@"token=keep-me-now"], @"自定义集替换默认集（token 不再脱敏）：%@", red);

    // reset 恢复默认集
    [MLRouter resetGovernance];
    NSString *after = [MLRouter redactedURLString:@"mltest://x?sessionid=abc123&token=t2"];
    XCTAssertTrue([after containsString:@"sessionid=abc123"], @"reset 后自定义集应清空：%@", after);
    XCTAssertFalse([after containsString:@"=t2"], @"reset 后默认集应回归（token 再度脱敏）：%@", after);
}

/// 终极验证：真实触发 404 诊断日志，重定向 stderr 捕获 NSLog 输出，
/// 断言日志里只有 `REDACTED` 而没有原始敏感值 —— 这是合规审计直接可用的证据。
- (void)testDiagnosticLogDoesNotEmitRawSensitiveValues {
    int savedErr = dup(STDERR_FILENO);
    int pipeFD[2];
    XCTAssertEqual(pipe(pipeFD), 0, @"创建捕获管道失败");
    dup2(pipeFD[1], STDERR_FILENO);

    MLRouter.create.build(@"mltest://no/such/route?token=raw-secret-value&user=bob").open();

    // 恢复 stderr 后再读管道，避免 NSLog 继续写丢失
    dup2(savedErr, STDERR_FILENO);
    close(savedErr);
    close(pipeFD[1]);
    NSMutableString *captured = [NSMutableString string];
    char buf[1024];
    ssize_t n;
    while ((n = read(pipeFD[0], buf, sizeof(buf))) > 0) {
        // 必须按 UTF-8 显式解码：appendFormat 的 %s 对编码的解释不可靠（实测中文变乱码导致匹配失败）
        NSString *chunk = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding];
        if (chunk) [captured appendString:chunk];
        if (captured.length > 64 * 1024) break;   // 防御性上限
    }
    close(pipeFD[0]);

    NSString *dump = captured.length > 600 ? [[captured substringToIndex:600] stringByAppendingString:@"..."] : captured;
    XCTAssertTrue([captured containsString:@"404 灾难级诊断警报"], @"应捕获到 404 诊断日志（长度 %lu）：\n%@", (unsigned long)captured.length, dump);
    XCTAssertTrue([captured containsString:@"REDACTED"], @"日志应输出脱敏占位符：\n%@", dump);
    XCTAssertFalse([captured containsString:@"raw-secret-value"], @"日志绝不能出现原始 token 值：\n%@", dump);
    XCTAssertTrue([captured containsString:@"user=bob"], @"非敏感参数照常输出（可归因）：\n%@", dump);
}

#pragma mark - 11. 乱序操作不变量（测试隔离 / 随机顺序稳定性）

/// 固定种子的随机操作序列：动态路由注册/反注册 + 白名单开关随机交错，
/// **每一步之后**用本地状态推演出两条不变量的期望值并断言——
/// 无论操作以什么顺序到达，框架的可观测行为必须与状态推演完全一致。
/// 这是「跨场景副作用 / 随机顺序执行」元维度的落地：任何一条被前序操作污染，
/// 期望值与实际值立刻偏离。
- (void)testRandomizedOperationOrdersKeepRoutingInvariants {
    __block id fallbackRet = nil;   // nil = 无兜底
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
        return fallbackRet;
    }];

    NSString *const dynA = @"mltest://dyn/invariant-a";
    NSString *const dynB = @"mltest://dyn/invariant-b";

    for (unsigned seed = 1; seed <= 3; seed++) {
        // ⚠️ 每个 seed 开始前必须把框架状态真正归零：上一 seed 的动态路由/白名单会残留，
        // 本地 hasA/hasB/whitelistOn 归零而框架没归零，推演就会全盘错位（实测踩过）。
        // resetRouter 顺带清掉兜底，重装即可。
        [MLRouter resetRouter];
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
            return fallbackRet;
        }];
        srand48(seed);
        BOOL hasA = NO, hasB = NO, whitelistOn = NO;
        NSArray<NSString *> *ops = @[@"regA", @"regB", @"unregA", @"unregB",
                                     @"whitelistOn", @"whitelistOff", @"noop"];
        for (int round = 0; round < 30; round++) {
            NSString *op = ops[(NSUInteger)(drand48() * ops.count)];

            if ([op isEqualToString:@"regA"]) {
                [MLRouter registerRoute:dynA handler:^id _Nullable(NSDictionary *p, MLRouterRequest *r) {
                    return @"A";
                }];
                hasA = YES;
            } else if ([op isEqualToString:@"regB"]) {
                [MLRouter registerRoute:dynB handler:^id _Nullable(NSDictionary *p, MLRouterRequest *r) {
                    return @"B";
                }];
                hasB = YES;
            } else if ([op isEqualToString:@"unregA"]) {
                [MLRouter unregisterRoute:dynA];
                hasA = NO;
            } else if ([op isEqualToString:@"unregB"]) {
                [MLRouter unregisterRoute:dynB];
                hasB = NO;
            } else if ([op isEqualToString:@"whitelistOn"]) {
                // 故意放行一个「不存在」的 scheme：开启后 mltest 全被 403 拦截
                [MLRouter setAllowedSchemes:[NSSet setWithObject:@"blockall-scheme"]];
                whitelistOn = YES;
            } else if ([op isEqualToString:@"whitelistOff"]) {
                [MLRouter setAllowedSchemes:nil];
                whitelistOn = NO;
            }

            // 不变量 ①：静态锚点路由。白名单开 → 403 兜底；关 → 正常返回 3
            id anchor = MLRouter.create.build(@"mltest://method/add?a=1&b=2").open();
            XCTAssertEqualObjects(anchor, whitelistOn ? fallbackRet : (id)@3,
                                  @"seed=%u round=%d op=%@ 后静态锚点偏离", seed, round, op);
            // 不变量 ②：动态路由 A 的可达性与注册状态一致
            id a = MLRouter.create.build(dynA).open();
            id expectedA = whitelistOn ? fallbackRet : (hasA ? (id)@"A" : fallbackRet);
            XCTAssertEqualObjects(a, expectedA,
                                  @"seed=%u round=%d op=%@ 后动态路由 A 偏离（hasA=%d）", seed, round, op, hasA);
            // 不变量 ③：动态路由 B 同理
            id b = MLRouter.create.build(dynB).open();
            id expectedB = whitelistOn ? fallbackRet : (hasB ? (id)@"B" : fallbackRet);
            XCTAssertEqualObjects(b, expectedB,
                                  @"seed=%u round=%d op=%@ 后动态路由 B 偏离（hasB=%d）", seed, round, op, hasB);
        }
    }
    // 收尾：白名单关掉，动态路由清掉，不留跨测试污染
    [MLRouter setAllowedSchemes:nil];
    [MLRouter unregisterRoute:dynA];
    [MLRouter unregisterRoute:dynB];
}

@end
