// DemoModule.m
#import <MLRouter/MLRouterHeader.h>
#import <MLRouter/MLRouterModule.h>
#import "DemoService.h"

@interface DemoModule : NSObject <MLRouterModule>
@end

@implementation DemoModule

+ (NSInteger)modulePriority { return 100; }
+ (NSArray<NSString *> *)moduleDependencies { return @[]; }

- (void)moduleSetup {
    NSLog(@"[DemoModule] moduleSetup：模块自举（注册服务/路由）");
    // 演示动态路由（运行时注册，优先级低于编译期静态段，高于 404 兜底）
    [MLRouter registerRoute:@"app://dynamic/hello"
                    handler:^id _Nullable(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request) {
        NSLog(@"[DemoModule] 动态路由被调用，params=%@", params);
        return @"dynamic-ok";
    }];
}

- (void)moduleInit {
    NSLog(@"[DemoModule] moduleInit：初始化模块私有资源");
}

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    NSLog(@"[DemoModule] applicationDidFinishLaunching");
}

MLRouterModule(DemoModule)

@end
