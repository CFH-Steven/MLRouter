// MLRouterGovernanceTests.m
// 治理层：动态路由 / 安全白名单 / 降级兜底 / 路由表导出 / reset / 主线程约束。
#import <XCTest/XCTest.h>
#import "MLRouterTestSupport.h"

@interface MLRouterGovernanceTests : XCTestCase
@end

@implementation MLRouterGovernanceTests

- (void)setUp {
    [super setUp];
    [TestCapture reset];
    [MLRouter resetRouter]; // 每个用例重置动态路由/白名单/兜底
}

#pragma mark - 动态路由

- (void)testDynamicRouteExact {
    [MLRouter registerRoute:@"mltest://dyn/hello"
                    handler:^id _Nullable(NSDictionary *params, MLRouterRequest *request) {
        return @"dyn-ok";
    }];
    id ret = MLRouter.create.build(@"mltest://dyn/hello").open();
    XCTAssertEqualObjects(ret, @"dyn-ok", @"动态精确路由应命中 handler");
}

- (void)testDynamicRouteWildcardParamExtraction {
    [MLRouter registerRoute:@"mltest://dyn/*/detail"
                    handler:^id _Nullable(NSDictionary *params, MLRouterRequest *request) {
        return params[@"wildcard_1"]; // 单级 * 捕获
    }];
    id ret = MLRouter.create.build(@"mltest://dyn/abc/detail").open();
    XCTAssertEqualObjects(ret, @"abc", @"通配符捕获参数 wildcard_1 应被提取");
}

- (void)testDynamicRouteDoubleWildcardGreedy {
    [MLRouter registerRoute:@"mltest://deep/**/end"
                    handler:^id _Nullable(NSDictionary *params, MLRouterRequest *request) {
        return params[@"wildcard_1"];
    }];
    id ret = MLRouter.create.build(@"mltest://deep/a/b/c/end").open();
    XCTAssertEqualObjects(ret, @"a/b/c", @"** 应贪婪捕获多级路径");
}

- (void)testDynamicRouteUnregister {
    [MLRouter registerRoute:@"mltest://dyn/temp" handler:^id(NSDictionary *p, MLRouterRequest *r){ return @"x"; }];
    [MLRouter unregisterRoute:@"mltest://dyn/temp"];
    // 反注册后静态段也未命中 -> 404 无兜底 -> nil
    id ret = MLRouter.create.build(@"mltest://dyn/temp").open();
    XCTAssertNil(ret, @"反注册后动态路由不应再命中");
}

- (void)testDynamicRouteReturnsViewController {
    UIViewController * (^handler)(NSDictionary *, MLRouterRequest *) = ^UIViewController *(NSDictionary *p, MLRouterRequest *r) {
        return [[TestRouteViewController alloc] init];
    };
    [MLRouter registerRoute:@"mltest://dyn/vc" handler:handler];
    id ret = MLRouter.create.build(@"mltest://dyn/vc").open();
    XCTAssertEqualObjects(ret, @(YES), @"动态路由返回 VC 应自动 present 并返回 @(YES)");
}

#pragma mark - 安全白名单

- (void)testWhitelistSchemeBlocks {
    [MLRouter setAllowedSchemes:[NSSet setWithObject:@"app"]]; // 只允许 app://
    __block BOOL fbCalled = NO;
    [MLRouter setFallbackHandler:^id(MLRouterRequest *req, NSError *err) {
        fbCalled = YES;
        return @"fallback";
    }];
    id ret = MLRouter.create.build(@"mltest://page/basic").open(); // scheme mltest 不在白名单
    XCTAssertTrue(fbCalled, @"白名单拦截后应走兜底");
    XCTAssertEqualObjects(ret, @"fallback");
}

- (void)testWhitelistPathPrefix {
    [MLRouter setAllowedURLPaths:[NSSet setWithObject:@"mltest://safe/"]];
    __block BOOL fbCalled = NO;
    [MLRouter setFallbackHandler:^id(MLRouterRequest *req, NSError *err) { fbCalled = YES; return nil; }];
    id ret = MLRouter.create.build(@"mltest://other/x").open(); // 非 safe 前缀
    XCTAssertTrue(fbCalled, @"路径不匹配白名单应走兜底");
    XCTAssertNil(ret);
}

- (void)testCustomValidatorBlocks {
    [MLRouter setRouteValidator:^BOOL(NSURL *url) {
        return ![url.host isEqualToString:@"blockedhost"];
    }];
    __block BOOL fbCalled = NO;
    [MLRouter setFallbackHandler:^id(MLRouterRequest *req, NSError *err) { fbCalled = YES; return nil; }];
    id ret = MLRouter.create.build(@"mltest://blockedhost/x").open();
    XCTAssertTrue(fbCalled);
    XCTAssertNil(ret);
}

#pragma mark - 降级兜底

- (void)testFallbackHandlerOn404 {
    [MLRouter setFallbackHandler:^id(MLRouterRequest *req, NSError *err) {
        [TestCapture setFallbackCalled:YES];
        return @"404-fallback";
    }];
    id ret = MLRouter.create.build(@"mltest://unknown/route").open();
    XCTAssertTrue([TestCapture fallbackCalled], @"404 应触发兜底 handler");
    XCTAssertEqualObjects(ret, @"404-fallback");
}

- (void)testFallbackViewController {
    [MLRouter setFallbackViewControllerClass:[TestParamViewController class]];
    MLRouter.create.build(@"mltest://unknown/route").open();
    XCTAssertTrue([[TestCapture lastVC] isKindOfClass:[TestParamViewController class]], @"应 present 兜底 VC");
}

#pragma mark - 导出 / 重置

- (void)testExportRouteTableStructure {
    NSDictionary *table = [MLRouter exportRouteTable];
    XCTAssertNotNil(table[@"pages"]);
    XCTAssertNotNil(table[@"methods"]);
    XCTAssertNotNil(table[@"views"]);
    XCTAssertNotNil(table[@"dynamic"]);
    XCTAssertNotNil(table[@"wildcards"]);
    XCTAssertNotNil(table[@"redirects"]);
    XCTAssertNotNil(table[@"services"]);
    XCTAssertNotNil(table[@"modules"]);
    XCTAssertTrue([table[@"pages"] containsObject:@"mltest://page/basic"], @"导出表应含已注册页面");
}

- (void)testResetRouterClearsDynamicAndWhitelist {
    [MLRouter registerRoute:@"mltest://dyn/x" handler:^id(NSDictionary *p, MLRouterRequest *r){ return @"x"; }];
    [MLRouter setAllowedSchemes:[NSSet setWithObject:@"app"]];
    [MLRouter resetRouter];

    // 动态路由已清空
    id dynRet = MLRouter.create.build(@"mltest://dyn/x").open();
    XCTAssertNil(dynRet, @"reset 后动态路由应清空");

    // 白名单已清空：之前被拦截的 scheme 现在放行（命中页面路由）
    id pageRet = MLRouter.create.build(@"mltest://page/basic").open();
    XCTAssertEqualObjects(pageRet, @(YES), @"reset 后白名单应清空，页面路由可命中");
}

#pragma mark - 兜底返回值语义（P0 回归：「open 返回控制器」困惑的来源）

- (void)testFallbackHandlerReturningVCPresentsItAndReturnsYES {
    // 回归：兜底 handler 返回 UIViewController 时必须自动 present，并让 open() 返回 @(YES)。
    // 旧实现只把 VC 当返回值丢出去、从不 present —— 于是表现为「未命中路由时页面毫无反馈，
    // 而 open() 返回一个 UIViewController」，这正是「用 open 打开路由，返回的是控制器」这一
    // 困惑的真实来源（其实说明该 URL 没命中、走的是兜底）。
    [TestCapture reset];
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest *request, NSError *error) {
        return [[TestParamViewController alloc] init];
    }];
    id ret = MLRouter.create.build(@"mltest://unknown/fallback/vc").open();

    XCTAssertEqualObjects(ret, @(YES), @"兜底 handler 返回 VC 应 present 后返回 @(YES)");
    XCTAssertFalse([ret isKindOfClass:[UIViewController class]],
                   @"open() 永远不应把 UIViewController 当返回值丢出来");
    XCTAssertTrue([[TestCapture lastVC] isKindOfClass:[TestParamViewController class]],
                  @"兜底 VC 应被真正 present");
}

- (void)testFallbackPageCarriesRequestContext {
    // 兜底页最需要的上下文是「哪条 URL 挂的、为什么挂」，否则线上排查只能靠猜
    [TestCapture reset];
    [MLRouter setFallbackViewControllerClass:[TestParamViewController class]];
    MLRouter.create.build(@"mltest://unknown/ctx").open();

    NSDictionary *ctx = [TestCapture lastParams];
    XCTAssertEqualObjects(ctx[@"ml_fallbackURL"], @"mltest://unknown/ctx", @"兜底页应携带原始 URL");
    XCTAssertEqualObjects(ctx[@"ml_fallbackErrorCode"], @(404), @"兜底页应携带 404 错误码");
}

#pragma mark - 主线程约束

- (void)testPagePresentCompletesOnMainThread {
    XCTestExpectation *exp = [self expectationWithDescription:@"present-on-main"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        MLRouter.create.build(@"mltest://page/basic")
            .withCompletion(^(id result) {
                XCTAssertTrue([NSThread isMainThread], @"页面 present 的 completion 应在主线程");
                [exp fulfill];
            }).open();
    });
    [self waitForExpectationsWithTimeout:5 handler:nil];
}

@end
