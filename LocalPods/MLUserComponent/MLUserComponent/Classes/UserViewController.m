// UserViewController.m
// 页面路由自注册。页面内通过协议头跨仓调用购物车服务 —— 不 import CartServiceImpl.h（实现隔离）。

#import "UserViewController.h"
#import <MLCartComponent/CartServiceProtocol.h>
#import <MLRouter/MLRouterHeader.h>
#import <MLRouter/MLRouterService.h>
#import <objc/runtime.h>

@implementation UserViewController

MLRouterPageClass("UserViewController", "mluser://user/index")

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.title = @"跨模块页面（User）";

    CGFloat y = 120.0;
    CGFloat w = self.view.bounds.size.width - 40;

    // 跨仓服务消费：只依赖协议头
    id<CartServiceProtocol> cart = [MLRouterService serviceForProtocol:@protocol(CartServiceProtocol)];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 60)];
    label.numberOfLines = 0;
    label.text = [NSString stringWithFormat:@"跨仓服务消费（仅 import 协议头）：\n%@ → %@ 件商品",
                  cart ? [cart componentName] : @"服务未发现",
                  cart ? @([cart itemCount]) : @"-"];
    [self.view addSubview:label];
    y += 80;

    NSArray *titles = @[
        @"调用跨模块动态路由（mluser://user/total）",
        @"返回场景 Dashboard",
    ];
    NSArray<NSURL *> *urls = @[[NSURL URLWithString:@"mluser://user/total"],
                               [NSURL URLWithString:@"mlcomp://cart/dashboard"]];
    for (NSInteger i = 0; i < titles.count; i++) {
        NSURL *url = urls[i];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(20, y, w, 44);
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.12];
        btn.layer.cornerRadius = 6;
        [btn addTarget:self action:@selector(_tapped:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(btn, @selector(description), url.absoluteString, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [self.view addSubview:btn];
        y += 56;
    }
}

- (void)_tapped:(UIButton *)sender {
    NSString *urlStr = objc_getAssociatedObject(sender, @selector(description));
    id ret = MLRouter.create.build(urlStr).open();
    if ([urlStr hasSuffix:@"total"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"跨模块动态路由"
                                                                       message:[NSString stringWithFormat:@"购物车商品数：%@", ret]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end
