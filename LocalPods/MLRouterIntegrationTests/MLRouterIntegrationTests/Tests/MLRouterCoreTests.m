// MLRouterCoreTests.m
// 核心路由场景：页面/方法/通配符/重定向/拦截器/参数映射/边界。
#import <XCTest/XCTest.h>
#import "MLRouterTestSupport.h"

@interface MLRouterCoreTests : XCTestCase
@end

@implementation MLRouterCoreTests

- (void)setUp {
    [super setUp];
    [TestCapture reset];
    [MLRouter resetRouter]; // 清动态路由/白名单/兜底；页面/方法段注册常驻，不受影响
}

#pragma mark - 页面路由

- (void)testPageRouteReturnsTrue {
    id ret = MLRouter.create.build(@"mltest://page/basic").open();
    XCTAssertEqualObjects(ret, @(YES), @"页面路由应返回 @(YES)");
}

- (void)testStaticWildcardPageMatches {
    // 命中编译期静态通配符页面 mltest://page/wild/*
    id ret = MLRouter.create.build(@"mltest://page/wild/123").open();
    XCTAssertEqualObjects(ret, @(YES), @"静态单级通配符页面应命中");
}

#pragma mark - 方法路由

- (void)testMethodRouteSyncReturnsValue {
    id ret = MLRouter.create.build(@"mltest://method/add").withParam(@"a", @1).withParam(@"b", @2).open();
    XCTAssertEqualObjects(ret, @3, @"1+2 应返回 3");
}

- (void)testMethodRouteQueryParamParsing {
    // query 参数应被解析进 params
    id ret = MLRouter.create.build(@"mltest://method/add?a=3&b=4").open();
    XCTAssertEqualObjects(ret, @7, @"query 3+4 应返回 7");
}

/// 【P0 回归】方法路由返回值所有权必须按 ARC 方法家族区分 +1 / +0。
///
/// 现场：这条用例原先会让测试进程**直接崩溃**，且崩溃栈落在
/// `AutoreleasePoolPage::releaseUntil` → `objc_release`（`EXC_BAD_ACCESS`），
/// 看上去与路由毫无关系 —— 实际根因是框架用 NSInvocation 拿裸指针后，
/// 不分家族一律 `__bridge_transfer` 抢所有权：对于 +0（已自动释放）的返回值，
/// 等于多抢一份，autorelease pool 排空时对已释放对象二次 release 而崩溃。
- (void)testMethodRouteReturnObjectOwnership_P0 {
    // ① 非保留家族（makeObjectWithParams:）→ 被调方返回 +0，框架必须认领而非抢夺
    id autoReleased = MLRouter.create.build(@"mltest://method/object").open();
    XCTAssertNotNil(autoReleased, @"+0 家族返回值不应为 nil");
    XCTAssertTrue([autoReleased isKindOfClass:[NSObject class]], @"返回值应是 NSObject 实例");
    // 再次访问验证未被过早释放（旧实现在这里之后的池排空阶段崩溃）
    XCTAssertEqualObjects([autoReleased description], [autoReleased description]);

    // ② 保留家族（new 开头）→ 被调方返回 +1，框架必须接管（否则泄漏，且不应崩溃）
    id retained = MLRouter.create.build(@"mltest://method/newobject").open();
    XCTAssertNotNil(retained, @"+1 家族返回值不应为 nil（若泄漏仍可用，但所有权必须被正确接管）");
    XCTAssertTrue([retained isKindOfClass:[NSObject class]], @"返回值应是 NSObject 实例");
    XCTAssertEqualObjects([retained description], [retained description]);

    // ③ 两条路径都走一遍后，autorelease pool 排空时不得崩溃
    //    （本用例能跑到下一行走完，才是对本次修复的真正验证）
    XCTAssertNotEqual(autoReleased, retained, @"两次调用应是不同实例");
}

- (void)testMethodRouteWithBlockCompletion {
    // 带 block 参数的方法路由：结果由方法内部的 completion block 异步回传
    XCTestExpectation *exp = [self expectationWithDescription:@"async method"];
    MLRouter.create.build(@"mltest://method/async")
        .withParam(@"a", @10).withParam(@"b", @20)
        .withCompletion(^(id result) {
            XCTAssertEqualObjects(result, @30, @"10+20 应返回 30");
            [exp fulfill];
        }).open();
    [self waitForExpectationsWithTimeout:3 handler:nil];
}

- (void)testMethodRouteSignatureInvalidReturnsNil {
    // selector 无参数（numberOfArguments<3），框架应拒绝并返回 nil（P0 签名校验）
    id ret = MLRouter.create.build(@"mltest://method/noarg").open();
    XCTAssertNil(ret, @"签名不符的方法路由应返回 nil 而非崩溃");
}

#pragma mark - 重定向链

- (void)testRedirectChainResolvesToFinalTarget {
    // mltest://r1 -> r2 -> r3（方法路由返回 @"redirected"），验证多级重定向 + 防环上限
    id ret = MLRouter.create.build(@"mltest://r1").open();
    XCTAssertEqualObjects(ret, @"redirected", @"重定向链应解析到终点 r3");
}

#pragma mark - 拦截器

- (void)testInterceptorRejectBlocksRoute {
    // URL 含 "blocked" -> TestBlockingInterceptor 拒绝，目标不应执行，返回 nil
    id ret = MLRouter.create.build(@"mltest://method/add?track=blocked").open();
    XCTAssertNil(ret, @"被拦截器拒绝的路由应返回 nil");
}

- (void)testInterceptorOrderByPriority {
    // 优先级 10 的 A 应先于 30 的 B 执行（数字小优先）
    [TestCapture reset]; // 清掉历史顺序，只测本次
    MLRouter.create.build(@"mltest://method/add?a=1&b=1").open();
    NSArray *log = [TestCapture.orderLog copy];
    XCTAssertTrue(log.count >= 2, @"至少应记录两个拦截器");
    XCTAssertEqualObjects(log.firstObject, @"TestOrderInterceptor", @"优先级 10 应最先执行");
    XCTAssertEqualObjects(log[1], @"TestOrderInterceptorB", @"优先级 30 应后执行");
}

#pragma mark - 参数映射

- (void)testParameterMappingToViewController {
    // 框架应把 withParam 的 name 设到 VC 的 name 属性，并把全量 params 写入 ml_routerParams
    MLRouter.create.build(@"mltest://page/param").withParam(@"name", @"tom").open();
    UIViewController *vc = [TestCapture lastVC];
    XCTAssertNotNil(vc, @"应记录被打开的 VC");
    XCTAssertTrue([vc isKindOfClass:[TestParamViewController class]]);
    XCTAssertEqualObjects([(TestParamViewController *)vc name], @"tom", @"name 属性应被参数映射赋值");
    XCTAssertEqualObjects([TestCapture lastParams][@"name"], @"tom", @"全量参数应写入 ml_routerParams");
}

#pragma mark - 边界

- (void)testInvalidURLReturnsNil {
    id ret = MLRouter.create.build(@"").open();
    XCTAssertNil(ret, @"空 URL 应返回 nil");
}

- (void)testUnknownRouteWithoutFallbackReturnsNil {
    // 未注册路由且无兜底 -> 返回 nil（而非崩溃）
    id ret = MLRouter.create.build(@"mltest://unknown/path/xyz").open();
    XCTAssertNil(ret, @"404 且无兜底应返回 nil");
}

@end
