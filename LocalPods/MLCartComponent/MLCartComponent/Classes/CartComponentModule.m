// CartComponentModule.m
// 模块自注册：MLRouterModule(类名) —— 编译期写入 __DATA,MLModuleSect，
// 启动时由 MLRouterModuleManager 扫描 + 按依赖拓扑排序执行 moduleSetup / moduleInit。

#import "CartComponentModule.h"
#import <MLRouter/MLRouterHeader.h>

static BOOL g_didSetup = NO;
static BOOL g_didInit = NO;
static NSMutableArray<NSString *> *g_lifecycleLog = nil;

@implementation CartComponentModule

MLRouterModule(CartComponentModule)

+ (void)initialize {
    if (self == [CartComponentModule class]) {
        g_lifecycleLog = [NSMutableArray array];
    }
}

+ (BOOL)didSetup { return g_didSetup; }
+ (BOOL)didInit { return g_didInit; }
+ (NSArray<NSString *> *)lifecycleLog { return [g_lifecycleLog copy]; }

#pragma mark - MLRouterModule

// moduleSetup：注册本模块对外提供的动态路由（模块自举 = 组件对宿主零侵入）
- (void)moduleSetup {
    g_didSetup = YES;
    [g_lifecycleLog addObject:@"CartComponentModule.moduleSetup"];
    [MLRouter registerRoute:@"mlcomp://cart/promotion"
                    handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
        return @"promo-ok";
    }];
}

- (void)moduleInit {
    g_didInit = YES;
    [g_lifecycleLog addObject:@"CartComponentModule.moduleInit"];
}

#pragma mark - App 生命周期转发（可选实现）

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    [g_lifecycleLog addObject:@"CartComponentModule.didFinishLaunching"];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [g_lifecycleLog addObject:@"CartComponentModule.didEnterBackground"];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [g_lifecycleLog addObject:@"CartComponentModule.willEnterForeground"];
}

@end
