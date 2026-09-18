// MLRouterModuleTests.m
// 模块层（自举 + 依赖拓扑 + 生命周期）测试。模块类用 runtime registerModuleClass 注册，便于隔离。
#import <XCTest/XCTest.h>
#import "MLRouterTestSupport.h"

#pragma mark - 测试模块类

@interface ModBase : NSObject <MLRouterModule>
@end
@implementation ModBase
+ (NSInteger)modulePriority { return 100; }
+ (NSArray<NSString *> *)moduleDependencies { return @[]; }
- (void)moduleSetup { [TestCapture appendModuleSetup:@"ModBase"]; [TestCapture appendModulePhase:@"setup:ModBase"]; }
- (void)moduleInit { [TestCapture appendModuleInit:@"ModBase"]; [TestCapture appendModulePhase:@"init:ModBase"]; }
- (void)applicationDidEnterBackground:(UIApplication *)application { [TestCapture appendModuleLifecycle:@"ModBase.background"]; }
@end

@interface ModDep : NSObject <MLRouterModule>
@end
@implementation ModDep
+ (NSInteger)modulePriority { return 0; }
+ (NSArray<NSString *> *)moduleDependencies { return @[@"ModBase"]; } // 依赖 ModBase
- (void)moduleSetup { [TestCapture appendModuleSetup:@"ModDep"]; [TestCapture appendModulePhase:@"setup:ModDep"]; }
- (void)moduleInit { [TestCapture appendModuleInit:@"ModDep"]; [TestCapture appendModulePhase:@"init:ModDep"]; }
@end

@interface ModCircleX : NSObject <MLRouterModule>
@end
@implementation ModCircleX
+ (NSArray<NSString *> *)moduleDependencies { return @[@"ModCircleY"]; }
- (void)moduleSetup {}
- (void)moduleInit {}
@end

@interface ModCircleY : NSObject <MLRouterModule>
@end
@implementation ModCircleY
+ (NSArray<NSString *> *)moduleDependencies { return @[@"ModCircleX"]; }
- (void)moduleSetup {}
- (void)moduleInit {}
@end

// 仅声明优先级、无依赖：验证「modulePriority 越大越先初始化」
@interface ModHighPriority : NSObject <MLRouterModule>
@end
@implementation ModHighPriority
+ (NSInteger)modulePriority { return 200; }
- (void)moduleSetup { [TestCapture appendModuleSetup:@"ModHighPriority"]; }
@end

@interface ModLowPriority : NSObject <MLRouterModule>
@end
@implementation ModLowPriority
+ (NSInteger)modulePriority { return 1; }
- (void)moduleSetup { [TestCapture appendModuleSetup:@"ModLowPriority"]; }
@end

// 高优先级但依赖低优先级模块：验证「依赖关系优先于优先级」
@interface ModHighDependsOnLow : NSObject <MLRouterModule>
@end
@implementation ModHighDependsOnLow
+ (NSInteger)modulePriority { return 900; }
+ (NSArray<NSString *> *)moduleDependencies { return @[@"ModLowDependency"]; }
- (void)moduleSetup { [TestCapture appendModuleSetup:@"ModHighDependsOnLow"]; }
@end

@interface ModLowDependency : NSObject <MLRouterModule>
@end
@implementation ModLowDependency
+ (NSInteger)modulePriority { return 1; }
- (void)moduleSetup { [TestCapture appendModuleSetup:@"ModLowDependency"]; }
@end

// 实现全部 App 生命周期钩子（含 openURL 返回 YES，用于验证多模块聚合语义）
@interface ModLifecycleFull : NSObject <MLRouterModule>
@end
@implementation ModLifecycleFull
- (void)moduleSetup {}
- (void)moduleInit {}
- (void)applicationDidFinishLaunching:(UIApplication *)application { [TestCapture appendModuleLifecycle:@"full.launch"]; }
- (void)applicationDidEnterBackground:(UIApplication *)application { [TestCapture appendModuleLifecycle:@"full.background"]; }
- (void)applicationWillEnterForeground:(UIApplication *)application { [TestCapture appendModuleLifecycle:@"full.foreground"]; }
- (BOOL)applicationOpenURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    [TestCapture appendModuleLifecycle:@"full.openURL"];
    return YES;
}
@end

// 不实现任何可选方法（极端最小模块）：验证生命周期转发不崩
@interface ModEmpty : NSObject <MLRouterModule>
@end
@implementation ModEmpty
@end

@interface MLRouterModuleTests : XCTestCase
@end

@implementation MLRouterModuleTests

- (void)setUp {
    [super setUp];
    [TestCapture reset];
    [MLRouter resetRouter];
    [MLRouterModuleManager reset]; // 清掉已加载实例并复位 loaded 标志，允许重新 loadModules
                                   // （刻意保留段扫描得到的模块类清单 —— 段扫描幂等，清了就回填不回来）
}

- (void)testLoadModulesTriggersSetupAndInit {
    [MLRouterModuleManager registerModuleClass:[ModBase class]];
    [MLRouterModuleManager loadModules];
    XCTAssertTrue([[TestCapture moduleSetupLog] containsObject:@"ModBase"]);
    XCTAssertTrue([[TestCapture moduleInitLog] containsObject:@"ModBase"]);
}

- (void)testDependencyTopoOrder {
    // ModDep 依赖 ModBase，被依赖者 ModBase 应先 setup
    [MLRouterModuleManager registerModuleClass:[ModBase class]];
    [MLRouterModuleManager registerModuleClass:[ModDep class]];
    [MLRouterModuleManager loadModules];
    NSArray *setup = [TestCapture moduleSetupLog];
    NSUInteger baseIdx = [setup indexOfObject:@"ModBase"];
    NSUInteger depIdx = [setup indexOfObject:@"ModDep"];
    XCTAssertLessThan(baseIdx, depIdx, @"被依赖模块 ModBase 应先于 ModDep 初始化");
}

- (void)testMultipleModulesLoaded {
    [MLRouterModuleManager registerModuleClass:[ModBase class]];
    [MLRouterModuleManager registerModuleClass:[ModDep class]];
    [MLRouterModuleManager loadModules];
    NSArray *names = [MLRouterModuleManager exportedModuleNames];
    XCTAssertTrue([names containsObject:@"ModBase"]);
    XCTAssertTrue([names containsObject:@"ModDep"]);
}

- (void)testCircularDependencyDetection {
    // 循环依赖不应崩溃，且环上的模块应被整体跳过（拓扑排序无法为它们定序）。
    // 注意：断言不能写成「已加载模块总数 < 2」—— 段扫描注册的模块（CartComponentModule /
    // UserComponentModule）常驻段表不会因 reset 消失，总数断言会误判。
    [MLRouterModuleManager registerModuleClass:[ModCircleX class]];
    [MLRouterModuleManager registerModuleClass:[ModCircleY class]];
    [MLRouterModuleManager loadModules]; // 不应死锁/崩溃
    NSArray *names = [MLRouterModuleManager exportedModuleNames];
    XCTAssertFalse([names containsObject:@"ModCircleX"], @"循环依赖组不应被初始化（X）");
    XCTAssertFalse([names containsObject:@"ModCircleY"], @"循环依赖组不应被初始化（Y）");
    XCTAssertTrue(names.count > 0u, @"与环无关的模块不应被牵连");
}

- (void)testLifecycleForwarding {
    [MLRouterModuleManager registerModuleClass:[ModBase class]];
    [MLRouterModuleManager loadModules];
    [MLRouterModuleManager applicationDidEnterBackground:[UIApplication sharedApplication]];
    XCTAssertTrue([[TestCapture moduleLifecycleLog] containsObject:@"ModBase.background"], @"生命周期应转发到模块");
}

- (void)testResetClearsModulesAndAllowsReload {
    [MLRouterModuleManager registerModuleClass:[ModBase class]];
    [MLRouterModuleManager loadModules];
    XCTAssertTrue([[MLRouterModuleManager exportedModuleNames] containsObject:@"ModBase"]);

    [MLRouterModuleManager reset];
    XCTAssertEqual([MLRouterModuleManager exportedModuleNames].count, 0u, @"reset 后应清空已加载模块");

    [TestCapture reset];
    [MLRouterModuleManager registerModuleClass:[ModBase class]];
    [MLRouterModuleManager loadModules]; // reset 后 g_mlModulesLoaded=NO，可重新加载
    XCTAssertTrue([[TestCapture moduleSetupLog] containsObject:@"ModBase"], @"reset 后应能重新初始化模块");
}

- (void)testSegmentScanRegistersModuleClass {
    // 模拟编译期段扫描回调，验证类名->模块类回填后 loadModules 可实例化
    [MLRouterModuleManager _registerModuleClassName:@"ModBase"];
    [MLRouterModuleManager loadModules];
    XCTAssertTrue([[MLRouterModuleManager exportedModuleNames] containsObject:@"ModBase"]);
}

- (void)testLoadModulesIdempotent {
    // loadModules 第二次调用不应重复初始化（g_mlModulesLoaded 守卫）
    [MLRouterModuleManager registerModuleClass:[ModBase class]];
    [MLRouterModuleManager loadModules];
    [TestCapture reset];
    [MLRouterModuleManager loadModules]; // 二次调用应无效
    XCTAssertEqual([TestCapture moduleSetupLog].count, 0u, @"loadModules 幂等，不应重复 setup");
}

#pragma mark - 优先级与依赖的裁决顺序

- (void)testHigherPriorityModuleInitializesFirstWhenNoDependency {
    [MLRouterModuleManager registerModuleClass:[ModLowPriority class]];
    [MLRouterModuleManager registerModuleClass:[ModHighPriority class]];
    [MLRouterModuleManager loadModules];
    NSArray *setup = [TestCapture moduleSetupLog];
    NSUInteger highIdx = [setup indexOfObject:@"ModHighPriority"];
    NSUInteger lowIdx = [setup indexOfObject:@"ModLowPriority"];
    XCTAssertNotEqual(highIdx, (NSUInteger)NSNotFound);
    XCTAssertNotEqual(lowIdx, (NSUInteger)NSNotFound);
    XCTAssertLessThan(highIdx, lowIdx, @"无依赖时，modulePriority 大者应先初始化（200 先于 1）");
}

- (void)testDependencyOverridesPriority {
    // ModHighDependsOnLow 优先级 900 但依赖优先级仅 1 的 ModLowDependency
    [MLRouterModuleManager registerModuleClass:[ModHighDependsOnLow class]];
    [MLRouterModuleManager registerModuleClass:[ModLowDependency class]];
    [MLRouterModuleManager loadModules];
    NSArray *setup = [TestCapture moduleSetupLog];
    NSUInteger depIdx = [setup indexOfObject:@"ModLowDependency"];
    NSUInteger highIdx = [setup indexOfObject:@"ModHighDependsOnLow"];
    XCTAssertNotEqual(depIdx, (NSUInteger)NSNotFound);
    XCTAssertNotEqual(highIdx, (NSUInteger)NSNotFound);
    XCTAssertLessThan(depIdx, highIdx, @"依赖关系优先于优先级：被依赖者必须先初始化");
}

- (void)testAllModuleSetupRunBeforeAnyModuleInit {
    [MLRouterModuleManager registerModuleClass:[ModBase class]];
    [MLRouterModuleManager registerModuleClass:[ModDep class]];
    [MLRouterModuleManager loadModules];
    // 框架约定：先跑完所有 moduleSetup，再统一 moduleInit（保证依赖方注册的服务在 init 前就位）
    NSArray *phases = [TestCapture modulePhaseLog];
    NSUInteger lastSetupIdx = NSNotFound;
    NSUInteger firstInitIdx = NSNotFound;
    for (NSUInteger i = 0; i < phases.count; i++) {
        if ([phases[i] hasPrefix:@"setup:"]) lastSetupIdx = i;
        if ([phases[i] hasPrefix:@"init:"] && firstInitIdx == NSNotFound) firstInitIdx = i;
    }
    XCTAssertNotEqual(lastSetupIdx, (NSUInteger)NSNotFound);
    XCTAssertNotEqual(firstInitIdx, (NSUInteger)NSNotFound);
    XCTAssertLessThan(lastSetupIdx, firstInitIdx, @"全部 moduleSetup 必须先于任何 moduleInit");
    XCTAssertEqual(phases.count, 4u, @"两个模块的 setup + init 共 4 条阶段日志");
}

#pragma mark - 生命周期全量转发

- (void)testLifecycleForwardingForAllHooks {
    [MLRouterModuleManager registerModuleClass:[ModLifecycleFull class]];
    [MLRouterModuleManager loadModules];
    UIApplication *app = [UIApplication sharedApplication];

    [MLRouterModuleManager applicationDidFinishLaunching:app];
    [MLRouterModuleManager applicationDidEnterBackground:app];
    [MLRouterModuleManager applicationWillEnterForeground:app];
    NSDictionary *options = [NSDictionary dictionary];
    BOOL handled = [MLRouterModuleManager applicationOpenURL:[NSURL URLWithString:@"mltest://open/demo"] options:options];

    NSArray *log = [TestCapture moduleLifecycleLog];
    XCTAssertTrue([log containsObject:@"full.launch"], @"didFinishLaunching 应转发");
    XCTAssertTrue([log containsObject:@"full.background"], @"didEnterBackground 应转发");
    XCTAssertTrue([log containsObject:@"full.foreground"], @"willEnterForeground 应转发");
    XCTAssertTrue([log containsObject:@"full.openURL"], @"openURL 应转发");
    XCTAssertTrue(handled, @"任一模块处理 openURL 返回 YES 时，聚合结果应为 YES");
}

- (void)testOpenURLReturnsNOWhenNoModuleHandlesIt {
    [MLRouterModuleManager registerModuleClass:[ModEmpty class]]; // 不实现任何可选方法
    [MLRouterModuleManager loadModules];
    BOOL handled = [MLRouterModuleManager applicationOpenURL:[NSURL URLWithString:@"mltest://open/demo"]
                                                     options:[NSDictionary dictionary]];
    XCTAssertFalse(handled, @"无模块处理时应返回 NO");
}

- (void)testLifecycleForwardingWithModuleImplementingNothingDoesNotCrash {
    [MLRouterModuleManager registerModuleClass:[ModEmpty class]];
    [MLRouterModuleManager loadModules];
    UIApplication *app = [UIApplication sharedApplication];
    // 全部钩子都应安全跳过（respondsToSelector 守卫）
    [MLRouterModuleManager applicationDidFinishLaunching:app];
    [MLRouterModuleManager applicationDidEnterBackground:app];
    [MLRouterModuleManager applicationWillEnterForeground:app];
    XCTAssertTrue([[MLRouterModuleManager exportedModuleNames] containsObject:@"ModEmpty"]);
}

@end
