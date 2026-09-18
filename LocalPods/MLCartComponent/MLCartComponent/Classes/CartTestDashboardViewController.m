// CartTestDashboardViewController.m
// 每个组件化/模块化场景对应一个按钮，点击即路由到真实页面或执行真实路由调用。

#import "CartTestDashboardViewController.h"
#import "CartBadgeView.h"
#import "CartAuthInterceptor.h"
#import <MLRouter/MLRouterHeader.h>
#import <objc/runtime.h>

@interface CartTestDashboardViewController ()
@property (nonatomic, strong) NSMutableArray<void(^)(void)> *actions;
@end

@implementation CartTestDashboardViewController

MLRouterPageClass("CartTestDashboardViewController", "mlcomp://cart/dashboard")

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.title = @"组件化场景 Dashboard";
    self.actions = [NSMutableArray array];

    __weak typeof(self) weakSelf = self;
    CGFloat y = 96.0;
    CGFloat w = self.view.bounds.size.width - 40;

    // 说明行
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 48)];
    tip.numberOfLines = 0;
    tip.font = [UIFont systemFontOfSize:12];
    tip.textColor = UIColor.darkGrayColor;
    tip.text = @"以下场景全部由本地私有仓组件（MLCartComponent / MLUserComponent）\n经编译期段宏自注册，宿主零手动接线：";
    [self.view addSubview:tip];
    y += 56;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, y, self.view.bounds.size.width, self.view.bounds.size.height - y)];
    scroll.contentSize = CGSizeMake(self.view.bounds.size.width, 700);
    [self.view addSubview:scroll];

    CGFloat sy = 12;
    [self _addButtonToView:scroll y:&sy title:@"1. 组件页面路由（段宏自注册）" action:^{
        MLRouter.create.build(@"mlcomp://cart/index").withParam(@"sourceTag", @"dashboard").open();
    }];
    [self _addButtonToView:scroll y:&sy title:@"2. 通配符页面路由（wildcard 捕获）" action:^{
        MLRouter.create.build(@"mlcomp://cart/item/42").open();
    }];
    [self _addButtonToView:scroll y:&sy title:@"3. View 路由（返回视图实例）" action:^{
        UIView *v = MLRouter.create.build(@"mlcomp://cart/badge").withParam(@"badgeText", @"🛒 购物车 3 件").open();
        [weakSelf _presentViewDemo:v];
    }];
    [self _addButtonToView:scroll y:&sy title:@"4. 组件方法路由（同步返回）" action:^{
        id ret = MLRouter.create.build(@"mlcomp://cart/total").withParam(@"a", @2).withParam(@"b", @3).open();
        [weakSelf _showAlert:@"方法路由同步返回" message:[NSString stringWithFormat:@"2 + 3 = %@", ret]];
    }];
    [self _addButtonToView:scroll y:&sy title:@"5. 组件方法路由（异步 completion）" action:^{
        MLRouter.create.build(@"mlcomp://cart/asyncSum")
            .withParam(@"a", @10).withParam(@"b", @20)
            .withCompletion(^(id result) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf _showAlert:@"方法路由异步返回" message:[NSString stringWithFormat:@"10 + 20 = %@", result]];
                });
            }).open();
    }];
    [self _addButtonToView:scroll y:&sy title:@"6. 模块自举动态路由（moduleSetup 注册）" action:^{
        id ret = MLRouter.create.build(@"mlcomp://cart/promotion").open();
        [weakSelf _showAlert:@"模块自举动态路由" message:[NSString stringWithFormat:@"返回：%@", ret]];
    }];
    [self _addButtonToView:scroll y:&sy title:@"7. 跨模块服务消费页面（MLUserComponent）" action:^{
        MLRouter.create.build(@"mluser://user/index").open();
    }];
    [self _addButtonToView:scroll y:&sy title:@"8. 跨模块动态路由（跨仓依赖拓扑）" action:^{
        id ret = MLRouter.create.build(@"mluser://user/total").open();
        [weakSelf _showAlert:@"跨模块动态路由" message:[NSString stringWithFormat:@"购物车商品数：%@", ret]];
    }];
    [self _addButtonToView:scroll y:&sy title:@"9. 拦截器阻断 → 降级兜底（URL 含 blocked）" action:^{
        MLRouter.create.build(@"mlcomp://blocked/demo").open();
    }];
    [self _addButtonToView:scroll y:&sy title:@"10. 404 兜底演示（未知路由）" action:^{
        MLRouter.create.build(@"mlcomp://not/exist").open();
    }];
    [self _addButtonToView:scroll y:&sy title:@"11. 拦截器日志（观察进链情况）" action:^{
        [weakSelf _showAlert:@"拦截器已处理 URL" message:[CartAuthInterceptor processedURLLog].description];
    }];
    [self _addButtonToView:scroll y:&sy title:@"12. 路由表导出（exportRouteTable）" action:^{
        NSDictionary *table = [MLRouter exportRouteTable];
        [weakSelf _showAlert:@"路由表导出" message:[NSString stringWithFormat:@"%@", table]];
    }];
}

#pragma mark - helpers

- (void)_addButtonToView:(UIView *)container y:(CGFloat *)y title:(NSString *)title action:(void (^)(void))action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(20, *y, container.bounds.size.width - 40, 44);
    [btn setTitle:title forState:UIControlStateNormal];
    btn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.12];
    btn.layer.cornerRadius = 6;
    [btn addTarget:self action:@selector(_tapped:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(btn, @selector(description), action, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [container addSubview:btn];
    *y += 54;
}

- (void)_tapped:(UIButton *)sender {
    void (^action)(void) = objc_getAssociatedObject(sender, @selector(description));
    if (action) action();
}

- (void)_showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_presentViewDemo:(UIView *)view {
    if (![view isKindOfClass:[UIView class]]) {
        [self _showAlert:@"View 路由" message:[NSString stringWithFormat:@"返回类型异常：%@", view]];
        return;
    }
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = @"View 路由演示";
    vc.view.backgroundColor = UIColor.whiteColor;
    view.frame = CGRectMake(40, 160, vc.view.bounds.size.width - 80, 44);
    [vc.view addSubview:view];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

@end
