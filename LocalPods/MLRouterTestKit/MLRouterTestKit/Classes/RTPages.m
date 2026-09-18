// RTPages.m
// 全部测试用页面 / 视图 / 方法路由宿主的定义与段宏注册。

#import "RTPages.h"
#import <MLRouter/MLRouterHeader.h>
#import <objc/runtime.h>   // ml_routerParams hook 用的 associated object API

#pragma mark - 通用小工具

// 在页面上贴一段多行文本，用于把「路由结果」直观呈现出来
static UILabel *RTMakeLabel(CGRect frame)
{
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = UIColor.darkGrayColor;
    return label;
}

#pragma mark - 1. 重定向终点页（rtkit://redirect/target）

@interface RTRedirectTargetViewController : UIViewController
@end

@implementation RTRedirectTargetViewController
MLRouterPageClass("RTRedirectTargetViewController", "rtkit://redirect/target")
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.title = @"重定向终点";
    UILabel *label = RTMakeLabel(CGRectMake(20, 120, self.view.bounds.size.width - 40, 240));
    // 重定向的关键断言依据：即便来源 URL 被改写成终点 URL，query 应当原样保留下来，
    // 所以这里能看到 origin 参数，就证明重定向只重写了 scheme://host/path，没有吃掉参数。
    label.text = [NSString stringWithFormat:
                  @"✅ 已到达重定向终点 rtkit://redirect/target\n\n"
                  @"若下面能看到 origin，说明重定向重写路径时保住了 query：\n"
                  @"  origin = %@\n\n"
                  @"ml_routerParams 留底：\n%@",
                  self.ml_routerParams[@"origin"] ?: @"(缺失 —— query 可能在重定向中被丢弃)",
                  self.ml_routerParams ?: @"(空)"];
    [self.view addSubview:label];
}
@end

#pragma mark - 2. 参数留底 + 类型映射验证页（rtkit://page/echo）

@implementation RTParamsEchoViewController

MLRouterPageClass("RTParamsEchoViewController", "rtkit://page/echo")

// J1 聚合自检的取值点：框架在「参数映射完成后」才写 ml_routerParams，借 setter 时机把实例透出。
// key 必须与框架 UIViewController (MLRouter) 分类的实现一致（同为 @selector(ml_routerParams)），
// 否则框架的读取会拿不到值。
static __weak RTParamsEchoViewController *gRTLastMappedEchoVC = nil;

- (void)setMl_routerParams:(NSDictionary *)params {
    objc_setAssociatedObject(self, @selector(ml_routerParams), params, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gRTLastMappedEchoVC = self;
}

- (NSDictionary *)ml_routerParams {
    return objc_getAssociatedObject(self, @selector(ml_routerParams));
}

+ (instancetype)lastMappedEchoVC {
    return gRTLastMappedEchoVC;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.title = @"参数映射 / 留底";

    UILabel *label = RTMakeLabel(CGRectMake(20, 100, self.view.bounds.size.width - 40, 420));
    label.text = [NSString stringWithFormat:
                  @"属性映射结果（_safelyMapParameters 按属性类型转换）\n"
                  @"  sourceTag : %@\n"
                  @"  count     : %ld\n"
                  @"  flag      : %@\n"
                  @"  ratio     : %.3f\n\n"
                  @"ml_routerParams 全量留底：\n%@",
                  self.sourceTag ?: @"(nil)",
                  (long)self.count,
                  self.flag ? @"YES" : @"NO",
                  self.ratio,
                  self.ml_routerParams ?: @"(空)"];
    [self.view addSubview:label];
}

@end

#pragma mark - 3. 单级通配符页（rtkit://wild/one/item/*）

@interface RTSingleWildcardViewController : UIViewController
@end

@implementation RTSingleWildcardViewController
MLRouterPageClass("RTSingleWildcardViewController", "rtkit://wild/one/item/*")
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.title = @"单级通配符 *";
    UILabel *label = RTMakeLabel(CGRectMake(20, 120, self.view.bounds.size.width - 40, 220));
    label.text = [NSString stringWithFormat:
                  @"✅ 命中单级通配符 rtkit://wild/one/item/*\n\n"
                  @"通配符捕获参数（最多 1 段，不跨 /）：\n%@",
                  self.ml_routerParams ?: @"(空)"];
    [self.view addSubview:label];
}
@end

#pragma mark - 4. 多级贪婪通配符页（rtkit://wild/all/**）

@interface RTMultiLevelWildcardViewController : UIViewController
@end

@implementation RTMultiLevelWildcardViewController
MLRouterPageClass("RTMultiLevelWildcardViewController", "rtkit://wild/all/**")
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.title = @"多级通配符 **";
    UILabel *label = RTMakeLabel(CGRectMake(20, 120, self.view.bounds.size.width - 40, 240));
    label.text = [NSString stringWithFormat:
                  @"✅ 命中多级贪婪通配符 rtkit://wild/all/**\n\n"
                  @"通配符捕获参数（可跨多级 /）：\n%@",
                  self.ml_routerParams ?: @"(空)"];
    [self.view addSubview:label];
}
@end

#pragma mark - 5. 多捕获通配符页（rtkit://wild/mix/*/detail/**）

@interface RTMultiCaptureViewController : UIViewController
@end

@implementation RTMultiCaptureViewController
MLRouterPageClass("RTMultiCaptureViewController", "rtkit://wild/mix/*/detail/**")
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.title = @"多捕获通配符";
    UILabel *label = RTMakeLabel(CGRectMake(20, 120, self.view.bounds.size.width - 40, 260));
    label.text = [NSString stringWithFormat:
                  @"✅ 命中多捕获通配符 rtkit://wild/mix/*/detail/**\n\n"
                  @"两个捕获段应各自归位（wildcard_1 = * 段，wildcard_2 = ** 段）：\n%@",
                  self.ml_routerParams ?: @"(空)"];
    [self.view addSubview:label];
}
@end

#pragma mark - 6. 多星号交错通配符页（rtkit://wild/multi/*/mid/*/end/**）
// 专门用来钉死「paramKeys 顺序必须与正则捕获组顺序一致」这条契约：
// 三个星号、类型交错，只要参数表与捕获组错位，页面上显示的 wildcard_1/2/3 就会串位。

@interface RTMultiStarWildcardViewController : UIViewController
@end

@implementation RTMultiStarWildcardViewController
MLRouterPageClass("RTMultiStarWildcardViewController", "rtkit://wild/multi/*/mid/*/end/**")
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.title = @"多星号交错";
    UILabel *label = RTMakeLabel(CGRectMake(20, 120, self.view.bounds.size.width - 40, 300));
    label.text = [NSString stringWithFormat:
                  @"✅ 命中 rtkit://wild/multi/*/mid/*/end/**\n\n"
                  @"按 URL 从左到右，三个捕获段应依次归位：\n"
                  @"  wildcard_1 = 第一个 * 段\n"
                  @"  wildcard_2 = 第二个 * 段\n"
                  @"  wildcard_3 = ** 剩余的整段\n\n"
                  @"实际捕获：\n%@",
                  self.ml_routerParams ?: @"(空)"];
    [self.view addSubview:label];
}
@end

#pragma mark - 7. View 路由（rtkit://view/badge）

@interface RTBadgeView : UIView
@property (nonatomic, copy) NSString *badgeText;
@end

@implementation RTBadgeView
MLRouterViewClass("RTBadgeView", "rtkit://view/badge")

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.18];
        self.layer.cornerRadius = 8.0;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)setBadgeText:(NSString *)badgeText {
    _badgeText = [badgeText copy];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    NSString *text = self.badgeText ?: @"(no badgeText)";
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:15],
                             NSForegroundColorAttributeName: UIColor.darkGrayColor };
    CGSize size = [text sizeWithAttributes:attrs];
    [text drawAtPoint:CGPointMake((rect.size.width - size.width) / 2.0,
                                  (rect.size.height - size.height) / 2.0)
       withAttributes:attrs];
}
@end

#pragma mark - 7. 方法路由宿主（同步 / 异步 / 错误签名 / 不存在的 selector）

@interface RTMethodHost : NSObject
@end

@implementation RTMethodHost

// 同步方法路由：返回 NSNumber，不接 completion block
MLRouterMethodClass("RTMethodHost", "rtkit://method/sync", "syncSum:block:")
+ (NSNumber *)syncSum:(NSDictionary *)params block:(void (^)(id))block {
    NSInteger a = [params[@"a"] integerValue];
    NSInteger b = [params[@"b"] integerValue];
    (void)block; // 同步路径不使用 block 回传
    return @(a + b);
}

// 异步方法路由：通过 block 回传结果
MLRouterMethodClass("RTMethodHost", "rtkit://method/async", "asyncEcho:block:")
+ (void)asyncEcho:(NSDictionary *)params block:(void (^)(id))block {
    NSString *tag = params[@"tag"] ?: @"(no tag)";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (block) block([NSString stringWithFormat:@"async-echo:%@", tag]);
    });
}

// ❌ 错误签名：0 参数方法的 numberOfArguments = 2 < 3，框架应拒绝并打诊断，不得崩溃
MLRouterMethodClass("RTMethodHost", "rtkit://method/noarg", "noArgMethod")
+ (NSString *)noArgMethod {
    return @"这条永远不该被路由调用 —— 签名校验应当先拦下它";
}

// 方法路由返回值所有权（P0 回归样本）
//
// 选择器名**不在** ARC 保留家族（不以 alloc/new/copy/mutableCopy/init 开头）
// ⇒ ARC 在方法返回前对该对象执行 objc_autoreleaseReturnValue，交给调用方的是 **+0（已自动释放）** 的对象。
// 框架内部用 NSInvocation 拿裸指针，必须把它当 +0 认领；若一律按 +1 用 __bridge_transfer 抢夺，
// autorelease pool 排空时就会对已释放对象二次 release ⇒ EXC_BAD_ACCESS（崩溃栈在 AutoreleasePoolPage）。
MLRouterMethodClass("RTMethodHost", "rtkit://method/object/autoreleased", "makeEphemeralObject:")
+ (id)makeEphemeralObject:(NSDictionary *)params {
    return [NSObject new];
}

// 选择器名以 "new" 开头 ⇒ ARC 保留家族 ⇒ 返回 **+1**，所有权随返回值转移。
// 框架必须用 __bridge_transfer 接管，若当成 +0 处理则会泄漏。
MLRouterMethodClass("RTMethodHost", "rtkit://method/object/retained", "newBoxedObject:")
+ (id)newBoxedObject:(NSDictionary *)params {
    return (id)[NSObject new];
}

@end

#pragma mark - 8. selector 不存在（类存在但没有实现该方法）

@interface RTGhostSelectorHost : NSObject
@end

@implementation RTGhostSelectorHost
// 只注册路由元数据，绝不实现 ghostMethod: —— 框架应走「找不到 selector」诊断分支
MLRouterMethodClass("RTGhostSelectorHost", "rtkit://method/ghost", "ghostMethod:")
@end

#pragma mark - 9. 兜底页

@implementation RTFallbackViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGrayColor;
    self.title = @"兜底页";
    UILabel *label = RTMakeLabel(CGRectMake(20, 140, self.view.bounds.size.width - 40, 200));
    label.textAlignment = NSTextAlignmentCenter;
    label.text = @"⚠️ 这是 setFallbackViewControllerClass: 指定的兜底页\n（走到这里说明路由未命中或被拦截）";
    [self.view addSubview:label];
}
@end

#pragma mark - 10. 重定向链（编译期 MLRedirectSect 段注册）

// 一级：from → target
MLRouterRedirect("rtkit://redirect/from", "rtkit://redirect/target")

// 多级：hop1 → hop2 → target（框架需在一次 open 内递归解析完整条链）
MLRouterRedirect("rtkit://redirect/hop1", "rtkit://redirect/hop2")
MLRouterRedirect("rtkit://redirect/hop2", "rtkit://redirect/target")

// 环路：loopA ↔ loopB 互指（框架有 16 跳防环上限，必须放弃解析而不是死循环）
MLRouterRedirect("rtkit://redirect/loopA", "rtkit://redirect/loopB")
MLRouterRedirect("rtkit://redirect/loopB", "rtkit://redirect/loopA")
