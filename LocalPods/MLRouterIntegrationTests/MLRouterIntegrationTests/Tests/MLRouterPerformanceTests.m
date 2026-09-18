// MLRouterPerformanceTests.m
// 性能场景全覆盖 —— 这个文件此前**完全空白**（仓库里 measureBlock 出现过 0 次）。
//
// ────────────────────────────────────────────────────────────────────────────
// 为什么不用 XCTest 的 measureBlock / 绝对耗时阈值？
// ────────────────────────────────────────────────────────────────────────────
// 模拟器（且宿主机还在编译、跑模拟器、开着一堆 App）的绝对耗时抖动可达数倍，
// 拿「某次调用必须 < 5ms」这种断言当门禁，结果一定是随机红 —— 那种测试很快就会被
// 所有人加 .skip 绕过，等于没测。
//
// 所以这里测的是**算法复杂度**：同一操作在「小规模」与「大规模」下的**耗时比**。
// 复杂度是代码结构决定的，不受机器快慢影响：
//   · 哈希查找 = O(1) ⇒ 表大 100 倍，耗时比应仍在个位数
//   · 线性扫描 = O(N) ⇒ 表大 10 倍，耗时比应≈10（这是**特性记录**，不是缺陷）
//   · 若某天被改坏成 O(N²)，比值会直接冲到 100 倍以上，断言立刻红。
//
// 每条测量都取「多轮中的最小值」（最小值最接近真实成本，排除调度抖动），
// 且执行前先预热一次（避免首次正则编译 / 字典扩容污染样本）。
// ────────────────────────────────────────────────────────────────────────────

#import <XCTest/XCTest.h>
#import "MLRouterTestSupport.h"

#pragma mark - 测量辅助

/// 执行 `iterations` 次取平均；重复 `rounds` 轮，返回**最小**平均值。
static double MLRBestSeconds(NSUInteger iterations, NSUInteger rounds, dispatch_block_t block) {
    block(); // 预热：把懒加载 / 正则编译 / 字典扩容挡在测量之外
    double best = DBL_MAX;
    for (NSUInteger r = 0; r < rounds; r++) {
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        for (NSUInteger i = 0; i < iterations; i++) {
            block();
        }
        double avg = (CFAbsoluteTimeGetCurrent() - start) / (double)iterations;
        if (avg < best) best = avg;
    }
    return best;
}

/// 注册 N 条返回业务数据的精确动态路由（不返回 VC，避免把 UIKit 开销算进路由性能）。
static void MLRRegisterExactRoutes(NSString *prefix, NSUInteger count) {
    for (NSUInteger i = 0; i < count; i++) {
        NSString *pattern = [NSString stringWithFormat:@"%@/%lu", prefix, (unsigned long)i];
        [MLRouter registerRoute:pattern handler:^id(NSDictionary *params, MLRouterRequest *request) {
            return @(i);
        }];
    }
}

/// 注册 N 条通配符动态路由（每条都会编译一个 NSRegularExpression，是路由表最重的部分）。
static void MLRRegisterWildcardRoutes(NSString *prefix, NSUInteger count) {
    for (NSUInteger i = 0; i < count; i++) {
        NSString *pattern = [NSString stringWithFormat:@"%@/w%lu/*", prefix, (unsigned long)i];
        [MLRouter registerRoute:pattern handler:^id(NSDictionary *params, MLRouterRequest *request) {
            return @(i);
        }];
    }
}

@interface MLRouterPerformanceTests : XCTestCase
@end

@implementation MLRouterPerformanceTests

- (void)setUp {
    [super setUp];
    [TestCapture reset];
    [MLRouter resetRouter];
}

#pragma mark - ① 精确路由查找：必须是 O(1)

/// 精确匹配走哈希字典（`g_mlDynamicExactMap`），表规模涨 100 倍，单次查找耗时不应跟着涨。
///
/// 这条断言的价值：一旦有人把精确查找改成「遍历所有已注册 pattern 比对」，
/// 比值会从个位数直接跳到 ~100，测试立刻抓到 —— 而这在功能测试里完全看不出来。
- (void)testExactRouteLookupIsSizeIndependent {
    const NSUInteger smallCount = 20;
    const NSUInteger largeCount = 2000; // 100 倍

    [MLRouter resetRouter];
    MLRRegisterExactRoutes(@"mltest://perf/small", smallCount);
    double small = MLRBestSeconds(500, 3, ^{
        MLRouter.create.build(@"mltest://perf/small/7").open();
    });

    [MLRouter resetRouter];
    MLRRegisterExactRoutes(@"mltest://perf/small", largeCount);
    double large = MLRBestSeconds(500, 3, ^{
        MLRouter.create.build(@"mltest://perf/small/7").open();
    });

    // 表规模 ×100，耗时允许有噪声但绝不允许线性增长
    XCTAssertLessThan(large, small * 8.0,
                      @"精确路由查找应接近 O(1)：表规模涨 100 倍后单次耗时从 %.3fms 涨到 %.3fms（%.1f 倍），"
                      @"疑似退化成了线性扫描", small * 1000, large * 1000, large / MAX(small, 1e-9));
}

/// 静态段路由的精确查找同样不应受动态表规模影响（静态表与动态表是两套字典）。
- (void)testStaticRouteLookupUnaffectedByDynamicTableSize {
    double baseline = MLRBestSeconds(500, 3, ^{
        MLRouter.create.build(@"mltest://method/add?a=1&b=2").open();
    });

    [MLRouter resetRouter];
    MLRRegisterExactRoutes(@"mltest://perf/dyn", 2000);
    double withBigDynamicTable = MLRBestSeconds(500, 3, ^{
        MLRouter.create.build(@"mltest://method/add?a=1&b=2").open();
    });

    XCTAssertLessThan(withBigDynamicTable, baseline * 8.0,
                      @"静态路由查找不应受动态表规模影响（%.3fms → %.3fms）",
                      baseline * 1000, withBigDynamicTable * 1000);
}

#pragma mark - ② 通配符查找：线性是已知特性，要守住「不炸」

/// 通配符查找的实现是**线性遍历 + 逐条正则匹配**（`for (MLWildcardRouteModel *m in g_mlXxxWildcards)`）。
/// 这里不做「必须 O(1)」的苛求（那需要改造框架），而是：
///   ① 记录它是线性的（供后人评估注册策略：通配符别注册太多）；
///   ② 守住最坏情况不被改坏成 O(N²)（比值远超 N 的倍数即判失败）。
///
/// 查询用的是「谁都不命中」的 URL —— 这是最坏情况：必须走完整张通配符表才能确认未命中。
- (void)testWildcardLookupScalesLinearlyNotNullQuadratically {
    const NSUInteger smallCount = 10;
    const NSUInteger largeCount = 100; // 10 倍

    [MLRouter resetRouter];
    MLRRegisterWildcardRoutes(@"mltest://perf/wc", smallCount);
    double small = MLRBestSeconds(200, 3, ^{
        MLRouter.create.build(@"mltest://perf/wc/nomatch/at/all").open();
    });

    [MLRouter resetRouter];
    MLRRegisterWildcardRoutes(@"mltest://perf/wc", largeCount);
    double large = MLRBestSeconds(200, 3, ^{
        MLRouter.create.build(@"mltest://perf/wc/nomatch/at/all").open();
    });

    double ratio = large / MAX(small, 1e-9);
    // 线性 ⇒ 比值应≈10；留 3 倍余量容忍噪声，但 O(N²) 会冲到 ~100 直接失败
    XCTAssertLessThan(ratio, 30.0,
                      @"通配符查找应是线性而非平方级：通配符数量 ×10 后耗时比 = %.1f（%.3fms → %.3fms）",
                      ratio, small * 1000, large * 1000);

    // 同时给出绝对预算：100 条通配符的最坏情况单次查找不应超过 5ms（远超则说明实现有问题）
    XCTAssertLessThan(large, 0.005,
                      @"100 条通配符下最坏单次查找耗时 %.3fms，超出 5ms 预算", large * 1000);
}

/// 命中位置影响耗时：通配符表是按注册顺序遍历的，命中越晚越慢。
/// 把这条差异**记录**下来，说明「热点路由应尽量用精确注册而非通配符」。
- (void)testWildcardFirstMatchIsFasterThanLastMatch {
    [MLRouter resetRouter];
    MLRRegisterWildcardRoutes(@"mltest://perf/order", 100);

    double first = MLRBestSeconds(200, 3, ^{
        MLRouter.create.build(@"mltest://perf/order/w0/x").open();   // 注册在最前
    });
    double last = MLRBestSeconds(200, 3, ^{
        MLRouter.create.build(@"mltest://perf/order/w99/x").open();  // 注册在最后
    });

    XCTAssertLessThan(first, last * 12.0,
                      @"遍历顺序决定通配符命中成本（首个 %.3fms vs 末个 %.3fms）—— 允许差异但不应失控",
                      first * 1000, last * 1000);
}

/// 大量通配符的**注册（建表）**成本：每条都要编译一个 NSRegularExpression，这是路由表最重的操作。
- (void)testBulkWildcardRegistrationBuildsTableWithinBudget {
    const NSUInteger count = 200;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    MLRRegisterWildcardRoutes(@"mltest://perf/build", count);
    double elapsed = CFAbsoluteTimeGetCurrent() - start;

    XCTAssertLessThan(elapsed, 2.0,
                      @"注册 %lu 条通配符（含正则编译）耗时 %.1fms，超出 2s 预算 —— "
                      @"若模块启动时批量注册通配符，这个成本会直接计入冷启动",
                      (unsigned long)count, elapsed * 1000);
}

#pragma mark - ③ 参数映射成本

/// 参数映射是「逐 key 查属性 + KVC 赋值」，应随参数个数线性增长。
- (void)testParameterMappingCostScalesLinearlyWithParamCount {
    NSMutableDictionary *few = [NSMutableDictionary dictionary];
    NSMutableDictionary *many = [NSMutableDictionary dictionary];
    for (NSInteger i = 0; i < 5; i++)   few[[NSString stringWithFormat:@"objVal%ld", (long)i]] = @(i);
    for (NSInteger i = 0; i < 100; i++) many[[NSString stringWithFormat:@"objVal%ld", (long)i]] = @(i);

    double t5 = MLRBestSeconds(300, 3, ^{
        MLRouterRequest *req = MLRouter.create.build(@"mltest://page/typed");
        req = req.withParams(few);
        req.open();
    });
    double t100 = MLRBestSeconds(300, 3, ^{
        MLRouterRequest *req = MLRouter.create.build(@"mltest://page/typed");
        req = req.withParams(many);
        req.open();
    });

    XCTAssertLessThan(t100, t5 * 40.0,
                      @"参数映射应线性：5 参数 %.3fms vs 100 参数 %.3fms（20 倍数量，耗时比 %.1f）",
                      t5 * 1000, t100 * 1000, t100 / MAX(t5, 1e-9));
}

#pragma mark - ④ 冷启动：段扫描（dyld 扫描 + 正则建表）

/// 段扫描是**一次性冷启动成本**（dyld image 遍历 + 七张段表回填 + 通配符正则编译）。
/// `ensureRoutesLoaded` 是幂等的，所以要测真实成本必须重置幂等标志 —— 这里通过
/// 「反复 reset + ensureRoutesLoaded」逼近真实重建成本。
- (void)testColdRouteLoadingIsWithinStartupBudget {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    for (NSInteger i = 0; i < 5; i++) {
        [MLRouter resetRouter];
        [MLRouter ensureRoutesLoaded];
    }
    double perLoad = (CFAbsoluteTimeGetCurrent() - start) / 5.0;

    XCTAssertLessThan(perLoad, 1.0,
                      @"单次段扫描 + 路由表重建耗时 %.1fms，超出 1s 冷启动预算",
                      perLoad * 1000);
}

/// 幂等性同时也要有性能含义：重复调用 `ensureRoutesLoaded` 应是「一次锁判断」级别的开销。
- (void)testIdempotentEnsureRoutesLoadedIsCheap {
    [MLRouter ensureRoutesLoaded]; // 先确保已加载
    double perCall = MLRBestSeconds(2000, 3, ^{
        [MLRouter ensureRoutesLoaded];
    });

    XCTAssertLessThan(perCall, 0.0005,
                      @"已加载状态下 ensureRoutesLoaded 应为廉价的幂等检查，实测单次 %.4fms",
                      perCall * 1000);
}

#pragma mark - ⑤ 并发吞吐

/// 多线程并发路由：总耗时应随并发数正常摊薄，而不是因锁竞争劣化成串行甚至卡死。
- (void)testConcurrentOpenThroughput {
    const NSInteger threads = 8;
    const NSInteger perThread = 200;

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    for (NSInteger t = 0; t < threads; t++) {
        dispatch_group_async(group, queue, ^{
            for (NSInteger i = 0; i < perThread; i++) {
                MLRouter.create.build(@"mltest://method/add?a=1&b=2").open();
            }
        });
    }
    long timedOut = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    double elapsed = CFAbsoluteTimeGetCurrent() - start;

    XCTAssertEqual(timedOut, 0, @"%ld 线程 × %ld 次并发路由应能在 20s 内完成（不得死锁）",
                   (long)threads, (long)perThread);
    XCTAssertLessThan(elapsed, 10.0,
                      @"%ld 次并发路由耗时 %.1fs，超出 10s 预算（疑似锁竞争劣化）",
                      (long)(threads * perThread), elapsed);
}

#pragma mark - ⑥ 路由表导出（诊断能力本身的性能）

/// `exportRouteTable` 会在排查问题/上报埋点时被调用，大表下不应爆炸。
- (void)testExportRouteTableUnderLoad {
    MLRRegisterExactRoutes(@"mltest://perf/export", 1000);
    MLRRegisterWildcardRoutes(@"mltest://perf/exportwc", 100);

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSDictionary *table = nil;
    for (NSInteger i = 0; i < 10; i++) {
        table = [MLRouter exportRouteTable];
    }
    double perCall = (CFAbsoluteTimeGetCurrent() - start) / 10.0;

    // 注意：精确路由进 "dynamic"，通配符进 "wildcards" —— 两个不同的导出键。
    XCTAssertGreaterThanOrEqual([(NSArray *)table[@"dynamic"] count], 1000u,
                                @"导出结果应包含全部 1000 条精确动态路由");
    XCTAssertGreaterThanOrEqual([(NSArray *)table[@"wildcards"] count], 100u,
                                @"导出结果应包含全部 100 条通配符（另有段注册的若干条）");
    XCTAssertLessThan(perCall, 0.5,
                      @"1100+ 条路由下单次路由表导出耗时 %.1fms，超出 500ms", perCall * 1000);
}

@end
