//
//  ViewController.m
//  RouterDemo
//
//  Created by cfh on 2026/7/29.
//

#import "ViewController.h"
#import <MLRouter/MLRouterHeader.h>
#import <MLRouter/MLRouterService.h>
#import "DemoService.h"
@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    UIButton *btn = [[UIButton alloc] init];
    [btn setTitle:@"跳转" forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.redColor forState:UIControlStateNormal];
    btn.frame = CGRectMake(100, 100, 100, 100);
    [btn addTarget:self action:@selector(jump) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn];
    
    UIButton *btn1 = [[UIButton alloc] init];
    [btn1 setTitle:@"服务" forState:UIControlStateNormal];
    [btn1 setTitleColor:UIColor.redColor forState:UIControlStateNormal];
    btn1.frame = CGRectMake(100, 200, 100, 100);
    [btn1 addTarget:self action:@selector(service) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn1];

    UIButton *btn2 = [[UIButton alloc] init];
    [btn2 setTitle:@"协议服务" forState:UIControlStateNormal];
    [btn2 setTitleColor:UIColor.redColor forState:UIControlStateNormal];
    btn2.frame = CGRectMake(100, 300, 120, 100);
    [btn2 addTarget:self action:@selector(protocolService) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn2];

    UIButton *btn3 = [[UIButton alloc] init];
    [btn3 setTitle:@"动态路由" forState:UIControlStateNormal];
    [btn3 setTitleColor:UIColor.redColor forState:UIControlStateNormal];
    btn3.frame = CGRectMake(100, 400, 120, 100);
    [btn3 addTarget:self action:@selector(dynamicRoute) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn3];

    UIButton *btn4 = [[UIButton alloc] init];
    [btn4 setTitle:@"404兜底" forState:UIControlStateNormal];
    [btn4 setTitleColor:UIColor.redColor forState:UIControlStateNormal];
    btn4.frame = CGRectMake(100, 500, 120, 100);
    [btn4 addTarget:self action:@selector(fallbackDemo) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn4];
    // Do any additi1onal setup after loading the view.
}

- (void)jump {
    MLRouter.create.build(@"app://Test/index")
    .withParam(@"title", @"我的")
    .open();
}

- (void)service {
    NSString *result = MLRouter.create.build(@"app://Test/service")
        .withCompletion(^(id result) {
            NSLog(@"异步返回的数据：%@",result);
        })
        .open();
    NSLog(@"服务返回的结果：%@",result);
}

// 协议驱动服务发现：调用方只依赖 DemoCartService 协议头，不依赖实现类
- (void)protocolService {
    id<DemoCartService> cart = [MLRouterService serviceForProtocol:@protocol(DemoCartService)];
    if (cart) {
        [cart addToCart:@"SKU-001"];
        NSLog(@"购物车数量：%ld", (long)[cart cartItemCount]);
    } else {
        NSLog(@"❌ 未找到 DemoCartService 实现");
    }
}

// 动态路由（运行时注册）
- (void)dynamicRoute {
    id result = MLRouter.create.build(@"app://dynamic/hello")
        .withParam(@"from", @"ViewController")
        .withCompletion(^(id res) { NSLog(@"动态路由异步返回：%@", res); })
        .open();
    NSLog(@"动态路由同步返回：%@", result);
}

// 404 兜底：未知路由触发 fallback handler
- (void)fallbackDemo {
    MLRouter.create.build(@"app://not/exist").open();
}

@end
