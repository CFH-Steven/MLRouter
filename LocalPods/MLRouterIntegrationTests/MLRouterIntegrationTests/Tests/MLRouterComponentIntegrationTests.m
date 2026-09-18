// MLRouterComponentIntegrationTests.m
// 组件化/模块化「本地私有仓」集成测试。
//
// 被测对象是两个独立本地私有仓 pod：
//   - MLCartComponent：页面/方法/视图/拦截器/服务/模块 全段宏自注册
//   - MLUserComponent：跨仓消费 CartServiceProtocol + 跨仓模块依赖拓扑
// 测试只 import 各组件仓的公开头文件，验证「宿主零手动接线、dyld 扫描自动发现」的真实组件化路径。

#import <XCTest/XCTest.h>
#import <MLRouter/MLRouterHeader.h>
#import <MLRouter/MLRouterService.h>
#import <MLRouter/MLRouterModule.h>

#import <MLCartComponent/CartServiceProtocol.h>
#import <MLCartComponent/CartComponentModule.h>
#import <MLCartComponent/CartAuthInterceptor.h>
#import <MLCartComponent/CartBadgeView.h>

#import <MLUserComponent/UserComponentModule.h>

@interface MLRouterComponentIntegrationTests : XCTestCase
@end

@implementation MLRouterComponentIntegrationTests

+ (void)setUp {
    [super setUp];
    // 段扫描在 MLRouter +initialize 首次使用时自动执行；
    // 模块加载由 loadModules 触发（幂等），测试宿主 App 的 AppDelegate 不会调用，故此处补一次。
    [MLRouterModuleManager loadModules];
}

#pragma mark - 组件化：服务层（段宏自注册 → dyld 扫描发现）

- (void)testComponentServiceDiscoveredViaSectionMacro {
    id<CartServiceProtocol> svc = [MLRouterService serviceForProtocol:@protocol(CartServiceProtocol)];
    XCTAssertNotNil(svc, @"私有仓组件服务应经段宏自注册被自动发现");
    XCTAssertTrue([svc conformsToProtocol:@protocol(CartServiceProtocol)]);
    XCTAssertEqual([svc itemCount], 3, @"协议方法应正确响应");
    XCTAssertEqualObjects([svc componentName], @"CartComponent");
    XCTAssertTrue([[MLRouterService exportedServiceProtocols] containsObject:@"CartServiceProtocol"],
                  @"服务表导出应包含组件服务协议");
}

- (void)testServiceTableHasNoUnregisteredProtocol {
    id svc = [MLRouterService serviceForProtocol:@protocol(MLRouterModule)];
    XCTAssertNil(svc, @"未注册为服务的协议应返回 nil");
}

#pragma mark - 组件化：方法路由（同步返回 + 异步 completion）

- (void)testComponentMethodRouteSyncReturn {
    id ret = MLRouter.create.build(@"mlcomp://cart/total")
        .withParam(@"a", @2).withParam(@"b", @3)
        .open();
    XCTAssertEqualObjects(ret, @5, @"组件方法路由应返回段宏注册类方法的计算结果");
}

- (void)testComponentMethodRouteAsyncCompletion {
    XCTestExpectation *exp = [self expectationWithDescription:@"async completion"];
    MLRouter.create.build(@"mlcomp://cart/asyncSum")
        .withParam(@"a", @10).withParam(@"b", @20)
        .withCompletion(^(id _Nullable result) {
            XCTAssertEqualObjects(result, @30, @"异步方法路由应经 completion 回传结果");
            [exp fulfill];
        }).open();
    [self waitForExpectationsWithTimeout:3 handler:nil];
}

#pragma mark - 组件化：View 路由（返回视图实例）

- (void)testComponentViewRouteReturnsViewInstance {
    id ret = MLRouter.create.build(@"mlcomp://cart/badge")
        .withParam(@"badgeText", @"🛒 测试")
        .open();
    XCTAssertTrue([ret isKindOfClass:[CartBadgeView class]], @"View 路由应返回组件仓注册的视图实例");
    XCTAssertEqualObjects(((CartBadgeView *)ret).badgeText, @"🛒 测试", @"参数应映射到视图属性");
}

#pragma mark - 组件化：页面路由（段宏自注册 + present 转场）
//
// 【双通道契约】页面路由的两条结果通道承载不同语义，断言必须分别对准：
//   · open() 的同步返回值 = 受理信号，页面路由恒为 @(YES)，**永不返回 UIViewController**；
//   · withCompletion 的回调值 = 结果对象，页面路由传**被 present 的 VC 实例**。
// 这里两者都断言，把契约钉死 —— 历史上正是「兜底 VC 从 open() 漏出去」造成了
// 「用 open 打开路由却拿到一个控制器」的困惑。

- (void)testComponentPageRoutePresents {
    XCTestExpectation *exp = [self expectationWithDescription:@"page present completion"];
    id openRet = MLRouter.create.build(@"mlcomp://cart/index")
        .withParam(@"sourceTag", @"integration-test")
        .withCompletion(^(id _Nullable result) {
            XCTAssertTrue([result isKindOfClass:[UIViewController class]],
                          @"页面路由的 completion 应回传被 present 的页面实例");
            XCTAssertEqualObjects([(UIViewController *)result ml_routerParams][@"sourceTag"], @"integration-test",
                                  @"自定义参数应随 VC 一起可读（ml_routerParams 留底）");
            [exp fulfill];
        }).open();
    XCTAssertEqualObjects(openRet, @(YES), @"页面路由 open() 同步返回受理信号 @(YES)");
    XCTAssertFalse([openRet isKindOfClass:[UIViewController class]], @"open() 永不返回 UIViewController");
    [self waitForExpectationsWithTimeout:3 handler:nil];
}

- (void)testWildcardPageRouteCapturesParam {
    XCTestExpectation *exp = [self expectationWithDescription:@"wildcard page present"];
    id openRet = MLRouter.create.build(@"mlcomp://cart/item/42")
        .withCompletion(^(id _Nullable result) {
            XCTAssertTrue([result isKindOfClass:[UIViewController class]],
                          @"通配符页面应命中并 present（completion 收到页面实例）");
            XCTAssertEqualObjects([(UIViewController *)result ml_routerParams][@"wildcard_1"], @"42",
                                  @"通配符捕获值应写入页面 ml_routerParams");
            [exp fulfill];
        }).open();
    XCTAssertEqualObjects(openRet, @(YES), @"通配符页面路由 open() 返回 @(YES)");
    [self waitForExpectationsWithTimeout:3 handler:nil];
}

#pragma mark - 模块化：模块自举与动态路由

- (void)testComponentModuleLoadedAndBootstrapped {
    XCTAssertTrue([CartComponentModule didSetup], @"组件模块应执行 moduleSetup");
    XCTAssertTrue([CartComponentModule didInit], @"组件模块应执行 moduleInit");
    XCTAssertTrue([[MLRouterModuleManager exportedModuleNames] containsObject:@"CartComponentModule"],
                  @"模块表导出应包含私有仓组件模块");
    XCTAssertEqualObjects(MLRouter.create.build(@"mlcomp://cart/promotion").open(), @"promo-ok",
                          @"模块 moduleSetup 自举注册的动态路由应可用");
}

- (void)testUserModuleRegistersDynamicRouteAcrossPods {
    XCTAssertEqualObjects(MLRouter.create.build(@"mluser://user/total").open(), @3,
                          @"跨仓模块注册的动态路由应经协议服务返回购物车商品数");
}

#pragma mark - 模块化：跨仓模块依赖拓扑顺序

- (void)testCrossPodModuleTopologicalOrder {
    XCTAssertTrue([UserComponentModule didInit], @"用户组件模块应已初始化");
    XCTAssertTrue([UserComponentModule cartModuleInitedFirst],
                  @"拓扑排序应保证被依赖的 CartComponentModule 先于 UserComponentModule 初始化（跨仓）");
    XCTAssertTrue([CartComponentModule didInit]);
}

#pragma mark - 治理：组件拦截器进链 / 阻断 / 降级兜底

- (void)testComponentInterceptorRunsInChain {
    [CartAuthInterceptor clearLog];
    MLRouter.create.build(@"mlcomp://cart/index").open();
    XCTAssertTrue([[CartAuthInterceptor processedURLLog] containsObject:@"mlcomp://cart/index"],
                  @"私有仓组件拦截器应被发现并进入全局拦截链");
}

- (void)testComponentInterceptorRejectTriggersFallback {
    XCTestExpectation *exp = [self expectationWithDescription:@"fallback"];
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull request, NSError * _Nullable error) {
        XCTAssertNotNil(error, @"被拦截器 reject 的路由应以错误形式进入兜底");
        XCTAssertTrue([request.urlStr containsString:@"blocked"]);
        [exp fulfill];
        return nil;
    }];
    MLRouter.create.build(@"mlcomp://blocked/demo").open();
    [self waitForExpectationsWithTimeout:3 handler:nil];
    [MLRouter setFallbackHandler:nil]; // 还原，避免污染后续用例
}

#pragma mark - 治理：路由表导出包含两个私有仓的全部注册

- (void)testExportRouteTableContainsComponentRegistrations {
    NSDictionary *table = [MLRouter exportRouteTable];
    XCTAssertTrue([table[@"pages"] containsObject:@"mlcomp://cart/index"], @"组件页面");
    XCTAssertTrue([table[@"pages"] containsObject:@"mlcomp://cart/dashboard"], @"场景 Dashboard 页面");
    XCTAssertTrue([table[@"pages"] containsObject:@"mluser://user/index"], @"跨仓用户组件页面");
    XCTAssertTrue([table[@"methods"] containsObject:@"mlcomp://cart/total"], @"组件方法路由");
    XCTAssertTrue([table[@"views"] containsObject:@"mlcomp://cart/badge"], @"组件 View 路由");
    XCTAssertTrue([table[@"dynamic"] containsObject:@"mlcomp://cart/promotion"], @"模块自举动态路由");
    XCTAssertTrue([table[@"services"] containsObject:@"CartServiceProtocol"], @"组件服务协议");
    XCTAssertTrue([table[@"modules"] containsObject:@"CartComponentModule"], @"购物车模块");
    XCTAssertTrue([table[@"modules"] containsObject:@"UserComponentModule"], @"用户模块（跨仓）");
}

@end
