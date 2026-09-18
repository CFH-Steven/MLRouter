// CartViewController.m
// 页面路由自注册：MLRouterPageClass(类名, url)。

#import "CartViewController.h"
#import "CartServiceProtocol.h"
#import <MLRouter/MLRouterHeader.h>
#import <MLRouter/MLRouterService.h>
#import <objc/runtime.h>

@implementation CartViewController

MLRouterPageClass("CartViewController", "mlcomp://cart/index")

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor] ?: UIColor.whiteColor;
    self.title = @"组件页面（Cart）";

    CGFloat y = 120.0;

    // 1) 参数映射展示
    UILabel *paramLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, y, self.view.bounds.size.width - 40, 40)];
    paramLabel.numberOfLines = 0;
    paramLabel.text = [NSString stringWithFormat:@"收到的路由参数：%@", self.ml_routerParams ?: @{}];
    [self.view addSubview:paramLabel];
    y += 60;

    // 2) 协议服务消费展示（组件内通过服务发现拿自己的实现也可以，这里演示协议调用）
    id<CartServiceProtocol> svc = [MLRouterService serviceForProtocol:@protocol(CartServiceProtocol)];
    UILabel *svcLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, y, self.view.bounds.size.width - 40, 40)];
    svcLabel.numberOfLines = 0;
    svcLabel.text = [NSString stringWithFormat:@"协议服务：%@（%@ 件商品）",
                     svc ? [svc componentName] : @"未发现", svc ? @([svc itemCount]) : @"-"];
    [self.view addSubview:svcLabel];
    y += 60;

    // 场景跳转按钮：每个场景一个真实页面入口
    [self _addButtonWithTitle:@"跳转通配符页面（mlcomp://cart/item/42）" y:&y action:^{
        MLRouter.create.build(@"mlcomp://cart/item/42").open();
    }];
    [self _addButtonWithTitle:@"调用方法路由（同步返回 + completion）" y:&y action:^{
        id ret = MLRouter.create.build(@"mlcomp://cart/total")
            .withParam(@"a", @2).withParam(@"b", @3)
            .withCompletion(^(id result) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"方法路由"
                                                                                   message:[NSString stringWithFormat:@"结果：%@", result]
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:alert animated:YES completion:nil];
                });
            })
            .open();
        NSLog(@"[CartComponent] 方法路由同步返回：%@", ret);
    }];
    [self _addButtonWithTitle:@"打开跨模块页面（mluser://user/index）" y:&y action:^{
        MLRouter.create.build(@"mluser://user/index").open();
    }];
    [self _addButtonWithTitle:@"返回场景 Dashboard" y:&y action:^{
        MLRouter.create.build(@"mlcomp://cart/dashboard").open();
    }];
}

- (void)_addButtonWithTitle:(NSString *)title y:(CGFloat *)y action:(void (^)(void))action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(20, *y, self.view.bounds.size.width - 40, 44);
    [btn setTitle:title forState:UIControlStateNormal];
    btn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.12];
    btn.layer.cornerRadius = 6;
    [btn addTarget:self action:@selector(_buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(btn, @selector(description), action, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self.view addSubview:btn];
    *y += 56;
}

- (void)_buttonTapped:(UIButton *)sender {
    void (^action)(void) = objc_getAssociatedObject(sender, @selector(description));
    if (action) action();
}

@end
