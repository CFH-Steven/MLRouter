// UserComponentModule.m
// 模块自注册 + 跨仓依赖声明：moduleDependencies 返回 @[@"CartComponentModule"]，
// MLRouterModuleManager 拓扑排序保证跨仓初始化顺序（被依赖者先 init）。

#import "UserComponentModule.h"
#import <MLCartComponent/CartServiceProtocol.h>
#import <MLCartComponent/CartComponentModule.h>   // 跨仓 import 模块头（pod 依赖声明）
#import <MLRouter/MLRouterHeader.h>
#import <MLRouter/MLRouterService.h>

static BOOL g_didInit = NO;
static BOOL g_cartFirst = NO;

@implementation UserComponentModule

MLRouterModule(UserComponentModule)

+ (BOOL)didInit { return g_didInit; }
+ (BOOL)cartModuleInitedFirst { return g_cartFirst; }

// 跨仓模块依赖：声明依赖购物车组件模块
+ (NSArray<NSString *> *)moduleDependencies {
    return @[@"CartComponentModule"];
}

#pragma mark - MLRouterModule

- (void)moduleSetup {
    // 模块自举：注册本模块的动态路由，内部通过协议服务消费购物车数据
    [MLRouter registerRoute:@"mluser://user/total"
                    handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
        id<CartServiceProtocol> cart = [MLRouterService serviceForProtocol:@protocol(CartServiceProtocol)];
        return cart ? @([cart itemCount]) : nil;
    }];
}

- (void)moduleInit {
    g_didInit = YES;
    // 拓扑顺序观测：执行到此处时，被依赖的 CartComponentModule 应已完成 moduleInit
    g_cartFirst = [CartComponentModule didInit];
}

@end
