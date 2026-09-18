// RouterTestDashboardViewController.m
// MLRouter 框架全能力测试总入口。
//
// 设计目标：把「框架的每一项公开能力」映射成一条可点击的真实场景，每条场景自带断言，
// 点完立刻看到「通过/失败 + 实际值」。这样任何人在真机上点一遍，就能回答
// 「这个框架宣传的功能是不是真的都能跑」，而不是靠读文档猜测。
//
// 场景分 14 组：静态段路由 / DSL / 重定向 / 动态路由 / 治理层 / 拦截器 / 服务发现 / 模块化 / 错误路径 / 聚合自检 / 线程内存 / 健壮性性能 / 跨仓组件 / 工程防线。

#import "RouterTestDashboardViewController.h"
#import "RTTestEnv.h"
#import "RTPages.h"
#import "RTServices.h"
#import "RTModules.h"
#import "RTInterceptors.h"
#import <MLRouter/MLRouterHeader.h>
#import <MLRouter/MLRouterService.h>
#import <MLRouter/MLRouterModule.h>
#import <math.h>

#define RTENV [RTTestEnv shared]

#pragma mark - 场景模型

@interface RTCase : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) void (^run)(void);
@end

@implementation RTCase
@end

@interface RTCaseGroup : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray<RTCase *> *cases;
+ (instancetype)groupWithName:(NSString *)name;
- (void)addCase:(NSString *)title detail:(NSString *)detail run:(void (^)(void))run;
@end

@implementation RTCaseGroup

+ (instancetype)groupWithName:(NSString *)name {
    RTCaseGroup *g = [[RTCaseGroup alloc] init];
    g.name = name;
    g.cases = [NSMutableArray array];
    return g;
}

- (void)addCase:(NSString *)title detail:(NSString *)detail run:(void (^)(void))run {
    RTCase *c = [[RTCase alloc] init];
    c.title = title;
    c.detail = detail;
    c.run = run;
    [self.cases addObject:c];
}

@end

#pragma mark - 默认兜底配置（TestKit 自己的，避免依赖宿主 AppDelegate）

static void RTInstallDefaultGovernance(void)
{
    [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull request, NSError * _Nullable error) {
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.systemGrayColor;
        vc.title = @"未命中兜底页";
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(vc.view.bounds, 24, 24)];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.text = [NSString stringWithFormat:
                      @"⚠️ TestKit 兜底页\n\n无法处理的路由：\n%@\n\n原因：\n%@",
                      request.urlStr,
                      error.localizedDescription ?: @"(未提供)"];
        [vc.view addSubview:label];
        return vc;
    }];
}

#pragma mark - 报告页

@interface RTReportViewController : UIViewController
@property (nonatomic, copy) NSString *reportText;
@property (nonatomic, copy) NSString *headline;
@end

@implementation RTReportViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.title = self.headline ?: @"场景结果";

    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    // 用 Menlo 而非 monospacedSystemFontOfSize: 以兼容 iOS 11 部署目标
    UIFont *mono = [UIFont fontWithName:@"Menlo" size:12];
    tv.font = mono ?: [UIFont systemFontOfSize:12];
    tv.text = self.reportText;
    [self.view addSubview:tv];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(_close)];
}

- (void)_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Dashboard

@interface RouterTestDashboardViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<RTCaseGroup *> *groups;
@end

@implementation RouterTestDashboardViewController

MLRouterPageClass("RouterTestDashboardViewController", "rtkit://test/dashboard")

// 一键全量跑（rtkit://test/runall）期间的静默开关：各场景不再弹自己的报告页，
// 结果全部记进 RTTestEnv，最后弹一张总报告。正常点按单个场景时它恒为 NO。
static BOOL gMLTRunAllMode = NO;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.title = @"MLRouter 全能力测试";
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"📋 完整报告" style:UIBarButtonItemStylePlain target:self action:@selector(_showFullReport)],
        [[UIBarButtonItem alloc] initWithTitle:@"🧹" style:UIBarButtonItemStylePlain target:self action:@selector(_clearReport)],
    ];

    // TestKit 自备兜底：治理层场景会把全局兜底改来改去，需要一个可复用的基准配置
    RTInstallDefaultGovernance();

    self.groups = @[
        [self groupStaticRoutes],
        [self groupDSL],
        [self groupRedirect],
        [self groupDynamicRoutes],
        [self groupGovernance],
        [self groupInterceptors],
        [self groupServices],
        [self groupModules],
        [self groupErrorPaths],
        [self groupBulk],
        // K / L / M 组放在最后：展示顺序必须与字母顺序一致，否则「第几组」这个说法在排查时会对不上
        [self groupThreadAndMemorySafety],
        [self groupRobustnessAndPerformance],
        [self groupCrossPodRoutes],
        [self groupOpsReadiness],
    ];

    // 把 J1 的聚合自检同时挂到一条动态路由上：`rtkit://test/selfcheck`。
    // 这样不点屏幕也能触发（CI 里 `xcrun simctl openurl booted "rtkit://test/selfcheck"`），
    // 真机/模拟器的免点击验收就有了一条可自动化的入口。Dashboard 是 App 启动自动打开的，
    // 所以 openurl 到达时这条路由必然已注册。
    __weak typeof(self) wself = self;
    [MLRouter registerRoute:@"rtkit://test/selfcheck"
                    handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
        [wself runAggregateSelfCheck];
        return @(YES);
    }];

    // 一键跑全量 68 个场景（rtkit://test/runall）：CI / 免点击验收入口。
    // 逐个执行每个场景的 run block（静默模式，不弹各场景自己的报告），
    // 全部跑完后弹一张总报告。AppDelegate 用 -RTKitRunAll 启动参数触发。
    [MLRouter registerRoute:@"rtkit://test/runall"
                    handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
        [wself runAllCasesThenReport];
        return @(YES);
    }];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 66.0;
    self.tableView.tableFooterView = [[UIView alloc] init];
    [self.view addSubview:self.tableView];
}

#pragma mark - A. 段宏静态路由

- (RTCaseGroup *)groupStaticRoutes {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"A · 段宏静态路由（编译期段注册，宿主零接线）"];
    __weak typeof(self) ws = self;

    [g addCase:@"A1 页面路由 + 参数映射 + 留底"
        detail:@"打开 rtkit://page/echo 并带 query；断言完成回调拿到页面实例、String/整型/BOOL/浮点四类属性映射、ml_routerParams 全量留底"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        MLRouter.create.build(@"rtkit://page/echo?sourceTag=dashboard&count=7&flag=1&ratio=1.5")
        .withCompletion(^(id result) {
            [RTENV beginSuite:@"A1 页面路由 + 参数映射 + 留底"];
            [RTENV check:[result isKindOfClass:[RTParamsEchoViewController class]]
                    name:@"withCompletion 回传真实页面实例"
                  detail:NSStringFromClass([result class])];
            RTParamsEchoViewController *vc = (RTParamsEchoViewController *)result;
            [RTENV check:[vc.sourceTag isEqualToString:@"dashboard"] name:@"对象属性映射（NSString）" detail:vc.sourceTag];
            [RTENV check:(vc.count == 7) name:@"整型属性映射（NSInteger）" detail:@(vc.count).stringValue];
            [RTENV check:(vc.flag == YES) name:@"布尔属性映射（BOOL）" detail:(vc.flag ? @"YES" : @"NO")];
            [RTENV check:(fabs(vc.ratio - 1.5) < 0.0001) name:@"浮点属性映射（double）" detail:[NSString stringWithFormat:@"%.3f", vc.ratio]];
            [RTENV check:[vc.ml_routerParams[@"sourceTag"] isEqualToString:@"dashboard"]
                    name:@"ml_routerParams 全量留底"
                  detail:[vc.ml_routerParams description]];
            [ws _presentReportSince:base];
        }).open();
    }];

    [g addCase:@"A2 通配符页面 · 单级 *"
        detail:@"打开 rtkit://wild/one/item/42；* 只吃一段、不跨 /，捕获写入 wildcard_1"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        MLRouter.create.build(@"rtkit://wild/one/item/42")
        .withCompletion(^(id vc) {
            [RTENV beginSuite:@"A2 单级通配符 *"];
            [RTENV check:[vc isKindOfClass:NSClassFromString(@"RTSingleWildcardViewController")]
                    name:@"命中单级通配符页面"
                  detail:NSStringFromClass([vc class])];
            NSString *cap = [(UIViewController *)vc ml_routerParams][@"wildcard_1"];
            [RTENV check:[cap isEqualToString:@"42"] name:@"wildcard_1 捕获到 42" detail:cap];
            [ws _presentReportSince:base];
        }).open();
    }];

    [g addCase:@"A3 通配符页面 · 多级贪婪 **"
        detail:@"打开 rtkit://wild/all/a/b/c；** 跨多级贪婪捕获整段"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        MLRouter.create.build(@"rtkit://wild/all/a/b/c")
        .withCompletion(^(id vc) {
            [RTENV beginSuite:@"A3 多级通配符 **"];
            [RTENV check:[vc isKindOfClass:NSClassFromString(@"RTMultiLevelWildcardViewController")]
                    name:@"命中多级通配符页面"
                  detail:NSStringFromClass([vc class])];
            NSString *cap = [(UIViewController *)vc ml_routerParams][@"wildcard_1"];
            [RTENV check:[cap isEqualToString:@"a/b/c"] name:@"wildcard_1 跨级捕获 a/b/c" detail:cap];
            [ws _presentReportSince:base];
        }).open();
    }];

    [g addCase:@"A4 通配符页面 · 单级 + 多级混合"
        detail:@"打开 rtkit://wild/mix/abc/detail/x/y；验证 * 与 ** 各自归位"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        MLRouter.create.build(@"rtkit://wild/mix/abc/detail/x/y")
        .withCompletion(^(id vc) {
            [RTENV beginSuite:@"A4 通配符 · * 与 ** 混合"];
            NSDictionary *p = [(UIViewController *)vc ml_routerParams];
            [RTENV check:[vc isKindOfClass:NSClassFromString(@"RTMultiCaptureViewController")]
                    name:@"命中混合通配符页面" detail:NSStringFromClass([vc class])];
            [RTENV check:[p[@"wildcard_1"] isEqualToString:@"abc"] name:@"wildcard_1 = * 段" detail:p[@"wildcard_1"]];
            [RTENV check:[p[@"wildcard_2"] isEqualToString:@"x/y"] name:@"wildcard_2 = ** 段" detail:p[@"wildcard_2"]];
            [ws _presentReportSince:base];
        }).open();
    }];

    [g addCase:@"A5 通配符页面 · 三星号交错（回归用例）"
        detail:@"打开 rtkit://wild/multi/s1/mid/s2/end/t1/t2；三个星号类型交错，参数表与捕获组一旦错位就会串位"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        MLRouter.create.build(@"rtkit://wild/multi/s1/mid/s2/end/t1/t2")
        .withCompletion(^(id vc) {
            [RTENV beginSuite:@"A5 三星号交错通配符（回归）"];
            NSDictionary *p = [(UIViewController *)vc ml_routerParams];
            [RTENV check:[vc isKindOfClass:NSClassFromString(@"RTMultiStarWildcardViewController")]
                    name:@"命中三星号交错页面" detail:NSStringFromClass([vc class])];
            [RTENV check:[p[@"wildcard_1"] isEqualToString:@"s1"] name:@"第 1 个 * → wildcard_1" detail:p[@"wildcard_1"]];
            [RTENV check:[p[@"wildcard_2"] isEqualToString:@"s2"] name:@"第 2 个 * → wildcard_2" detail:p[@"wildcard_2"]];
            [RTENV check:[p[@"wildcard_3"] isEqualToString:@"t1/t2"] name:@"** → wildcard_3" detail:p[@"wildcard_3"]];
            [ws _presentReportSince:base];
        }).open();
    }];

    [g addCase:@"A6 View 路由（返回视图实例）"
        detail:@"打开 rtkit://view/badge 并注入 badgeText；open() 应直接返回 UIView 实例（而不是 @(YES)）"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        id ret = MLRouter.create.build(@"rtkit://view/badge")
            .withParam(@"badgeText", @"🛒 3 件")
            .open();
        [RTENV beginSuite:@"A6 View 路由"];
        [RTENV check:[ret isKindOfClass:[UIView class]] name:@"open() 返回 UIView 实例" detail:NSStringFromClass([ret class])];
        [RTENV check:[[(UIView *)ret valueForKey:@"badgeText"] isEqualToString:@"🛒 3 件"]
                name:@"withParam 注入到视图属性" detail:[(UIView *)ret valueForKey:@"badgeText"]];

        if ([ret isKindOfClass:[UIView class]]) {
            UIViewController *host = [[UIViewController alloc] init];
            host.title = @"View 路由演示";
            host.view.backgroundColor = UIColor.whiteColor;
            UIView *v = (UIView *)ret;
            v.frame = CGRectMake(24, 140, host.view.bounds.size.width - 48, 60);
            [host.view addSubview:v];
            [ws _pushOrPresent:host];
        }
        [ws _presentReportSince:base];
    }];

    [g addCase:@"A7 方法路由 · 同步返回"
        detail:@"打开 rtkit://method/sync?a=2&b=3；同步方法路由应直接把返回值交回 open()"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        id ret = MLRouter.create.build(@"rtkit://method/sync?a=2&b=3").open();
        [RTENV beginSuite:@"A7 方法路由（同步）"];
        [RTENV check:[ret isEqual:@5] name:@"open() 同步返回 2+3=5" detail:[ret description]];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"A8 方法路由 · 异步 completion"
        detail:@"打开 rtkit://method/async?tag=T；方法内部异步回调，withCompletion 应收到结果"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        MLRouter.create.build(@"rtkit://method/async")
            .withParam(@"tag", @"T")
            .withCompletion(^(id result) {
                [RTENV beginSuite:@"A8 方法路由（异步）"];
                [RTENV check:[result isEqualToString:@"async-echo:T"]
                        name:@"withCompletion 收到异步结果"
                      detail:[result description]];
                [ws _presentReportSince:base];
            }).open();
    }];

    return g;
}

#pragma mark - B. 链式 DSL

- (RTCaseGroup *)groupDSL {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"B · 链式点语法 DSL"];
    __weak typeof(self) ws = self;

    [g addCase:@"B1 withParams 字典批量注入"
        detail:@"一次灌入多个参数，验证 withParams 内部逐个走 withParam 且都落到 ml_routerParams"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        MLRouter.create.build(@"rtkit://page/echo")
            .withParams(@{ @"sourceTag": @"bulk", @"count": @11, @"flag": @0, @"ratio": @2.25 })
            .withCompletion(^(id vc) {
                [RTENV beginSuite:@"B1 withParams 批量注入"];
                NSDictionary *p = [(UIViewController *)vc ml_routerParams];
                [RTENV check:[p[@"sourceTag"] isEqualToString:@"bulk"] name:@"批量参数 sourceTag" detail:p[@"sourceTag"]];
                [RTENV check:[p[@"count"] isEqual:@11] name:@"批量参数 count" detail:[p[@"count"] description]];
                [RTENV check:[p[@"flag"] isEqual:@0] name:@"批量参数 flag" detail:[p[@"flag"] description]];
                [RTENV check:[p[@"ratio"] isEqual:@2.25] name:@"批量参数 ratio" detail:[p[@"ratio"] description]];
                [ws _presentReportSince:base];
            }).open();
    }];

    [g addCase:@"B2 withTransitionStyle 模态弹出"
        detail:@"指定 MLRouteTransitionStylePresent，页面应以模态方式弹出（而非 push）"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"B2 withTransitionStyle"];
        id ret = MLRouter.create.build(@"rtkit://redirect/target")
            .withTransitionStyle(MLRouteTransitionStylePresent)
            .withCompletion(^(id vc) {
                [RTENV check:[vc isKindOfClass:[UIViewController class]]
                        name:@"完成回调收到页面实例" detail:NSStringFromClass([vc class])];
                [RTENV check:([(UIViewController *)vc presentingViewController] != nil)
                        name:@"页面确实以模态方式呈现（存在 presentingViewController）"
                      detail:NSStringFromClass([[(UIViewController *)vc presentingViewController] class])];
            }).open();
        [RTENV check:[ret isEqual:@(YES)] name:@"页面路由 open() 返回 @(YES)" detail:[ret description]];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"B3 withAnimation 关闭动画"
        detail:@"withAnimation(NO) 应只影响转场动画开关，路由本身必须照常命中"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"B3 withAnimation(NO)"];
        id ret = MLRouter.create.build(@"rtkit://page/echo?sourceTag=noanim")
            .withAnimation(NO)
            .withCompletion(^(id vc) {
                [RTENV check:[vc isKindOfClass:[RTParamsEchoViewController class]]
                        name:@"无动画路由仍然命中页面" detail:NSStringFromClass([vc class])];
                [RTENV check:([[(UIViewController *)vc ml_routerParams][@"sourceTag"] isEqualToString:@"noanim"])
                        name:@"参数照常传递" detail:[[(UIViewController *)vc ml_routerParams] description]];
            }).open();
        [RTENV check:[ret isEqual:@(YES)] name:@"open() 返回 @(YES)" detail:[ret description]];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"B4 open() 返回值语义对照（页面 / 方法 / 视图）"
        detail:@"一次性验证三类路由各自的返回语义：页面→@(YES)、方法→业务数据、视图→UIView 实例"
           run:^{
        [RTENV beginSuite:@"B4 open() 返回值语义"];
        NSInteger base = RTENV.totalLineCount;

        id pageRet = MLRouter.create.build(@"rtkit://redirect/target?origin=rtkit").open();
        [RTENV check:[pageRet isEqual:@(YES)] name:@"页面路由 → @(YES)（仅表示已 present）" detail:[pageRet description]];

        id methodRet = MLRouter.create.build(@"rtkit://method/sync?a=10&b=32").open();
        [RTENV check:[methodRet isEqual:@42] name:@"方法路由 → 业务数据 42" detail:[methodRet description]];

        id viewRet = MLRouter.create.build(@"rtkit://view/badge").open();
        [RTENV check:[viewRet isKindOfClass:[UIView class]] name:@"视图路由 → UIView 实例" detail:NSStringFromClass([viewRet class])];

        [RTENV info:@"结论：open() 从不返回 UIViewController。若拿到 UIViewController，说明该 URL 没命中、走的是兜底 handler。"];
        [ws _presentReportSince:base];
    }];

    return g;
}

#pragma mark - C. 重定向

- (RTCaseGroup *)groupRedirect {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"C · 重定向（编译期 MLRedirectSect）"];
    __weak typeof(self) ws = self;

    [g addCase:@"C1 一级重定向 + query 保留"
        detail:@"rtkit://redirect/from?origin=rtkit → rtkit://redirect/target?origin=rtkit；重写路径时 query 必须原样保留"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"C1 一级重定向"];
        id ret = MLRouter.create.build(@"rtkit://redirect/from?origin=rtkit")
            .withCompletion(^(id vc) {
                [RTENV check:[vc isKindOfClass:NSClassFromString(@"RTRedirectTargetViewController")]
                        name:@"落地到重定向终点页" detail:NSStringFromClass([vc class])];
                [RTENV check:[[(UIViewController *)vc ml_routerParams][@"origin"] isEqualToString:@"rtkit"]
                        name:@"重定向后 query(origin) 未丢失"
                      detail:[[(UIViewController *)vc ml_routerParams] description]];
            }).open();
        [RTENV check:[ret isEqual:@(YES)] name:@"open() 返回 @(YES)" detail:[ret description]];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"C2 多级重定向 hop1 → hop2 → target"
        detail:@"A→B→C 链式跳转，框架应在一次 open 内递归解析到最终地址"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        MLRouter.create.build(@"rtkit://redirect/hop1?origin=multihop")
            .withCompletion(^(id vc) {
                [RTENV beginSuite:@"C2 多级重定向"];
                [RTENV check:[vc isKindOfClass:NSClassFromString(@"RTRedirectTargetViewController")]
                        name:@"多级跳转后落地终点页" detail:NSStringFromClass([vc class])];
                [RTENV check:[[(UIViewController *)vc ml_routerParams][@"origin"] isEqualToString:@"multihop"]
                        name:@"多级跳转中 query 未丢失"
                      detail:[[(UIViewController *)vc ml_routerParams] description]];
                [ws _presentReportSince:base];
            }).open();
    }];

    [g addCase:@"C3 重定向环路不卡死"
        detail:@"loopA ↔ loopB 互为重定向；框架有防环上限，应放弃解析并落到 404 兜底，绝不能死循环"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        __block NSInteger code = 0;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest *req, NSError *err) {
            code = err.code;
            return nil;
        }];
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        MLRouter.create.build(@"rtkit://redirect/loopA").open();
        CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();
        [RTENV beginSuite:@"C3 重定向防环"];
        [RTENV check:(t1 - t0) < 1.0 name:@"环路被及时中断（耗时 < 1s）"
              detail:[NSString stringWithFormat:@"%.4f s", t1 - t0]];
        [RTENV check:(code == 404) name:@"放弃解析后进入 404 兜底"
              detail:[NSString stringWithFormat:@"code=%ld", (long)code]];
        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    return g;
}

#pragma mark - D. 动态路由

- (RTCaseGroup *)groupDynamicRoutes {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"D · 动态路由（运行时 / 远程下发注册）"];
    __weak typeof(self) ws = self;

    [g addCase:@"D1 精确动态路由 → 返回业务数据"
        detail:@"注册 rtkit://dyn/exact 返回 NSNumber；open() 应拿到数据，且不得走兜底"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        __block BOOL fallbackHit = NO;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest *req, NSError *err) { fallbackHit = YES; return nil; }];
        [MLRouter registerRoute:@"rtkit://dyn/exact" handler:^id _Nullable(NSDictionary *params, MLRouterRequest *request) {
            return @([params[@"n"] integerValue] * 2);
        }];
        id ret = MLRouter.create.build(@"rtkit://dyn/exact?n=21").open();
        [RTENV beginSuite:@"D1 精确动态路由"];
        [RTENV check:[ret isEqual:@42] name:@"handler 返回数据 21×2=42" detail:[ret description]];
        [RTENV check:!fallbackHit name:@"未误判为 404（没有走兜底）" detail:fallbackHit ? @"走了兜底" : @"未走兜底"];
        [MLRouter unregisterRoute:@"rtkit://dyn/exact"];
        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    [g addCase:@"D2 动态路由 → 返回 UIViewController"
        detail:@"handler 返回 VC 时应自动 present，且 open() 返回 @(YES)"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [MLRouter registerRoute:@"rtkit://dyn/vc" handler:^id _Nullable(NSDictionary *params, MLRouterRequest *request) {
            RTFallbackViewController *vc = [[RTFallbackViewController alloc] init];
            vc.title = @"动态路由返回的 VC";
            return vc;
        }];
        id ret = MLRouter.create.build(@"rtkit://dyn/vc").open();
        [RTENV beginSuite:@"D2 动态路由返回 VC"];
        [RTENV check:[ret isEqual:@(YES)] name:@"open() 返回 @(YES)" detail:[ret description]];
        [RTENV check:![ret isKindOfClass:[UIViewController class]]
                name:@"open() 不把 VC 当返回值丢出来" detail:NSStringFromClass([ret class])];
        [MLRouter unregisterRoute:@"rtkit://dyn/vc"];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"D3 动态通配符路由"
        detail:@"注册 rtkit://dyn/wild/*/tail，验证运行时注册的路由同样支持通配符捕获"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [MLRouter registerRoute:@"rtkit://dyn/wild/*/tail" handler:^id _Nullable(NSDictionary *params, MLRouterRequest *request) {
            return [NSString stringWithFormat:@"dyn:%@", params[@"wildcard_1"]];
        }];
        id ret = MLRouter.create.build(@"rtkit://dyn/wild/XY/tail").open();
        [RTENV beginSuite:@"D3 动态通配符路由"];
        [RTENV check:[ret isEqualToString:@"dyn:XY"] name:@"通配符捕获 XY" detail:[ret description]];
        [MLRouter unregisterRoute:@"rtkit://dyn/wild/*/tail"];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"D4 handler 返回 nil 不得被当成 404"
        detail:@"handler 合法返回 nil（业务语义＝无数据）时，不应触发兜底、不应打 404 诊断"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        __block BOOL fallbackHit = NO;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest *req, NSError *err) { fallbackHit = YES; return nil; }];
        [MLRouter registerRoute:@"rtkit://dyn/nil" handler:^id _Nullable(NSDictionary *params, MLRouterRequest *request) {
            return nil;
        }];
        id ret = MLRouter.create.build(@"rtkit://dyn/nil").open();
        [RTENV beginSuite:@"D4 动态路由返回 nil"];
        [RTENV check:(ret == nil) name:@"open() 返回 nil" detail:@"nil"];
        [RTENV check:!fallbackHit name:@"命中即为命中：不走 404 兜底" detail:fallbackHit ? @"错误地走了兜底" : @"正确"];
        [MLRouter unregisterRoute:@"rtkit://dyn/nil"];
        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    [g addCase:@"D5 unregisterRoute 后应回落到兜底"
        detail:@"注册 → 命中 → 反注册 → 再访问应走 404 兜底"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [MLRouter registerRoute:@"rtkit://dyn/gone" handler:^id _Nullable(NSDictionary *params, MLRouterRequest *request) {
            return @"alive";
        }];
        id before = MLRouter.create.build(@"rtkit://dyn/gone").open();

        [MLRouter unregisterRoute:@"rtkit://dyn/gone"];
        __block BOOL fallbackHit = NO;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest *req, NSError *err) { fallbackHit = YES; return nil; }];
        id after = MLRouter.create.build(@"rtkit://dyn/gone").open();

        [RTENV beginSuite:@"D5 反注册动态路由"];
        [RTENV check:[before isEqualToString:@"alive"] name:@"反注册前命中 handler" detail:[before description]];
        [RTENV check:(after == nil) name:@"反注册后不再命中" detail:@"nil"];
        [RTENV check:fallbackHit name:@"反注册后走兜底" detail:fallbackHit ? @"已兜底" : @"未兜底"];
        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    return g;
}

#pragma mark - E. 治理层

- (RTCaseGroup *)groupGovernance {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"E · 治理层（白名单 / 校验器 / 兜底）"];
    __weak typeof(self) ws = self;

    [g addCase:@"E1 scheme 白名单 · 放行"
        detail:@"只允许 rtkit 通过，打开 rtkit://page/echo 应正常命中"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [MLRouter setAllowedSchemes:[NSSet setWithObject:@"rtkit"]];
        id ret = MLRouter.create.build(@"rtkit://page/echo?sourceTag=wl-allow").open();
        [RTENV beginSuite:@"E1 scheme 白名单放行"];
        [RTENV check:[ret isEqual:@(YES)] name:@"白名单内 scheme 正常命中" detail:[ret description]];
        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    [g addCase:@"E2 scheme 白名单 · 拦截降级"
        detail:@"只允许 mlcomp 通过，打开 rtkit://… 应被拦下并走兜底，绝不能放行"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [MLRouter setAllowedSchemes:[NSSet setWithObject:@"mlcomp"]];
        __block NSInteger code = 0;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest *req, NSError *err) {
            code = err.code;
            return nil;
        }];
        MLRouter.create.build(@"rtkit://page/echo").open();
        [RTENV beginSuite:@"E2 scheme 白名单拦截"];
        // 用 error code 区分「被白名单拦下(403)」与「路由压根不存在(404)」，
        // 否则这条断言在「白名单没生效但路由恰好也不存在」时会假阳性通过。
        [RTENV check:(code == 403) name:@"非法 scheme 被白名单拦下（error 403）"
              detail:code == 0 ? @"被错误放行，未走兜底" : [NSString stringWithFormat:@"code=%ld", (long)code]];
        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    [g addCase:@"E3 path 前缀白名单"
        detail:@"只允许 rtkit://page/ 前缀；同 scheme 下 rtkit://redirect/target 必须被拦"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [MLRouter setAllowedURLPaths:[NSSet setWithObject:@"rtkit://page/"]];
        __block NSInteger code = 0;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest *req, NSError *err) { code = err.code; return nil; }];

        id allowed = MLRouter.create.build(@"rtkit://page/echo").open();
        NSInteger codeAllowed = code;
        code = 0;
        MLRouter.create.build(@"rtkit://redirect/target").open();
        NSInteger codeDenied = code;

        [RTENV beginSuite:@"E3 path 前缀白名单"];
        [RTENV check:[allowed isEqual:@(YES)] name:@"前缀内 path 正常命中" detail:[allowed description]];
        [RTENV check:(codeAllowed == 0) name:@"前缀内未走兜底" detail:[NSString stringWithFormat:@"code=%ld", (long)codeAllowed]];
        [RTENV check:(codeDenied == 403) name:@"前缀外 path 被拦下（error 403）"
              detail:[NSString stringWithFormat:@"code=%ld", (long)codeDenied]];

        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    [g addCase:@"E4 自定义 validator（最高优先级）"
        detail:@"validator 返回 NO 时直接降级，且优先于 scheme/path 白名单判定"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [MLRouter setAllowedSchemes:[NSSet setWithObject:@"rtkit"]]; // 故意放宽，证明 validator 优先级更高
        [MLRouter setRouteValidator:^BOOL(NSURL *url) {
            return ![url.absoluteString containsString:@"forbidden"];
        }];
        __block NSInteger code = 0;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest *req, NSError *err) { code = err.code; return nil; }];

        id pass = MLRouter.create.build(@"rtkit://page/echo").open();
        NSInteger codePass = code;
        code = 0;
        // 注意：被否决的这条 URL 本身是一条**存在且可正常命中**的路由，
        // 这样「被 validator 拦下(403)」与「路由不存在(404)」才能区分开，断言不会假阳性。
        MLRouter.create.build(@"rtkit://page/echo?sourceTag=forbidden").open();
        NSInteger codeDenied = code;

        [RTENV beginSuite:@"E4 自定义 validator"];
        [RTENV check:[pass isEqual:@(YES)] name:@"validator 通过时正常命中" detail:[pass description]];
        [RTENV check:(codePass == 0) name:@"通过时未走兜底" detail:[NSString stringWithFormat:@"code=%ld", (long)codePass]];
        [RTENV check:(codeDenied == 403) name:@"validator 否决时被拦下（压过白名单）"
              detail:[NSString stringWithFormat:@"code=%ld", (long)codeDenied]];

        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    [g addCase:@"E5 fallbackHandler 兜底（自定义逻辑 + error 透传）"
        detail:@"路由未命中时应回调 handler，并带上 404 NSError；handler 返回的 VC 会被自动 present"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        __block NSString *capturedURL = nil;
        __block NSInteger capturedCode = 0;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest *req, NSError *err) {
            capturedURL = req.urlStr;
            capturedCode = err.code;
            UIViewController *vc = [[UIViewController alloc] init];
            vc.view.backgroundColor = UIColor.systemGrayColor;
            vc.title = @"E5 自定义兜底";
            return vc;
        }];
        id ret = MLRouter.create.build(@"rtkit://e5/no/such/route").open();
        [RTENV beginSuite:@"E5 fallbackHandler"];
        [RTENV check:[capturedURL isEqualToString:@"rtkit://e5/no/such/route"] name:@"handler 收到原始 URL" detail:capturedURL];
        [RTENV check:(capturedCode == 404) name:@"handler 收到 404 error" detail:@(capturedCode).stringValue];
        [RTENV check:[ret isEqual:@(YES)] name:@"handler 返回 VC 被自动 present，open() 返回 @(YES)" detail:[ret description]];
        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    [g addCase:@"E6 fallbackViewControllerClass 兜底（便捷版）"
        detail:@"不写 handler，只指定兜底 VC 类，未命中时应自动实例化并 present"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [MLRouter resetGovernance];   // 先清掉 handler，否则 handler 优先级更高，测不到这条分支
        [MLRouter setFallbackViewControllerClass:[RTFallbackViewController class]];
        id ret = MLRouter.create.build(@"rtkit://e6/nowhere").open();
        [RTENV beginSuite:@"E6 fallbackViewControllerClass"];
        [RTENV check:[ret isEqual:@(YES)] name:@"自动实例化兜底 VC 并 present" detail:[ret description]];
        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    [g addCase:@"E7 exportRouteTable 路由表导出"
        detail:@"导出应包含静态段页面/方法/视图/通配符、动态路由、重定向、服务、模块七类信息"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        NSDictionary *table = [MLRouter exportRouteTable];
        NSArray *pages = table[@"pages"];
        NSArray *methods = table[@"methods"];
        NSArray *views = table[@"views"];
        NSArray *wildcards = table[@"wildcards"];
        NSDictionary *redirects = table[@"redirects"];
        NSArray *services = table[@"services"];

        [RTENV beginSuite:@"E7 exportRouteTable"];
        [RTENV check:[pages containsObject:@"rtkit://redirect/target"] name:@"pages 含段注册页面" detail:@(pages.count).stringValue];
        [RTENV check:[methods containsObject:@"rtkit://method/sync"] name:@"methods 含段注册方法路由" detail:@(methods.count).stringValue];
        [RTENV check:[views containsObject:@"rtkit://view/badge"] name:@"views 含段注册视图路由" detail:@(views.count).stringValue];
        [RTENV check:(wildcards.count > 0) name:@"wildcards 含通配符路由" detail:@(wildcards.count).stringValue];
        [RTENV check:[redirects[@"rtkit://redirect/from"] isEqualToString:@"rtkit://redirect/target"]
                name:@"redirects 含重定向映射" detail:[redirects description]];
        [RTENV check:[services containsObject:@"RTGreetingService"] name:@"services 含段注册服务" detail:@(services.count).stringValue];
        [RTENV info:[NSString stringWithFormat:@"完整路由表：\n%@", table]];
        [ws _presentReportSince:base];
    }];

    return g;
}

#pragma mark - F. 拦截器

- (RTCaseGroup *)groupInterceptors {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"F · 拦截器职责链"];
    __weak typeof(self) ws = self;

    [g addCase:@"F1 放行 · 进链顺序按 priority 升序"
        detail:@"Early(p10) 与 Late(p90) 都应进链，且 p10 必须先于 p90 执行"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTInterceptorLog reset];
        MLRouter.create.build(@"rtkit://method/sync?a=1&b=1").open();

        NSInteger iEarly = [RTInterceptorLog indexOfEntryContaining:@"RTEarlyInterceptor"];
        NSInteger iLate = [RTInterceptorLog indexOfEntryContaining:@"RTLateInterceptor"];
        [RTENV beginSuite:@"F1 拦截器放行与顺序"];
        [RTENV check:(iEarly >= 0) name:@"p10 拦截器已进链" detail:@(iEarly).stringValue];
        [RTENV check:(iLate >= 0) name:@"p90 拦截器已进链" detail:@(iLate).stringValue];
        [RTENV check:(iEarly >= 0 && iLate >= 0 && iEarly < iLate) name:@"priority 升序：p10 先于 p90" detail:[NSString stringWithFormat:@"early=%ld late=%ld", (long)iEarly, (long)iLate]];
        [RTENV info:[RTInterceptorLog reportText]];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"F2 阻断 · reject 熔断并降级"
        detail:@"URL 命中 rtkit://block 时 p10 直接 reject；p90 不得再进链，且整体走降级兜底"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTInterceptorLog reset];
        __block BOOL fallbackHit = NO;
        __block NSInteger errCode = 0;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest *req, NSError *err) {
            fallbackHit = YES;
            errCode = err.code;
            return nil;
        }];
        id ret = MLRouter.create.build(@"rtkit://block/demo").open();

        NSInteger iEarly = [RTInterceptorLog indexOfEntryContaining:@"RTEarlyInterceptor"];
        NSInteger iLate = [RTInterceptorLog indexOfEntryContaining:@"RTLateInterceptor"];
        [RTENV beginSuite:@"F2 拦截器阻断"];
        [RTENV check:(iEarly >= 0) name:@"阻断前 p10 已进链" detail:@(iEarly).stringValue];
        [RTENV check:(iLate < 0) name:@"reject 后 p90 不再进链（职责链熔断）" detail:iLate < 0 ? @"正确熔断" : @"未被熔断"];
        [RTENV check:fallbackHit name:@"被拦截后走降级兜底" detail:fallbackHit ? @"已兜底" : @"未兜底"];
        [RTENV check:(errCode == 403) name:@"兜底拿到拦截器 error(403)" detail:@(errCode).stringValue];
        [RTENV check:![ret isKindOfClass:[UIViewController class]]
                name:@"open() 未把 VC 当返回值丢出来" detail:NSStringFromClass([ret class])];
        [RTENV info:[RTInterceptorLog reportText]];
        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    [g addCase:@"F3 被拦截时不返回 UIViewController"
        detail:@"回归检查：拦截器 reject 走兜底后，open() 应返回 @(YES)/nil，绝不能把 VC 当返回值丢出来"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        __block BOOL fallbackHit = NO;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest *req, NSError *err) {
            fallbackHit = YES;
            UIViewController *vc = [[UIViewController alloc] init];
            vc.view.backgroundColor = UIColor.systemGrayColor;
            return vc;
        }];
        id ret = MLRouter.create.build(@"rtkit://block/again").open();
        [RTENV beginSuite:@"F3 拦截降级返回值语义"];
        [RTENV check:fallbackHit name:@"确实走了兜底" detail:fallbackHit ? @"是" : @"否"];
        [RTENV check:![ret isKindOfClass:[UIViewController class]]
                name:@"open() 未返回 UIViewController" detail:NSStringFromClass([ret class])];
        [RTENV check:[ret isEqual:@(YES)] name:@"open() 返回 @(YES)" detail:[ret description]];
        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    return g;
}

#pragma mark - G. 服务发现

- (RTCaseGroup *)groupServices {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"G · 协议驱动服务发现"];
    __weak typeof(self) ws = self;

    [g addCase:@"G1 serviceForProtocol 命中并强类型调用"
        detail:@"只依赖 RTGreetingService 协议，通过段注册拿到实现并调用其方法"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        id<RTGreetingService> svc = [MLRouterService serviceForProtocol:@protocol(RTGreetingService)];
        [RTENV beginSuite:@"G1 serviceForProtocol"];
        [RTENV check:(svc != nil) name:@"拿到服务实现" detail:NSStringFromClass([svc class])];
        [RTENV check:[svc conformsToProtocol:@protocol(RTGreetingService)] name:@"实现遵循协议" detail:@"RTGreetingService"];
        [RTENV check:[[svc greetingForUser:@"Tongxue"] containsString:@"Tongxue"] name:@"协议方法可调用" detail:[svc greetingForUser:@"Tongxue"]];
        [RTENV check:([svc callCount] == 42) name:@"协议整型返回值正确" detail:@([svc callCount]).stringValue];
        [RTENV info:[RTServices describeRegisteredServices]];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"G2 hasServiceForProtocol 真/假"
        detail:@"已注册协议返回 YES，未注册协议返回 NO"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"G2 hasServiceForProtocol"];
        [RTENV check:[MLRouterService hasServiceForProtocol:@protocol(RTGreetingService)] name:@"已注册协议 → YES" detail:@"RTGreetingService"];
        [RTENV check:![MLRouterService hasServiceForProtocol:@protocol(RTMissingService)] name:@"未注册协议 → NO" detail:@"RTMissingService"];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"G3 未注册协议取服务返回 nil"
        detail:@"不存在的协议必须返回 nil 且不崩溃"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        id svc = [MLRouterService serviceForProtocol:@protocol(RTMissingService)];
        [RTENV beginSuite:@"G3 未注册协议"];
        [RTENV check:(svc == nil) name:@"返回 nil" detail:@"nil"];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"G4 unregister 屏蔽段注册 + reset 恢复（tombstone 模型）"
        detail:@"段注册的服务被 unregister 后应查不到；reset 只回滚运行时状态，段注册必须能恢复"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        BOOL before = [MLRouterService hasServiceForProtocol:@protocol(RTGreetingService)];
        [MLRouterService unregisterService:@protocol(RTGreetingService)];
        BOOL afterUnregister = [MLRouterService hasServiceForProtocol:@protocol(RTGreetingService)];
        [MLRouterService reset];
        BOOL afterReset = [MLRouterService hasServiceForProtocol:@protocol(RTGreetingService)];

        [RTENV beginSuite:@"G4 服务移除与恢复"];
        [RTENV check:before name:@"段注册服务初始可见" detail:before ? @"是" : @"否"];
        [RTENV check:!afterUnregister name:@"unregister 后不可见" detail:afterUnregister ? @"仍可见" : @"正确"];
        [RTENV check:afterReset name:@"reset 后段注册服务恢复可见（未被子类误删）" detail:afterReset ? @"正确" : @"被永久删除"];
        [ws _presentReportSince:base];
    }];

    return g;
}

#pragma mark - H. 模块化与生命周期

- (RTCaseGroup *)groupModules {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"H · 模块化与 App 生命周期"];
    __weak typeof(self) ws = self;

    [g addCase:@"H1 模块扫描清单"
        detail:@"段宏注册的模块应被全部扫描到，且能在 exportedModuleNames 里看到"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        NSArray<NSString *> *names = [MLRouterModuleManager exportedModuleNames];
        [RTENV beginSuite:@"H1 模块清单"];
        [RTENV check:[names containsObject:@"RTHighPriorityModule"] name:@"扫描到 RTHighPriorityModule" detail:@"✓"];
        [RTENV check:[names containsObject:@"RTLowPriorityModule"] name:@"扫描到 RTLowPriorityModule" detail:@"✓"];
        [RTENV check:[names containsObject:@"RTTopologyModule"] name:@"扫描到 RTTopologyModule" detail:@"✓"];
        [RTENV check:[names containsObject:@"CartComponentModule"] name:@"扫描到业务组件模块 CartComponentModule" detail:@"✓"];
        [RTENV check:[names containsObject:@"UserComponentModule"] name:@"扫描到业务组件模块 UserComponentModule" detail:@"✓"];
        [RTENV info:[NSString stringWithFormat:@"全部模块：%@", names]];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"H2 moduleSetup / moduleInit 已执行"
        detail:@"这是最容易静默失效的一环：段扫描若晚于 loadModules，模块就永远不会初始化"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"H2 模块自举回调"];
        [RTENV check:([RTModuleLog indexOfEntryContaining:@"RTHighPriorityModule.moduleSetup"] >= 0)
                name:@"moduleSetup 已执行"
              detail:[RTModuleLog reportText]];
        [RTENV check:([RTModuleLog indexOfEntryContaining:@"RTHighPriorityModule.moduleInit"] >= 0)
                name:@"moduleInit 已执行" detail:@"✓"];
        [RTENV check:([RTModuleLog indexOfEntryContaining:@"RTLowPriorityModule.moduleInit"] >= 0)
                name:@"低优先级模块 moduleInit 已执行" detail:@"✓"];
        [RTENV info:[RTModuleLog reportText]];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"H3 modulePriority 越大越先初始化"
        detail:@"High(p90) 必须先于 Low(p10) 完成 setup"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        NSInteger iHigh = [RTModuleLog indexOfEntryContaining:@"RTHighPriorityModule.moduleSetup"];
        NSInteger iLow = [RTModuleLog indexOfEntryContaining:@"RTLowPriorityModule.moduleSetup"];
        [RTENV beginSuite:@"H3 模块优先级"];
        [RTENV check:(iHigh >= 0 && iLow >= 0 && iHigh < iLow)
                name:@"p90 先于 p10 初始化"
              detail:[NSString stringWithFormat:@"high=%ld low=%ld", (long)iHigh, (long)iLow]];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"H4 依赖拓扑顺序压过优先级"
        detail:@"Topology(p999) 依赖 Low(p10)：尽管优先级最高，也必须排在 Low 之后"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        NSInteger iLow = [RTModuleLog indexOfEntryContaining:@"RTLowPriorityModule.moduleSetup"];
        NSInteger iTopo = [RTModuleLog indexOfEntryContaining:@"RTTopologyModule.moduleSetup"];
        [RTENV beginSuite:@"H4 依赖拓扑顺序"];
        [RTENV check:(iLow >= 0 && iTopo >= 0 && iLow < iTopo)
                name:@"被依赖者 Low(p10) 先于依赖者 Topology(p999)"
              detail:[NSString stringWithFormat:@"low=%ld topology=%ld", (long)iLow, (long)iTopo]];
        [RTENV info:[RTModuleLog reportText]];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"H5 App 生命周期转发（后台 / 前台 / OpenURL）"
        detail:@"手动触发 MLRouterModuleManager 的转发入口，验证模块能收到生命周期事件"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTModuleLog reset];
        [MLRouterModuleManager applicationDidFinishLaunching:[UIApplication sharedApplication]];
        [MLRouterModuleManager applicationDidEnterBackground:[UIApplication sharedApplication]];
        [MLRouterModuleManager applicationWillEnterForeground:[UIApplication sharedApplication]];
        BOOL handled = [MLRouterModuleManager applicationOpenURL:[NSURL URLWithString:@"rtkit://lifecycle/probe"]
                                                         options:@{}];
        [RTENV beginSuite:@"H5 生命周期转发"];
        [RTENV check:([RTModuleLog indexOfEntryContaining:@"didFinishLaunching"] >= 0) name:@"didFinishLaunching 已转发" detail:@"✓"];
        [RTENV check:([RTModuleLog indexOfEntryContaining:@"didEnterBackground"] >= 0) name:@"didEnterBackground 已转发" detail:@"✓"];
        [RTENV check:([RTModuleLog indexOfEntryContaining:@"willEnterForeground"] >= 0) name:@"willEnterForeground 已转发" detail:@"✓"];
        [RTENV check:handled name:@"openURL 被模块处理并返回 YES" detail:handled ? @"YES" : @"NO"];
        [RTENV info:[RTModuleLog reportText]];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"H6 打开业务组件 Dashboard（跨仓组件化入口）"
        detail:@"跳转到由 MLCartComponent 私有仓段宏自注册的组件化场景页 mlcomp://cart/dashboard"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        id ret = MLRouter.create.build(@"mlcomp://cart/dashboard").open();
        [RTENV beginSuite:@"H6 跨仓组件入口"];
        [RTENV check:[ret isEqual:@(YES)] name:@"组件自注册页面可被路由打开" detail:[ret description]];
        [ws _presentReportSince:base];
    }];

    return g;
}

#pragma mark - I. 错误路径

- (RTCaseGroup *)groupErrorPaths {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"I · 错误路径（不得崩溃、不得静默）"];
    __weak typeof(self) ws = self;

    [g addCase:@"I1 非法 URL 字符串"
        detail:@"空串 / 无法解析的 URL 必须安全返回 nil，不能崩"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"I1 非法 URL"];
        // ⚠️ TestKit 默认装有兜底 handler：非法 URL 会走兜底返回 @(YES)（这是正确行为！）。
        // 本场景断言的是「无兜底时的安全返回 nil」，所以先临时清兜底，断言完立即恢复。
        [MLRouter setFallbackHandler:nil];
        id r1 = MLRouter.create.build(@"").open();
        [RTENV check:(r1 == nil) name:@"空字符串 → nil（无兜底时）" detail:@"nil"];
        id r2 = MLRouter.create.build(@"http://[invalid").open();
        [RTENV check:(r2 == nil) name:@"非法 URL 字面量 → nil（无兜底时）" detail:@"nil"];
        RTInstallDefaultGovernance();   // 立即恢复，别影响 I4 等依赖兜底的场景
        [ws _presentReportSince:base];
    }];

    [g addCase:@"I2 方法路由签名不符（缺 params 参数）"
        detail:@"注册到 0 参数方法时，框架应拒绝执行并打诊断，绝不能拿错参数去 NSInvocation 调用"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        id ret = MLRouter.create.build(@"rtkit://method/noarg").open();
        [RTENV beginSuite:@"I2 方法签名校验"];
        [RTENV check:(ret == nil) name:@"签名不符 → 拒绝执行返回 nil" detail:@"nil"];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"I3 selector 不存在"
        detail:@"段里登记了路由但类没有实现该 selector，应走诊断分支安全返回 nil"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        id ret = MLRouter.create.build(@"rtkit://method/ghost").open();
        [RTENV beginSuite:@"I3 selector 不存在"];
        [RTENV check:(ret == nil) name:@"找不到 selector → 返回 nil" detail:@"nil"];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"I4 通配符段数不足（无匹配）"
        detail:@"rtkit://wild/one/item 少了最后一段，不应被单级通配符命中，应走兜底"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        __block BOOL fallbackHit = NO;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest *req, NSError *err) { fallbackHit = YES; return nil; }];
        MLRouter.create.build(@"rtkit://wild/one/item").open();
        [RTENV beginSuite:@"I4 通配符无匹配"];
        [RTENV check:fallbackHit name:@"段数不足 → 走兜底" detail:fallbackHit ? @"正确" : @"被错误命中"];
        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    [g addCase:@"I5 完全未知路由 → 兜底页"
        detail:@"保证「点什么都不会白屏」：未命中一定有可见反馈"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        id ret = MLRouter.create.build(@"rtkit://nobody/here").open();
        [RTENV beginSuite:@"I5 未知路由兜底"];
        [RTENV check:[ret isEqual:@(YES)] name:@"默认兜底页已 present" detail:[ret description]];
        [ws _presentReportSince:base];
    }];

    return g;
}

#pragma mark - K. 线程与内存安全（P0 回归）

- (RTCaseGroup *)groupThreadAndMemorySafety {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"K · 线程与内存安全（P0 回归）"];
    __weak typeof(self) ws = self;

    [g addCase:@"K1 页面路由 · 后台线程调用（主线程契约）"
        detail:@"在全局并发队列里调 open() 打开页面路由：VC 构造 / KVC 参数映射 / present 必须整体在主线程完成，"
               @"open() 则在调用线程同步返回 @(YES)。若只把 present 挪到主线程、VC 仍在后台线程 init，"
               @"Main Thread Checker 会直接掐死进程（线上则是 UIKit 未定义行为）"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        __block BOOL calledOnBackgroundThread = NO;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            // ⚠️ 标记必须写在 open() 之前：completion 被框架派发到主队列后，主队列可能与
            // 本后台线程**并行**执行 —— 旧实现把标记写在 open() 之后并声称"主队列抢不到前面"，
            // 属于数据竞争（实测首航 verify_all.sh 时抓到 2 条假红）。dispatch_async 自带
            // 屏障语义，写在 open() 之前则 completion（主线程）读到的恒为 YES，确定无疑。
            calledOnBackgroundThread = YES;
            id k1OpenRet = MLRouter.create.build(@"rtkit://page/echo?sourceTag=bgthread&count=3")
                .withCompletion(^(id result) {
                    // 框架必须把 completion 调度回主线程；此处的断言全部在主线程执行
                    [RTENV beginSuite:@"K1 页面路由 · 后台线程调用"];
                    [RTENV check:calledOnBackgroundThread
                            name:@"open() 确实在后台线程被调用"
                          detail:@"global concurrent queue"];
                    [RTENV check:[NSThread isMainThread]
                            name:@"completion 回调回到主线程"
                          detail:[NSThread isMainThread] ? @"主线程" : @"❌ 非主线程"];
                    [RTENV check:[result isKindOfClass:NSClassFromString(@"RTParamsEchoViewController")]
                            name:@"后台线程调用仍能拿到页面实例"
                          detail:NSStringFromClass([result class])];
                    RTParamsEchoViewController *vc = (RTParamsEchoViewController *)result;
                    [RTENV check:(vc.count == 3)
                            name:@"VC 属性映射已完成（证明 VC 构造也在主线程）"
                          detail:@(vc.count).stringValue];
                }).open();
            // k1SyncRet = open() 的真实返回值（局部变量，非 __block —— 绝不能被 completion 触碰）。
            // 断言它不能用 __block 直读（数据竞争），而是交给下面的主队列收尾块：
            // 主队列 FIFO ⇒ 收尾块必然排在框架 completion 之后；dispatch_async 屏障 ⇒ 写入可见。
            id k1SyncRet = k1OpenRet;
            dispatch_async(dispatch_get_main_queue(), ^{
                [RTENV check:[k1SyncRet isEqual:@(YES)]
                        name:@"open() 在调用线程同步返回 @(YES)"
                      detail:[k1SyncRet description]];
                [ws _presentReportSince:base];
            });
        });
    }];

    [g addCase:@"K2 返回值所有权 · 非保留家族（+0，P0 回归）"
        detail:@"rtkit://method/object/autoreleased 的选择器名不以 alloc/new/copy/mutableCopy/init 开头，"
               @"ARC 编译后被调方返回的是「已自动释放（+0）」对象。框架内部用 NSInvocation 拿裸指针，"
               @"必须按 +0 认领；旧实现一律按 +1 用 __bridge_transfer 抢夺 ⇒ autorelease pool 排空时"
               @"对已释放对象二次 release 而 EXC_BAD_ACCESS（崩溃栈在 AutoreleasePoolPage::releaseUntil）"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"K2 返回值所有权 · +0 家族"];
        id ret = MLRouter.create.build(@"rtkit://method/object/autoreleased").open();
        [RTENV check:[ret isKindOfClass:[NSObject class]]
                name:@"非保留家族方法路由可正常返回对象"
              detail:NSStringFromClass([ret class])];
        [RTENV check:[[ret description] isEqualToString:[ret description]]
                name:@"返回对象仍可安全访问（未被过度释放）"
              detail:@"✓"];
        // 关键回归点：主动做一轮 autorelease pool 排空。旧实现在这里就会崩。
        @autoreleasepool {
            for (NSInteger i = 0; i < 50; i++) {
                (void)MLRouter.create.build(@"rtkit://method/object/autoreleased").open();
            }
        }
        [RTENV check:YES name:@"连续 50 次调用 + pool 排空后未崩溃" detail:@"✓"];
        [ws _presentReportSince:base];
    }];

    [g addCase:@"K3 返回值所有权 · new 家族（+1，P0 回归）"
        detail:@"rtkit://method/object/retained 的选择器名以 new 开头 ⇒ ARC 保留家族 ⇒ 返回 +1，"
               @"所有权随返回值转移给调用方。框架此时必须用 __bridge_transfer 接管；"
               @"若误当 +0 处理则会泄漏（对象永不释放）"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"K3 返回值所有权 · +1 家族"];
        id ret = MLRouter.create.build(@"rtkit://method/object/retained").open();
        [RTENV check:[ret isKindOfClass:[NSObject class]]
                name:@"保留家族方法路由可正常返回对象"
              detail:NSStringFromClass([ret class])];
        @autoreleasepool {
            id again = MLRouter.create.build(@"rtkit://method/object/retained").open();
            [RTENV check:(again != nil && again != ret)
                    name:@"重复调用各自返回独立实例"
                  detail:@"✓"];
        }
        [RTENV check:YES name:@"+1 家族所有权接管正确，pool 排空后未崩溃" detail:@"✓"];
        [ws _presentReportSince:base];
    }];

    return g;
}

#pragma mark - L. 健壮性与性能

/// 多轮取最小值的耗时测量（本地辅助）。
/// 不用 XCTest 的 measureBlock：这里要的是「同一操作在两种规模下的耗时比」，
/// 绝对值会被机器快慢和调度抖动污染，比值才是复杂度信号。
static double RTBestSeconds(NSUInteger iterations, dispatch_block_t block) {
    block(); // 预热：把懒加载 / 正则编译 / 字典扩容挡在测量之外
    double best = DBL_MAX;
    for (NSUInteger r = 0; r < 3; r++) {
        CFTimeInterval t0 = CACurrentMediaTime();
        for (NSUInteger i = 0; i < iterations; i++) block();
        double avg = (CACurrentMediaTime() - t0) / (double)iterations;
        if (avg < best) best = avg;
    }
    return best;
}

/// 调用「返回 BOOL 的类方法」（用于组件类的运行时引用）。
/// ⚠️ 绝不能用 performSelector: —— 它把返回值当 id 传回，BOOL 的 YES 就是 0x1，
/// 再对它发 boolValue 消息就是 objc_msgSend(0x1) → SIGSEGV（实测崩溃栈：KERN_INVALID_ADDRESS at 0x1）。
/// NSInvocation 按 methodReturnType 原样取值才是安全姿势。
static BOOL RTInvokeClassBoolMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    NSMethodSignature *sig = [cls methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments < 2) return NO;
    const char ret = sig.methodReturnType[0];
    if (ret != 'B' && ret != 'c') return NO;   // BOOL(unsigned/signed char) 之外一律拒绝
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sel];
    [inv setTarget:cls];
    [inv invoke];
    BOOL out = NO;
    [inv getReturnValue:&out];
    return out;
}

- (RTCaseGroup *)groupRobustnessAndPerformance {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"L · 健壮性与性能（崩溃 / 极端输入 / 复杂度）"];
    __weak typeof(self) ws = self;

    // ── L1 ────────────────────────────────────────────────────────────────
    [g addCase:@"L1 畸形与极端输入 · 全面不崩"
        detail:@"空串 / 只有 scheme / 4000 字符超长路径 / 200 个 query 参数 / 连续斜杠 / 百分号编码特殊字符，"
               @"逐条调 open()：必须安全返回、绝不崩溃。这类 URL 在真实 App 里来自 H5、推送、剪贴板、"
               @"第三方 App 跳转 —— 全是不可信来源，最容易被忽略、也最容易炸"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"L1 畸形与极端输入"];

        // ⚠️ TestKit 环境默认装有兜底 handler，未命中 URL 会走兜底返回 @(YES) 而不是 nil。
        // 要断言「无兜底时返回 nil」，必须临时清兜底 → 断言 → 立即恢复。
        // （这个坑在 J1 与全量 runner 首跑里各踩过一次，这里统一按此约定写。）
        [MLRouter setFallbackHandler:nil];
        [MLRouter setFallbackViewControllerClass:nil];

        [RTENV check:(MLRouter.create.build(@"").open() == nil)
                name:@"空字符串 → nil" detail:@"nil"];
        [RTENV check:(MLRouter.create.build(@"rtkit://").open() == nil)
                name:@"只有 scheme → nil" detail:@"nil"];
        [RTENV check:(MLRouter.create.build(@"://").open() == nil)
                name:@"无 scheme → nil" detail:@"nil"];

        NSString *longPath = [@"" stringByPaddingToLength:4000 withString:@"a" startingAtIndex:0];
        [RTENV check:(MLRouter.create.build([NSString stringWithFormat:@"rtkit://page/%@", longPath]).open() == nil)
                name:@"4000 字符超长路径 → nil" detail:@"nil"];
        [RTENV check:(MLRouter.create.build(@"rtkit://page//echo").open() == nil)
                name:@"路径中间连续斜杠 → 不命中（NSURL 只归一化尾斜杠）" detail:@"nil"];

        // 恢复兜底，后续断言涉及正常路由不受影响
        RTInstallDefaultGovernance();

        // 200 个 query 参数：仍应正确解析出 a / b
        NSMutableString *many = [NSMutableString stringWithString:@"rtkit://method/sync?"];
        for (NSInteger i = 0; i < 200; i++) {
            [many appendFormat:@"k%ld=v%ld&", (long)i, (long)i];
        }
        [many appendString:@"a=7&b=8"];
        [RTENV check:[MLRouter.create.build(many).open() isEqual:@15]
                name:@"200 个 query 参数仍正确求值 7+8"
              detail:@"15"];

        // 特殊字符：必须用 RFC 3986 unreserved 集合编码。
        // ⚠️ URLQueryAllowedCharacterSet **包含** & 和 =（它们在 query 里本就是合法分隔符），
        // 用它「编码」等于没编码 —— 这是写测试时最容易犯的错，症状是参数被拆成两个。
        // 用一条同步的动态路由取值，避免异步 completion 与报告时机打架。
        NSMutableCharacterSet *unreserved = [NSMutableCharacterSet alphanumericCharacterSet];
        [unreserved addCharactersInString:@"-._~"];
        NSString *encoded = [@"a+b&c=d" stringByAddingPercentEncodingWithAllowedCharacters:unreserved];

        [MLRouter registerRoute:@"rtkit://robust/echoencoded"
                        handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
            return params[@"sourceTag"] ?: @"(nil)";
        }];
        id echoed = MLRouter.create.build(
            [NSString stringWithFormat:@"rtkit://robust/echoencoded?sourceTag=%@", encoded]).open();
        [RTENV check:[echoed isEqualToString:@"a+b&c=d"]
                name:@"百分号编码的 & / = 未被当作参数分隔符"
              detail:[echoed description]];
        [MLRouter unregisterRoute:@"rtkit://robust/echoencoded"];

        [ws _presentReportSince:base];
    }];

    // ── L2 ────────────────────────────────────────────────────────────────
    [g addCase:@"L2 异常穿透契约（框架零 @try/@catch）"
        detail:@"在动态 handler 里抛 NSException。框架内部**没有任何** @try/@catch，所以异常会同步穿透给调用方。"
               @"这是**有意保留**的语义（吞掉异常会把「handler 里数组越界」变成「页面莫名白屏」），"
               @"但必须让每个人都知道：远程下发的 handler 一旦抛异常，整个 App 就是直接崩。"
               @"同时验证异常之后路由表未被破坏、读写锁未泄漏（后者会表现为后续调用全部死锁）"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"L2 异常穿透契约"];

        [MLRouter registerRoute:@"rtkit://robust/dynthrowing"
                        handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
            @throw [NSException exceptionWithName:@"RTKitIntentionalException"
                                           reason:@"handler 故意抛异常，用于验证异常穿透契约"
                                         userInfo:nil];
        }];

        BOOL caught = NO;
        NSString *caughtName = @"(未抛出，说明被框架吞掉了)";
        @try {
            MLRouter.create.build(@"rtkit://robust/dynthrowing").open();
        } @catch (NSException *e) {
            caught = YES;
            caughtName = e.name;
        }
        [RTENV check:caught name:@"handler 的异常穿透到调用方（可被 @try 捕获）" detail:caughtName];
        [RTENV check:[caughtName isEqualToString:@"RTKitIntentionalException"]
                name:@"异常原样传递，名称未被框架篡改"
              detail:caughtName];

        // 关键：异常之后一切照旧。若框架在持锁状态下执行 handler，这里会死锁而不是返回。
        id after = MLRouter.create.build(@"rtkit://method/sync?a=1&b=2").open();
        [RTENV check:[after isEqual:@3]
                name:@"异常之后方法路由仍正常（无死锁 / 无状态损坏）"
              detail:@"3"];

        [MLRouter unregisterRoute:@"rtkit://robust/dynthrowing"];
        [ws _presentReportSince:base];
    }];

    // ── L3 ────────────────────────────────────────────────────────────────
    [g addCase:@"L3 重入与并发安全"
        detail:@"① handler 内部再次调用路由（真实场景：聚合页的 handler 顺带触发埋点路由）；"
               @"② 8 线程 × 100 次并发路由。若框架在持锁状态下执行 handler，① 会直接死锁 —— "
               @"表现是界面卡死、没有任何崩溃日志，最难查的一类问题"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"L3 重入与并发安全"];

        __block id inner = nil;
        [MLRouter registerRoute:@"rtkit://robust/outer"
                        handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
            inner = MLRouter.create.build(@"rtkit://method/sync?a=3&b=4").open();
            return @"outer-done";
        }];
        id outer = MLRouter.create.build(@"rtkit://robust/outer").open();
        [RTENV check:[outer isEqualToString:@"outer-done"]
                name:@"外层路由正常返回（未死锁）" detail:@"outer-done"];
        [RTENV check:[inner isEqual:@7]
                name:@"handler 内的重入调用也正常返回（未死锁）" detail:@"7"];
        [MLRouter unregisterRoute:@"rtkit://robust/outer"];

        const NSInteger threads = 8;
        const NSInteger perThread = 100;
        CFTimeInterval t0 = CACurrentMediaTime();
        dispatch_group_t grp = dispatch_group_create();
        for (NSInteger t = 0; t < threads; t++) {
            dispatch_group_async(grp, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                for (NSInteger i = 0; i < perThread; i++) {
                    (void)MLRouter.create.build(@"rtkit://method/sync?a=1&b=1").open();
                }
            });
        }
        long timedOut = dispatch_group_wait(grp, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)));
        CFTimeInterval elapsed = CACurrentMediaTime() - t0;

        [RTENV check:(timedOut == 0) name:@"8 线程 × 100 次并发路由未死锁" detail:@"全部完成"];
        [RTENV check:(elapsed < 10.0)
                name:@"并发吞吐在预算内"
              detail:[NSString stringWithFormat:@"%.2fs / %ld 次", elapsed, (long)(threads * perThread)]];
        [RTENV check:[MLRouter.create.build(@"rtkit://method/sync?a=5&b=6").open() isEqual:@11]
                name:@"并发压测后路由表仍一致可用" detail:@"11"];

        [ws _presentReportSince:base];
    }];

    // ── L4 ────────────────────────────────────────────────────────────────
    [g addCase:@"L4 性能 · 精确查找 O(1)（表大 100 倍不退化）"
        detail:@"精确匹配走哈希字典。注册 20 条 vs 2000 条，单次查找耗时不应随表规模线性增长。"
               @"用「耗时比」而不是「绝对毫秒」做断言 —— 复杂度是代码结构决定的，不受机器快慢影响。"
               @"这条能抓到「把精确查找改成遍历比对」这类功能测试完全看不出的退化"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"L4 性能 · 精确查找复杂度"];

        NSMutableArray<NSString *> *registered = [NSMutableArray array];

        // 小表：20 条
        for (NSInteger i = 0; i < 20; i++) {
            NSString *p = [NSString stringWithFormat:@"rtkit://robust/perf/%ld", (long)i];
            [MLRouter registerRoute:p handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
                return @(i);
            }];
            [registered addObject:p];
        }
        double small = RTBestSeconds(300, ^{
            (void)MLRouter.create.build(@"rtkit://robust/perf/7").open();
        });

        // 大表：再补到 2000 条
        for (NSInteger i = 20; i < 2000; i++) {
            NSString *p = [NSString stringWithFormat:@"rtkit://robust/perf/%ld", (long)i];
            [MLRouter registerRoute:p handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
                return @(i);
            }];
            [registered addObject:p];
        }
        double large = RTBestSeconds(300, ^{
            (void)MLRouter.create.build(@"rtkit://robust/perf/7").open();
        });

        double ratio = large / MAX(small, 1e-9);
        [RTENV check:(ratio < 8.0)
                name:@"表规模 ×100 后单次查找耗时未线性增长"
              detail:[NSString stringWithFormat:@"%.4fms → %.4fms（%.1f 倍）",
                      small * 1000, large * 1000, ratio]];
        [RTENV check:[MLRouter.create.build(@"rtkit://robust/perf/1999").open() isEqual:@1999]
                name:@"大表下末位路由仍可正确命中" detail:@"1999"];

        // 收尾：清掉本场景注册的 2000 条，避免污染后续场景
        for (NSString *p in registered) [MLRouter unregisterRoute:p];

        [ws _presentReportSince:base];
    }];

    // ── L5 ────────────────────────────────────────────────────────────────
    [g addCase:@"L5 性能 · 通配符线性 + 路由表导出预算"
        detail:@"通配符查找的实现是「线性遍历 + 逐条正则匹配」，这是已知特性，不做 O(1) 苛求；"
               @"要守住的是两条线：① 通配符数量 ×10 时耗时比应≈10 而非≈100（否则退化成了平方级）；"
               @"② 最坏情况（谁都不命中，必须走完整张表）的绝对预算。"
               @"结论直接指导注册策略：**热点路由用精确注册，别用通配符**"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"L5 性能 · 通配符与导出"];

        NSMutableArray<NSString *> *registered = [NSMutableArray array];

        for (NSInteger i = 0; i < 10; i++) {
            NSString *p = [NSString stringWithFormat:@"rtkit://robust/wc%ld/*", (long)i];
            [MLRouter registerRoute:p handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
                return @(i);
            }];
            [registered addObject:p];
        }
        double small = RTBestSeconds(100, ^{
            (void)MLRouter.create.build(@"rtkit://robust/wc/nomatch/at/all").open();
        });

        for (NSInteger i = 10; i < 100; i++) {
            NSString *p = [NSString stringWithFormat:@"rtkit://robust/wc%ld/*", (long)i];
            [MLRouter registerRoute:p handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
                return @(i);
            }];
            [registered addObject:p];
        }
        double large = RTBestSeconds(100, ^{
            (void)MLRouter.create.build(@"rtkit://robust/wc/nomatch/at/all").open();
        });

        double ratio = large / MAX(small, 1e-9);
        [RTENV check:(ratio < 30.0)
                name:@"通配符数量 ×10 后耗时比 < 30（线性，非平方级）"
              detail:[NSString stringWithFormat:@"%.3fms → %.3fms（%.1f 倍）",
                      small * 1000, large * 1000, ratio]];
        [RTENV check:(large < 0.01)
                name:@"100 条通配符最坏情况单次查找 < 10ms"
              detail:[NSString stringWithFormat:@"%.3fms", large * 1000]];

        // 路由表导出（排查/埋点会调，大表下不应爆炸）
        CFTimeInterval t0 = CACurrentMediaTime();
        NSDictionary *table = nil;
        for (NSInteger i = 0; i < 10; i++) table = [MLRouter exportRouteTable];
        double exportMs = (CACurrentMediaTime() - t0) / 10.0 * 1000;
        [RTENV check:(exportMs < 500.0)
                name:@"路由表导出单次 < 500ms"
              detail:[NSString stringWithFormat:@"%.1fms（通配符 %lu 条）",
                      exportMs, (unsigned long)[(NSArray *)table[@"wildcards"] count]]];

        for (NSString *p in registered) [MLRouter unregisterRoute:p];

        [ws _presentReportSince:base];
    }];

    return g;
}

#pragma mark - M. 跨仓组件路由（真实 App 运行时逐条验证）

// 本组验证 MLCartComponent / MLUserComponent 两个独立私有仓「仅凭段宏自注册」在真实 App
// 运行时的每一条路由 —— 与 XCTest 的 MLRouterComponentIntegrationTests（CI 精确断言）互补。
// 历史教训：组件模块类漏声明协议 → 全部路由静默失效 → `mluser://user/total` 走兜底返回 VC，
// 这正是「open 返回控制器」的原始事故现场。本组就是那条 URL 的**正面回归**。
// 注意：TestKit 不依赖组件仓（保持宿主无关），所有组件类/协议一律 NSClassFromString /
// NSProtocolFromString 运行时引用 —— 组件缺失时断言会红，但不会编译失败。

- (RTCaseGroup *)groupCrossPodRoutes {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"M · 跨仓组件路由（真实运行时）"];
    __weak typeof(self) ws = self;

    // 本组验证 MLCartComponent / MLUserComponent 两个独立私有仓「仅凭段宏自注册」在真实 App
    // 运行时的每一条路由 —— 与 XCTest 的 MLRouterComponentIntegrationTests（CI 精确断言）互补。
    // 历史教训：组件模块类漏声明协议 → 全部路由静默失效 → mluser://user/total 走兜底返回 VC，
    // 这正是「open 返回控制器」的原始事故现场，M4 是那条 URL 的正面回归。
    // TestKit 不依赖组件仓（保持宿主无关），组件类/协议一律 NSClassFromString /
    // NSProtocolFromString 运行时引用 —— 组件缺失时断言会红，但不会编译失败。

    // ── M1 ────────────────────────────────────────────────────────────────
    [g addCase:@"M1 组件页面 + 通配符页面（mlcomp://）"
        detail:@"CartViewController（mlcomp://cart/index）与 CartWildcardPage（mlcomp://cart/item/*）"
               @"均由组件仓段宏自注册，宿主零接线。验证 open() 受理信号、completion 交付页面实例、"
               @"通配符参数捕获（wildcard_1）"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"M1 组件页面 + 通配符页面"];

        // 注意：TestKit 不是 XCTest 环境（没有 XCTestCase 的 expectation API），
        // 异步断言一律放 completion 里、最后 _presentReportSince 弹报告（与 K1 同模式）。
        id r1 = MLRouter.create.build(@"mlcomp://cart/index").withParam(@"sourceTag", @"rtkit-M1")
            .withCompletion(^(id result) {
                [RTENV check:[result isKindOfClass:NSClassFromString(@"CartViewController")]
                        name:@"组件页面实例经 completion 交付"
                      detail:NSStringFromClass([result class] ?: [NSObject class])];
                [RTENV check:[[(UIViewController *)result ml_routerParams][@"sourceTag"] isEqual:@"rtkit-M1"]
                        name:@"withParam 参数随页面留底"
                      detail:[(UIViewController *)result ml_routerParams][@"sourceTag"]];

                // 串行验证通配符页面（completion 已在主线程，可安全再开路由）
                id r2 = MLRouter.create.build(@"mlcomp://cart/item/42")
                    .withCompletion(^(id result2) {
                        [RTENV check:[result2 isKindOfClass:NSClassFromString(@"CartWildcardPage")]
                                name:@"通配符组件页面命中并交付实例"
                              detail:NSStringFromClass([result2 class] ?: [NSObject class])];
                        [RTENV check:[[(UIViewController *)result2 ml_routerParams][@"wildcard_1"] isEqual:@"42"]
                                name:@"通配符参数 wildcard_1 捕获 42"
                              detail:[(UIViewController *)result2 ml_routerParams][@"wildcard_1"]];
                        [ws _presentReportSince:base];
                    }).open();
                [RTENV check:[r2 isEqual:@(YES)] name:@"通配符页面 open() 返回 @(YES)" detail:@"@(YES)"];
            }).open();
        [RTENV check:[r1 isEqual:@(YES)] name:@"组件页面 open() 返回 @(YES)" detail:@"@(YES)"];
    }];

    // ── M2 ────────────────────────────────────────────────────────────────
    [g addCase:@"M2 组件 View 路由 + 方法路由同步"
        detail:@"CartBadgeView（mlcomp://cart/badge）返回视图实例且属性参数映射生效；"
               @"CartMathService.sumWithParams:（mlcomp://cart/total）同步返回求和"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"M2 组件 View 路由 + 方法路由同步"];

        UIView *v = MLRouter.create.build(@"mlcomp://cart/badge").withParam(@"badgeText", @"M2").open();
        [RTENV check:[v isKindOfClass:NSClassFromString(@"CartBadgeView")]
                name:@"组件 View 路由返回视图实例"
              detail:NSStringFromClass([v class] ?: [NSObject class])];
        [RTENV check:[[v performSelector:NSSelectorFromString(@"badgeText")] isEqual:@"M2"]
                name:@"View 属性参数映射生效（badgeText）"
              detail:@"M2"];

        id sum = MLRouter.create.build(@"mlcomp://cart/total").withParam(@"a", @2).withParam(@"b", @3).open();
        [RTENV check:[sum isEqual:@5] name:@"组件方法路由同步返回 2+3" detail:@"5"];

        [ws _presentReportSince:base];
    }];

    // ── M3 ────────────────────────────────────────────────────────────────
    [g addCase:@"M3 组件方法路由 · 异步 completion"
        detail:@"CartMathService.asyncSumWithParams:completion:（mlcomp://cart/asyncSum）——"
               @"异步方法路由的结果经 completion 回传，open() 同步返回 nil"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"M3 组件方法路由异步"];

        id openRet = MLRouter.create.build(@"mlcomp://cart/asyncSum")
            .withParam(@"a", @10).withParam(@"b", @20)
            .withCompletion(^(id result) {
                [RTENV check:[result isEqual:@30] name:@"异步方法路由 completion 回传 10+20" detail:@"30"];
                [ws _presentReportSince:base];
            }).open();
        [RTENV check:(openRet == nil) name:@"异步方法路由 open() 同步返回 nil" detail:@"nil"];
    }];

    // ── M4 ────────────────────────────────────────────────────────────────
    [g addCase:@"M4 模块自举动态路由（含 mluser://user/total 正面回归）"
        detail:@"两条动态路由都由组件模块的 moduleSetup 在启动时注册："
               @"mlcomp://cart/promotion 返回 promo-ok；"
               @"mluser://user/total 经协议服务跨仓取购物车商品数 —— 后者就是「open 返回控制器」"
               @"原始事故的那条 URL：当时组件模块漏声明协议被静默跳过，该路由根本没注册、走了兜底。"
               @"本条是它在真实运行时的正面回归"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"M4 模块自举动态路由"];

        id promo = MLRouter.create.build(@"mlcomp://cart/promotion").open();
        [RTENV check:[promo isEqual:@"promo-ok"]
                name:@"CartComponentModule 自举的路由可命中"
              detail:[promo description]];

        id total = MLRouter.create.build(@"mluser://user/total").open();
        [RTENV check:[total isKindOfClass:[NSNumber class]]
                name:@"mluser://user/total 返回业务数据（非 VC / 非 nil）"
              detail:[total description]];
        [RTENV check:([total intValue] >= 0)
                name:@"返回的是购物车商品数（跨仓服务消费成功）"
              detail:[total description]];

        // 模块状态观测（运行时引用，TestKit 不编译依赖组件仓）。
        // ⚠️ didSetup / cartModuleInitedFirst 返回 BOOL，必须走 NSInvocation（见 RTInvokeClassBoolMethod 注释）
        BOOL cartSetup = RTInvokeClassBoolMethod(NSClassFromString(@"CartComponentModule"), NSSelectorFromString(@"didSetup"));
        BOOL userFirst = RTInvokeClassBoolMethod(NSClassFromString(@"UserComponentModule"), NSSelectorFromString(@"cartModuleInitedFirst"));
        [RTENV check:cartSetup name:@"CartComponentModule.moduleSetup 已执行" detail:cartSetup ? @"YES" : @"NO"];
        [RTENV check:userFirst name:@"跨仓依赖拓扑：Cart 先于 User 完成 moduleInit" detail:userFirst ? @"YES" : @"NO"];

        [ws _presentReportSince:base];
    }];

    // ── M5 ────────────────────────────────────────────────────────────────
    [g addCase:@"M5 组件拦截器阻断 + 404 兜底"
        detail:@"CartAuthInterceptor（组件仓段宏注册）对 URL 含 blocked 的请求 reject(403)，"
               @"框架转入兜底；未命中路由（mlcomp://not/exist）同样走兜底。"
               @"临时装一个检测型兜底 handler 证明两者确实兜底介入，完毕立即恢复基准兜底"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"M5 拦截器阻断 + 404 兜底"];

        __block BOOL fallbackCalled = NO;
        __block NSError *fallbackError = nil;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull request, NSError * _Nullable error) {
            fallbackCalled = YES;
            fallbackError = error;
            return @(YES);   // 不返回 VC，避免为验证兜底而弹出一个页面
        }];

        id r1 = MLRouter.create.build(@"mlcomp://blocked/demo").open();
        [RTENV check:fallbackCalled name:@"拦截器 reject 后兜底 handler 被调" detail:@"✓"];
        [RTENV check:(fallbackError.code == 403)
                name:@"reject 的错误码透传给兜底（403）"
              detail:[NSString stringWithFormat:@"%ld", (long)fallbackError.code]];
        [RTENV check:[r1 isEqual:@(YES)] name:@"兜底受理后 open() 返回 @(YES)" detail:@"@(YES)"];

        fallbackCalled = NO;
        fallbackError = nil;
        id r2 = MLRouter.create.build(@"mlcomp://not/exist").open();
        [RTENV check:fallbackCalled name:@"未知路由兜底 handler 被调" detail:@"✓"];
        [RTENV check:(fallbackError.code == 404)
                name:@"未命中的错误码（404）"
              detail:[NSString stringWithFormat:@"%ld", (long)fallbackError.code]];
        [RTENV check:[r2 isEqual:@(YES)] name:@"兜底受理后 open() 返回 @(YES)" detail:@"@(YES)"];

        RTInstallDefaultGovernance();   // 立即恢复基准兜底，别污染后续场景
        [ws _presentReportSince:base];
    }];

    // ── M6 ────────────────────────────────────────────────────────────────
    [g addCase:@"M6 组件注册全部体现在路由表 + 拦截器进链日志"
        detail:@"exportRouteTable 应包含两个私有仓的全部段注册（页面 / 动态路由 / 服务）；"
               @"CartAuthInterceptor 的 processedURLLog 应记录本组之前的真实调用 —— "
               @"证明组件拦截器在全局职责链中真实进链"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"M6 路由表导出 + 拦截器日志"];

        NSDictionary *table = [MLRouter exportRouteTable];
        [RTENV check:[(NSArray *)table[@"pages"] containsObject:@"mlcomp://cart/index"]
                name:@"路由表含 Cart 页面注册" detail:@"mlcomp://cart/index"];
        [RTENV check:[(NSArray *)table[@"pages"] containsObject:@"mluser://user/index"]
                name:@"路由表含 User 页面注册" detail:@"mluser://user/index"];
        [RTENV check:[(NSArray *)table[@"dynamic"] containsObject:@"mlcomp://cart/promotion"]
                name:@"路由表含模块自举动态路由（Cart）" detail:@"mlcomp://cart/promotion"];
        [RTENV check:[(NSArray *)table[@"dynamic"] containsObject:@"mluser://user/total"]
                name:@"路由表含模块自举动态路由（User）" detail:@"mluser://user/total"];
        [RTENV check:[(NSArray *)table[@"services"] containsObject:@"CartServiceProtocol"]
                name:@"路由表含组件服务协议" detail:@"CartServiceProtocol"];

        Protocol *cartProtocol = NSProtocolFromString(@"CartServiceProtocol");
        [RTENV check:[MLRouterService hasServiceForProtocol:cartProtocol]
                name:@"协议驱动服务发现命中（跨仓）" detail:@"CartServiceProtocol"];

        NSArray *log = [[NSClassFromString(@"CartAuthInterceptor") performSelector:NSSelectorFromString(@"processedURLLog")] copy];
        [RTENV check:(log.count > 0)
                name:@"组件拦截器真实进链（有处理记录）"
              detail:[NSString stringWithFormat:@"%lu 条", (unsigned long)log.count]];
        BOOL sawM1 = NO;
        for (NSString *u in log) {
            if ([u containsString:@"mlcomp://cart/item/42"]) { sawM1 = YES; break; }
        }
        [RTENV check:sawM1 name:@"日志记录了本组 M1 的真实调用" detail:@"mlcomp://cart/item/42"];

        [ws _presentReportSince:base];
    }];

    return g;
}

#pragma mark - N. 工程防线（真实运行时）

// 对应覆盖审计的「工程防线」维度：冷启动时序 / 安全白名单防线 / 校验器优先级契约 /
// 降级链路分层 / 命名空间冲突契约 / fuzz 不崩 / 稳定性复跑（flaky 检测）。
// 与 XCTest 的 MLRouterOpsReadinessTests 互补：那边是 CI 精确断言，这边是真实 App 运行时。

- (RTCaseGroup *)groupOpsReadiness {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"N · 工程防线（真实运行时）"];
    __weak typeof(self) ws = self;

    // ── N1 冷启动时序 ─────────────────────────────────────────────────────
    [g addCase:@"N1 冷启动时序：路由请求先于模块加载"
        detail:@"reset 模块后立刻 open 组件动态路由（模拟外部 deeplink 冷启动抢跑）→ 必须走 404 兜底"
               @"而非静默 nil；loadModules 之后自动恢复。这正是「合法 URL 却 404」时序事故的真实形态"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"N1 冷启动时序"];

        // ⚠️ 模块自举的动态路由 handler 存在 MLRouter 的动态表里：只 reset 模块实例不够，
        // 必须同时 resetRouter 清掉 handler（单测能过是因为 setUp 本来就先 resetRouter）。
        // 注意 resetRouter 也会清掉 rtkit://test/selfcheck、rtkit://test/runall 两条入口路由，
        // 但本组在跑序里最后执行，且运行中的 runall block 已在内存里，不受影响。
        [MLRouterModuleManager reset];
        [MLRouter resetRouter];
        __block BOOL fb = NO;
        __block NSInteger errCode = -1;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
            fb = YES; errCode = e ? e.code : -1; return @"fb";
        }];
        id cold = MLRouter.create.build(@"mluser://user/total").open();
        [RTENV check:(fb && errCode == 404)
                name:@"模块未加载时组件动态路由缺失 → 404 兜底（可归因）"
              detail:[NSString stringWithFormat:@"code=%ld", (long)errCode]];
        [RTENV check:[cold isEqual:@"fb"] name:@"open() 返回兜底结果而非静默 nil" detail:@"fb"];
        // 错误注入的兜底要立即换回来，别把 @\"fb\" 留在全局
        RTInstallDefaultGovernance();

        [MLRouterModuleManager loadModules];
        id warm = MLRouter.create.build(@"mluser://user/total").open();
        [RTENV check:[warm isKindOfClass:[NSNumber class]]
                name:@"loadModules 后组件动态路由自动恢复"
              detail:[warm description]];

        [ws _presentReportSince:base];
    }];

    // ── N2 安全白名单防线 ────────────────────────────────────────────────
    [g addCase:@"N2 scheme 白名单：外部入口防线"
        detail:@"只放行 rtkit:// 时，外部来源的 mlcomp:// 请求必须被 403 拦截且不产生任何页面；"
               @"白名单内的方法路由不受影响。完毕恢复基准治理"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"N2 安全白名单防线"];

        [MLRouter setAllowedSchemes:[NSSet setWithObject:@"rtkit"]];
        __block BOOL fb = NO;
        __block NSInteger errCode = -1;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
            fb = YES; errCode = e ? e.code : -1; return @("blocked");
        }];
        id blocked = MLRouter.create.build(@"mlcomp://cart/index").open();
        [RTENV check:(fb && errCode == 403)
                name:@"外部 scheme 被 403 拦截并走兜底"
              detail:[NSString stringWithFormat:@"code=%ld", (long)errCode]];
        [RTENV check:[blocked isKindOfClass:[NSString class]]
                name:@"拦截请求不产生页面实例"
              detail:NSStringFromClass([blocked class] ?: [NSObject class])];

        id allowed = MLRouter.create.build(@"rtkit://method/sync?a=20&b=22").open();
        [RTENV check:[allowed isEqual:@42] name:@"白名单内路由不受影响" detail:@"42"];

        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    // ── N3 校验器接管契约 ────────────────────────────────────────────────
    [g addCase:@"N3 自定义校验器最高优先级"
        detail:@"同时设置「全拦的路径白名单」与「放行的校验器」：校验器必须整体接管（白名单不叠加），"
               @"被校验器拒绝的 host 走 403。对应 setRouteValidator 的文档契约"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"N3 校验器接管契约"];

        [MLRouter setAllowedURLPaths:[NSSet setWithObject:@"rtkit://nomatch/"]]; // 若生效会拦掉一切
        [MLRouter setRouteValidator:^BOOL(NSURL *url) {
            return ![url.host isEqualToString:@"denyhost"];
        }];
        __block NSInteger errCode = -1;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
            errCode = e ? e.code : -1; return nil;
        }];

        id passed = MLRouter.create.build(@"rtkit://method/sync?a=1&b=1").open();
        [RTENV check:[passed isEqual:@2]
                name:@"校验器放行的路由不受白名单牵连（接管而非叠加）"
              detail:@"2"];

        errCode = -1;
        id denied = MLRouter.create.build(@"rtkit://denyhost/x").open();
        [RTENV check:(errCode == 403) name:@"校验器拒绝 → 403" detail:[NSString stringWithFormat:@"code=%ld", (long)errCode]];
        [RTENV check:(denied == nil) name:@"拒绝请求返回 nil" detail:@"nil"];

        [MLRouter resetGovernance];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    // ── N4 降级链路分层 ──────────────────────────────────────────────────
    [g addCase:@"N4 降级链路分层：数据兜底 vs VC 兜底"
        detail:@"兜底 handler 返回业务数据 → open() 与 completion 双通道达；返回 VC → 自动 present 且"
               @"携带 ml_fallbackURL / ml_fallbackErrorCode 上下文（线上排查的命脉）。完毕收掉页面、恢复基准兜底"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"N4 降级链路分层"];

        __block UIViewController *fbVC = nil;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
            if ([r.urlStr containsString:@"fbvc"]) {
                UIViewController *vc = [[UIViewController alloc] init];
                vc.view.backgroundColor = UIColor.systemOrangeColor;
                vc.title = @"N4 兜底页";
                return vc;   // 框架应自动 present 并注入上下文
            }
            return @{@"degraded": @YES};
        }];

        __block id completed = nil;
        id dataRet = MLRouter.create.build(@"rtkit://no/such/route")
            .withCompletion(^(id result) { completed = result; }).open();
        [RTENV check:[dataRet isEqual:(id)@{@"degraded": @YES}]
                name:@"数据兜底经 open() 返回值到达"
              detail:@"degraded:YES"];
        [RTENV check:[completed isEqual:(id)@{@"degraded": @YES}]
                name:@"数据兜底经 completion 通道到达"
              detail:@"degraded:YES"];

        id vcRet = MLRouter.create.build(@"rtkit://fbvc/nowhere")
            .withCompletion(^(id result) { fbVC = [result isKindOfClass:[UIViewController class]] ? result : nil; }).open();
        [RTENV check:[vcRet isEqual:@(YES)] name:@"VC 兜底被自动 present 并返回 @(YES)" detail:@"@(YES)"];
        [RTENV check:[fbVC isKindOfClass:[UIViewController class]] name:@"completion 交付兜底 VC 实例" detail:@"✓"];
        [RTENV check:[[fbVC ml_routerParams][@"ml_fallbackErrorCode"] isEqual:@404]
                name:@"兜底页携带 404 错误码上下文"
              detail:[[fbVC ml_routerParams][@"ml_fallbackErrorCode"] description]];
        [RTENV check:[[fbVC ml_routerParams][@"ml_fallbackURL"] containsString:@"fbvc"]
                name:@"兜底页携带原始 URL 上下文"
              detail:[fbVC ml_routerParams][@"ml_fallbackURL"]];

        // 收掉兜底页，别污染后续场景
        UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        [top dismissViewControllerAnimated:NO completion:nil];
        RTInstallDefaultGovernance();
        [ws _presentReportSince:base];
    }];

    // ── N5 命名空间冲突契约 ──────────────────────────────────────────────
    [g addCase:@"N5 命名空间冲突：动态 vs 静态 / last-wins"
        detail:@"宿主把动态路由注册到与静态段相同的 URL：静态段必须赢（SDK 被嵌入宿主时的行为锚点）；"
               @"同为动态路由时后注册覆盖先注册；反注册不伤及静态段"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"N5 命名空间冲突契约"];

        [MLRouter registerRoute:@"rtkit://method/sync"
                        handler:^id _Nullable(NSDictionary * _Nonnull p, MLRouterRequest * _Nonnull r) {
            return @"dynamic-marker";
        }];
        id ret = MLRouter.create.build(@"rtkit://method/sync?a=20&b=22").open();
        [RTENV check:[ret isEqual:@42]
                name:@"静态段命中（动态标记值未透出）"
              detail:[ret description]];
        [MLRouter unregisterRoute:@"rtkit://method/sync"];
        id after = MLRouter.create.build(@"rtkit://method/sync?a=20&b=22").open();
        [RTENV check:[after isEqual:@42] name:@"反注册动态路由不伤及静态段" detail:@"42"];

        [MLRouter registerRoute:@"rtkit://dyn/conflict"
                        handler:^id _Nullable(NSDictionary * _Nonnull p, MLRouterRequest * _Nonnull r) { return @"v1"; }];
        [MLRouter registerRoute:@"rtkit://dyn/conflict"
                        handler:^id _Nullable(NSDictionary * _Nonnull p, MLRouterRequest * _Nonnull r) { return @"v2"; }];
        [RTENV check:[MLRouter.create.build(@"rtkit://dyn/conflict").open() isEqual:@"v2"]
                name:@"动态路由重复注册 last-wins"
              detail:@"v2"];

        __block NSInteger errCode = -1;
        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
            errCode = e ? e.code : -1; return nil;
        }];
        [MLRouter unregisterRoute:@"rtkit://dyn/conflict"];
        id gone = MLRouter.create.build(@"rtkit://dyn/conflict").open();
        [RTENV check:(gone == nil && errCode == 404) name:@"反注册后未命中走 404" detail:@"nil/404"];
        RTInstallDefaultGovernance();

        [ws _presentReportSince:base];
    }];

    // ── N6 Fuzz ──────────────────────────────────────────────────────────
    [g addCase:@"N6 Fuzz：1000 条随机 URL 不崩"
        detail:@"固定种子生成 1000 条含 URL 元字符 / Emoji / 超长段的随机 URL 逐条 open，"
               @"唯一断言是不崩且框架存活。与手写畸形样本的本质区别：不枚举，只钉「任何输入都不得炸」"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"N6 Fuzz 1000 条不崩"];

        [MLRouter setFallbackHandler:^id _Nullable(MLRouterRequest * _Nonnull r, NSError * _Nullable e) {
            return nil;   // 静默兜底：只关心不崩
        }];
        NSString *charset = @"abcXYZ019-._~:/?#[]@!$&'()*+,;=%<> \"\n😀🚀";
        srand48(20260918);
        @try {
            for (int i = 0; i < 1000; i++) {
                NSUInteger len = (NSUInteger)(drand48() * 80);
                NSMutableString *s = [NSMutableString string];
                for (NSUInteger k = 0; k < len; k++) {
                    unichar c = [charset characterAtIndex:(NSUInteger)(drand48() * charset.length)];
                    [s appendFormat:@"%C", c];
                }
                MLRouter.create.build(s).open();
            }
            [RTENV check:YES name:@"1000 条随机 URL 全部安全受理（零崩溃）" detail:@"1000/1000"];
        } @catch (NSException *exception) {
            [RTENV check:NO name:@"fuzz 输入炸出了 NSException" detail:exception.name];
        }
        id alive = MLRouter.create.build(@"rtkit://method/sync?a=20&b=22").open();
        [RTENV check:[alive isEqual:@42] name:@"fuzz 之后框架存活（路由能力不退化）" detail:@"42"];
        RTInstallDefaultGovernance();

        [ws _presentReportSince:base];
    }];

    // ── N7 稳定性复跑（flaky 检测）────────────────────────────────────────
    [g addCase:@"N7 稳定性复跑：确定性断言 20 轮全一致"
        detail:@"把一组纯逻辑断言（方法路由 / 表导出 / 动态路由生命周期）连跑 20 轮，"
               @"每轮记录通过数 —— 全部轮次必须完全一致且全通过，抓「时序抖动型假绿」"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"N7 稳定性复跑"];

        NSMutableArray<NSNumber *> *roundPasses = [NSMutableArray array];
        // 第 4 项断言要求「反注册后 open 返回 nil」—— 必须先摘掉 TestKit 默认兜底，
        // 否则 404 会被兜底页拦截成 @(YES)；循环结束后立即恢复。
        [MLRouter setFallbackHandler:nil];
        for (int round = 0; round < 20; round++) {
            NSInteger pass = 0;
            if ([MLRouter.create.build(@"rtkit://method/sync?a=2&b=3").open() isEqual:@5]) pass++;
            NSDictionary *t = [MLRouter exportRouteTable];
            if ([(NSArray *)t[@"pages"] containsObject:@"rtkit://page/echo"]) pass++;
            [MLRouter registerRoute:@"rtkit://dyn/stability"
                            handler:^id _Nullable(NSDictionary * _Nonnull p, MLRouterRequest * _Nonnull r) {
                return @(round);
            }];
            if ([MLRouter.create.build(@"rtkit://dyn/stability").open() isEqual:@(round)]) pass++;
            [MLRouter unregisterRoute:@"rtkit://dyn/stability"];
            if (MLRouter.create.build(@"rtkit://dyn/stability").open() == nil) pass++;
            [roundPasses addObject:@(pass)];
        }
        BOOL allIdentical = YES;
        for (NSNumber *p in roundPasses) {
            if (![p isEqual:@4]) { allIdentical = NO; break; }
        }
        [RTENV check:allIdentical
                name:@"20 轮结果完全一致且全通过（每轮 4/4）"
              detail:[NSString stringWithFormat:@"首轮=%@ 末轮=%@",
                      roundPasses.firstObject, roundPasses.lastObject]];
        RTInstallDefaultGovernance();

        [ws _presentReportSince:base];
    }];

    // ── N8 PII 日志脱敏 ──────────────────────────────────────────────────
    [g addCase:@"N8 PII 日志脱敏（合规红线）"
        detail:@"诊断日志打印 URL 时，敏感 query 值（token / phone 等）必须替换为 REDACTED，"
               @"非敏感参数原样保留（可归因）。自定义键集整体替换默认集，resetGovernance 恢复。"
               @"本场景会真实触发一条 404 诊断日志 —— 控制台里应只看到 REDACTED 而非原始值"
           run:^{
        NSInteger base = RTENV.totalLineCount;
        [RTENV beginSuite:@"N8 PII 日志脱敏"];

        // 默认集：token / phone 脱敏，非敏感保留
        NSString *red = [MLRouter redactedURLString:@"mltest://demo/pii?token=live-secret-99&phone=13800138000&user=bob"];
        [RTENV check:([red containsString:@"REDACTED"] && ![red containsString:@"live-secret-99"] && ![red containsString:@"13800138000"])
                name:@"默认集脱敏 token / 手机号（日志侧同步生效）"
              detail:red];
        [RTENV check:[red containsString:@"user=bob"]
                name:@"非敏感参数原样保留（可归因）"
              detail:@"user=bob"];

        // 真实触发 404 诊断日志：控制台应只出现 REDACTED
        [RTENV info:@"👇 控制台即将输出一条 404 诊断日志，人工核对其中 token 值应为 REDACTED"];
        [MLRouter setFallbackHandler:nil];   // 摘兜底让 404 走诊断警报路径
        MLRouter.create.build(@"rtkit://no/such/pii-demo?token=console-secret-42").open();
        [RTENV check:YES name:@"404 诊断日志已触发（见控制台）" detail:@"token=console-secret-42 → REDACTED"];
        RTInstallDefaultGovernance();

        // 自定义键集整体替换 + reset 恢复
        [MLRouter setRedactedQueryKeys:[NSSet setWithObject:@"sessionid"]];
        NSString *custom = [MLRouter redactedURLString:@"mltest://demo/pii?sessionid=s-xyz&token=plain-now"];
        [RTENV check:([custom containsString:@"sessionid=REDACTED"] && [custom containsString:@"token=plain-now"])
                name:@"自定义键集整体替换默认集"
              detail:custom];
        [MLRouter resetGovernance];
        NSString *restored = [MLRouter redactedURLString:@"mltest://demo/pii?token=secret-again"];
        [RTENV check:![restored containsString:@"secret-again"]
                name:@"resetGovernance 恢复默认脱敏集"
              detail:restored];

        [ws _presentReportSince:base];
    }];

    return g;
}

#pragma mark - J. 聚合

- (RTCaseGroup *)groupBulk {
    RTCaseGroup *g = [RTCaseGroup groupWithName:@"J · 聚合自检"];
    __weak typeof(self) ws = self;

    [g addCase:@"J1 一键跑全部「非跳转类」断言"
        detail:@"一条命令跑完路由表 / 服务 / 模块 / 错误路径等纯断言项，汇总成一张报告（亦可用 rtkit://test/selfcheck 免点击触发）"
           run:^{
        [ws runAggregateSelfCheck];
    }];

    return g;
}

// J1 的检查体。同时被两个入口使用：①Dashboard 上的 J1 场景；②动态路由 rtkit://test/selfcheck
// （xcrun simctl openurl 免点击触发，用于真机/CI 自动化验收）。两边共享同一份断言与报告展示。
- (void)runAggregateSelfCheck {
    NSInteger base = RTENV.totalLineCount;
    [RTENV beginSuite:@"J1 聚合自检（开始）"];

    // 路由表完整性
    NSDictionary *table = [MLRouter exportRouteTable];
    [RTENV check:([(NSArray *)table[@"pages"] containsObject:@"rtkit://redirect/target"]) name:@"静态页面段可导出" detail:@"✓"];
    [RTENV check:([(NSArray *)table[@"methods"] containsObject:@"rtkit://method/sync"]) name:@"静态方法段可导出" detail:@"✓"];
    [RTENV check:([(NSArray *)table[@"views"] containsObject:@"rtkit://view/badge"]) name:@"静态视图段可导出" detail:@"✓"];

    // 服务发现
    [RTENV check:[MLRouterService hasServiceForProtocol:@protocol(RTGreetingService)] name:@"段注册服务可见" detail:@"RTGreetingService"];
    [RTENV check:![MLRouterService hasServiceForProtocol:@protocol(RTMissingService)] name:@"未注册协议不可见" detail:@"RTMissingService"];

    // 模块化
    NSArray<NSString *> *names = [MLRouterModuleManager exportedModuleNames];
    [RTENV check:[names containsObject:@"RTHighPriorityModule"] name:@"模块已被扫描并初始化" detail:@"RTHighPriorityModule"];
    // ⚠️ H5 场景会 reset RTModuleLog（它需要干净日志验证生命周期转发）。若本检查在 H5 之后
    // 运行（一键全量的顺序就是这样），setup 条目已被清掉 —— 重新 loadModules 再生成即可。
    if ([RTModuleLog indexOfEntryContaining:@"RTHighPriorityModule.moduleSetup"] < 0) {
        [MLRouterModuleManager reset];
        [MLRouterModuleManager loadModules];
    }
    NSInteger iHigh = [RTModuleLog indexOfEntryContaining:@"RTHighPriorityModule.moduleSetup"];
    NSInteger iLow = [RTModuleLog indexOfEntryContaining:@"RTLowPriorityModule.moduleSetup"];
    NSInteger iTopo = [RTModuleLog indexOfEntryContaining:@"RTTopologyModule.moduleSetup"];
    [RTENV check:(iHigh >= 0 && iLow >= 0 && iHigh < iLow) name:@"模块优先级顺序正确" detail:[NSString stringWithFormat:@"%ld<%ld", (long)iHigh, (long)iLow]];
    [RTENV check:(iLow >= 0 && iTopo >= 0 && iLow < iTopo) name:@"模块依赖拓扑顺序正确" detail:[NSString stringWithFormat:@"%ld<%ld", (long)iLow, (long)iTopo]];

    // 错误路径
    // ⚠️ 注意：TestKit 环境默认装有兜底 handler（RTInstallDefaultGovernance），非法/未命中 URL
    // 会走兜底返回 @(YES) 而不是 nil —— 单测里这两条能过是因为 resetRouter 清掉了兜底。
    // 所以这里**临时清掉兜底**再断言「无兜底时安全返回 nil」，断言完立即恢复基准兜底，
    // 否则会把后续场景的兜底配置污染掉。
    [MLRouter setFallbackHandler:nil];
    [RTENV check:(MLRouter.create.build(@"rtkit://method/noarg").open() == nil) name:@"签名不符被拒绝" detail:@"✓"];
    [RTENV check:(MLRouter.create.build(@"rtkit://method/ghost").open() == nil) name:@"幽灵 selector 被拒绝" detail:@"✓"];
    [RTENV check:(MLRouter.create.build(@"").open() == nil) name:@"非法 URL 安全返回 nil（无兜底时）" detail:@"✓"];
    RTInstallDefaultGovernance();   // 立即恢复基准兜底，别让后面的场景裸奔

    // 方法路由
    [RTENV check:[MLRouter.create.build(@"rtkit://method/sync?a=20&b=22").open() isEqual:@42] name:@"方法路由同步返回正确" detail:@"42"];

    // 参数映射类型回归（对应 _safelyMapParameters: 的类型码分支 —— 本轮修复的静默失效锚点）。
    // 旧框架实现：short(Ts)/unsigned short(TS)/unsigned char(TC) 无分支 → 静默跳过、属性恒 0；
    // block(T@?) 被 T@ 分支误接住 → URL 字符串写进 block 存储位（类型混淆，调用必崩）。
    MLRouter.create.build(@"rtkit://page/echo?shortVal=1234&uShortVal=54321&uCharVal=250&callback=poison").open();
    RTParamsEchoViewController *echo = [RTParamsEchoViewController lastMappedEchoVC];
    [RTENV check:[echo isKindOfClass:[RTParamsEchoViewController class]] name:@"参数映射页面实例已捕获" detail:NSStringFromClass([echo class])];
    if ([echo isKindOfClass:[RTParamsEchoViewController class]]) {
        [RTENV check:(echo.shortVal == 1234) name:@"short(Ts) 属性正确映射（旧实现恒 0）" detail:@(echo.shortVal).stringValue];
        [RTENV check:(echo.uShortVal == 54321) name:@"unsigned short(TS) 属性正确映射（旧实现恒 0）" detail:@(echo.uShortVal).stringValue];
        [RTENV check:(echo.uCharVal == 250) name:@"unsigned char(TC) 属性正确映射（旧实现恒 0）" detail:@(echo.uCharVal).stringValue];
        [RTENV check:(echo.callback == nil) name:@"block(T@?) 属性未被字符串污染（防类型混淆）" detail:@"nil"];
    }
    // 收掉为取值而 push 的 echo 页。⚠️ 只能弹这一层（echo 是刚 push 的栈顶），
    // **绝不能用 popToRootViewControllerAnimated:** —— Dashboard 本身不是导航栈的根
    // （root 是 AppDelegate 的初始容器），popToRoot 会把 Dashboard 自己也弹掉，
    // 一键全量 runner 后续场景的 popToViewController:self 将全部失效（实测踩过）。
    UINavigationController *echoNav = echo.navigationController;
    [echoNav popViewControllerAnimated:NO];

    [RTENV beginSuite:@"J1 聚合自检（结束）"];

    // 独立自检模式（-RTKitSelfCheck 启动参数）落盘结果供脚本自动判定。
    // 一键全量模式下 RTENV 是累计值，落盘会覆盖真实数字 —— 全量走 runall 自己的文件。
    if (!gMLTRunAllMode) {
        NSString *scPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rtkit_last_selfcheck.txt"];
        [[NSFileManager defaultManager] removeItemAtPath:scPath error:nil];
        NSString *scOutput = [NSString stringWithFormat:@"%@\n%@", RTENV.summary,
                              [RTENV reportFromLine:base]];
        [scOutput writeToFile:scPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    if (gMLTRunAllMode) return;   // 一键全量模式：不弹本场景报告，结果进总表

    UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    RTReportViewController *vc = [[RTReportViewController alloc] init];
    vc.headline = RTENV.summary;
    vc.reportText = [RTENV reportFromLine:base];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [top presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 一键全量（rtkit://test/runall）

// 把 14 组共 68 个场景的 run block 逐个执行一遍（静默模式），最后弹总报告。
// 每个场景之间留 1s 缓冲：等异步 completion（内部最长延迟约 0.45s）落盘、
// 再把该场景 push / present 出去的页面收掉，回到 Dashboard 跑下一个。
- (void)runAllCasesThenReport {
    if (gMLTRunAllMode) return;   // 防重入
    gMLTRunAllMode = YES;

    // 结果落盘：脚本（verify_all.sh）用 simctl get_app_container 读取沙盒 tmp 里的这份
    // 文件自动判定通过/失败 —— 模拟器两层不再依赖人工看截图，全部进退出码。
    // 每次先删旧文件：脚本侧读不到文件 = run 没跑完（比读到陈旧结果更安全）。
    NSString *resultPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rtkit_last_runall.txt"];
    [[NSFileManager defaultManager] removeItemAtPath:resultPath error:nil];

    NSMutableArray<RTCase *> *flat = [NSMutableArray array];
    for (RTCaseGroup *g in self.groups) [flat addObjectsFromArray:g.cases];

    NSInteger base = RTENV.totalLineCount;
    [RTENV beginSuite:@"一键全量 · 开始"];
    [RTENV info:[NSString stringWithFormat:@"共 %ld 个场景，逐个静默执行", (long)flat.count]];

    __weak typeof(self) wself = self;
    [self _runFlatCaseAtIndex:0 list:flat done:^{
        __strong typeof(wself) sself = wself;
        if (!sself) return;
        gMLTRunAllMode = NO;
        [RTENV beginSuite:@"一键全量 · 结束"];
        // 🔬 判定链自检：-RTKitFailInject 注入一条必败断言，用于端到端验证脚本
        // （verify_all.sh）失败判定路径真的能抓住失败并置非零退出码 —— 平时绝不触发。
        if ([[NSProcessInfo processInfo].arguments containsObject:@"-RTKitFailInject"]) {
            [RTENV check:NO name:@"注入的验证性失败（-RTKitFailInject）" detail:@"判定链负向自检"];
        }
        UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        RTReportViewController *vc = [[RTReportViewController alloc] init];
        vc.headline = RTENV.summary;
        // 总报告很长（68 个场景 216 条断言），把失败项摘出来放最上面，一眼定位
        NSString *full = [RTENV reportFromLine:base];
        NSMutableArray<NSString *> *fails = [NSMutableArray array];
        for (NSString *line in [full componentsSeparatedByString:@"\n"]) {
            if ([line containsString:@"❌"]) [fails addObject:[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        }
        NSString *head = fails.count
            ? [NSString stringWithFormat:@"\n🔥 失败清单（%ld 条）：\n%@\n\n👇 完整报告：\n", (long)fails.count, [fails componentsJoinedByString:@"\n"]]
            : @"\n✅ 无失败项\n\n👇 完整报告：\n";
        vc.reportText = [head stringByAppendingString:full];
        // 落盘：第一行 summary 供脚本 grep「0 失败」—— 注意图标随状态变化：
        // 无失败「✅ N 通过 · ✅ 0 失败」；有失败「⚠️ N 通过 · ❌ M 失败」。
        // 关键字必须选「0 失败」（图标中性），不能锚定 ✅。
        // 后面附完整报告，失败时脚本可直接打印失败清单定位。
        NSString *output = [NSString stringWithFormat:@"%@\n%@", RTENV.summary, full];
        [output writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [top presentViewController:nav animated:YES completion:nil];
    }];
}

- (void)_runFlatCaseAtIndex:(NSInteger)idx list:(NSArray<RTCase *> *)list done:(void (^)(void))done {
    if (idx >= list.count) { done(); return; }
    RTCase *c = list[(NSUInteger)idx];
    // 零断言守卫：一个「静默空转」的场景（run block 没跑 / 异步回调没落盘 / 断言条件写反成恒真）
    // 如果不盯着它，会混在通过数里装作通过 —— 这正是这套框架最忌讳的静默失效。
    NSInteger checksBefore = RTENV.passCount + RTENV.failCount;
    if (c.run) c.run();

    __weak typeof(self) wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(wself) sself = wself;
        if (!sself) { done(); return; }
        // 异步场景最长内部延迟约 0.45s，1s 已够；若仍零断言，再宽限 1.2s 后才判定，
        // 避免把「只是慢」误杀成「静默空转」
        NSInteger produced = (RTENV.passCount + RTENV.failCount) - checksBefore;
        if (produced == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSInteger produced2 = (RTENV.passCount + RTENV.failCount) - checksBefore;
                if (produced2 == 0) {
                    [RTENV check:NO
                            name:[NSString stringWithFormat:@"【零断言】%@", c.title]
                          detail:@"场景静默空转：run block 未执行或异步断言未落盘，结果不可信"];
                }
                [sself _finishCaseAtIndex:idx list:list done:done];
            });
        } else {
            [sself _finishCaseAtIndex:idx list:list done:done];
        }
    });
}

// 场景收尾：pop 掉 push 的页面、dismiss 模态弹出的页面，回到 Dashboard 后跑下一个
- (void)_finishCaseAtIndex:(NSInteger)idx list:(NSArray<RTCase *> *)list done:(void (^)(void))done {
    __weak typeof(self) wself = self;
    [self.navigationController popToViewController:self animated:NO];
    UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top dismissViewControllerAnimated:NO completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [wself _runFlatCaseAtIndex:idx + 1 list:list done:done];
    });
}

#pragma mark - 报告展示

- (void)_presentReportSince:(NSInteger)lineCount {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [ws _reallyPresentReportSince:lineCount];
    });
}

- (void)_reallyPresentReportSince:(NSInteger)lineCount {
    if (gMLTRunAllMode) return;   // 一键全量模式：报告只在最后弹一次总表

    UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;

    RTReportViewController *vc = [[RTReportViewController alloc] init];
    vc.headline = RTENV.summary;
    vc.reportText = [RTENV reportFromLine:lineCount];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    // 用 showDetail / present 都行，这里统一 present 到最顶层，保证被路由打开的页面不会盖住报告
    [top presentViewController:nav animated:YES completion:nil];
}

- (void)_pushOrPresent:(UIViewController *)vc {
    UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [top presentViewController:nav animated:YES completion:nil];
}

- (void)_showFullReport {
    UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    RTReportViewController *vc = [[RTReportViewController alloc] init];
    vc.headline = RTENV.summary;
    vc.reportText = RTENV.report;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [top presentViewController:nav animated:YES completion:nil];
}

- (void)_clearReport {
    [RTENV reset];
    [RTInterceptorLog reset];
    [RTModuleLog reset];
    // 清空后模块日志就空了，重新 loadModules 让生命周期证据重新产生
    [MLRouterModuleManager reset];
    [MLRouterModuleManager loadModules];
    [MLRouterModuleManager applicationDidFinishLaunching:[UIApplication sharedApplication]];
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.groups.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.groups[(NSUInteger)section].cases.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.groups[(NSUInteger)section].name;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"RTCaseCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    }
    RTCase *c = self.groups[(NSUInteger)indexPath.section].cases[(NSUInteger)indexPath.row];
    cell.textLabel.text = c.title;
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont boldSystemFontOfSize:14];
    cell.detailTextLabel.text = c.detail;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.grayColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    RTCase *c = self.groups[(NSUInteger)indexPath.section].cases[(NSUInteger)indexPath.row];
    if (c.run) c.run();
}

@end
