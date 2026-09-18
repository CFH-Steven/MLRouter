// RTModules.m
// 三个测试模块，一次覆盖两项模块化契约：
//   ① modulePriority 越大越先初始化；
//   ② moduleDependencies 的拓扑顺序优先于 modulePriority（被依赖者必须先于依赖者）。

#import "RTModules.h"
#import <UIKit/UIKit.h>
#import <MLRouter/MLRouterHeader.h>
#import <MLRouter/MLRouterModule.h>

#pragma mark - 观测日志

static NSMutableArray<NSString *> *g_rtModuleLog = nil;

@implementation RTModuleLog

+ (void)initialize {
    if (self == [RTModuleLog class]) {
        g_rtModuleLog = [NSMutableArray array];
    }
}

+ (void)append:(NSString *)entry {
    if (entry.length == 0) return;
    @synchronized (g_rtModuleLog) {
        [g_rtModuleLog addObject:entry];
    }
}

+ (NSArray<NSString *> *)entries {
    @synchronized (g_rtModuleLog) {
        return [g_rtModuleLog copy];
    }
}

+ (void)reset {
    @synchronized (g_rtModuleLog) {
        [g_rtModuleLog removeAllObjects];
    }
}

+ (NSInteger)indexOfEntryContaining:(NSString *)keyword {
    NSArray<NSString *> *snapshot = [self entries];
    for (NSInteger i = 0; i < (NSInteger)snapshot.count; i++) {
        if ([snapshot[i] containsString:keyword]) return i;
    }
    return -1;
}

+ (NSString *)reportText {
    NSArray<NSString *> *snapshot = [self entries];
    if (snapshot.count == 0) return @"(模块日志为空 —— 说明模块没有被初始化)";
    NSMutableArray *lines = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)snapshot.count; i++) {
        [lines addObject:[NSString stringWithFormat:@"%02ld  %@", (long)i, snapshot[i]]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

@end

#pragma mark - 模块 A：高优先级、无依赖（应最先被初始化）

@interface RTHighPriorityModule : NSObject <MLRouterModule>
@end

@implementation RTHighPriorityModule

MLRouterModule(RTHighPriorityModule)

+ (NSInteger)modulePriority { return 90; }
+ (NSArray<NSString *> *)moduleDependencies { return @[]; }

- (void)moduleSetup {
    [RTModuleLog append:@"RTHighPriorityModule.moduleSetup"];
}
- (void)moduleInit {
    [RTModuleLog append:@"RTHighPriorityModule.moduleInit"];
}
- (void)applicationDidFinishLaunching:(UIApplication *)application {
    [RTModuleLog append:@"RTHighPriorityModule.didFinishLaunching"];
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
    [RTModuleLog append:@"RTHighPriorityModule.didEnterBackground"];
}
- (void)applicationWillEnterForeground:(UIApplication *)application {
    [RTModuleLog append:@"RTHighPriorityModule.willEnterForeground"];
}
- (BOOL)applicationOpenURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    [RTModuleLog append:[NSString stringWithFormat:@"RTHighPriorityModule.openURL:%@", url.absoluteString]];
    return YES;
}

@end

#pragma mark - 模块 B：低优先级、无依赖（应排在高优先级之后）

@interface RTLowPriorityModule : NSObject <MLRouterModule>
@end

@implementation RTLowPriorityModule

MLRouterModule(RTLowPriorityModule)

+ (NSInteger)modulePriority { return 10; }
+ (NSArray<NSString *> *)moduleDependencies { return @[]; }

- (void)moduleSetup {
    [RTModuleLog append:@"RTLowPriorityModule.moduleSetup"];
}
- (void)moduleInit {
    [RTModuleLog append:@"RTLowPriorityModule.moduleInit"];
}

@end

#pragma mark - 模块 C：最高优先级，但依赖模块 B（拓扑必须压过优先级）

@interface RTTopologyModule : NSObject <MLRouterModule>
@end

@implementation RTTopologyModule

MLRouterModule(RTTopologyModule)

// 注意：这里是刻意的「反直觉」配置 —— 优先级最高却声明依赖低优先级模块。
// 若框架搞错顺序（按优先级硬排），拓扑断言必挂。
+ (NSInteger)modulePriority { return 999; }
+ (NSArray<NSString *> *)moduleDependencies { return @[@"RTLowPriorityModule"]; }

- (void)moduleSetup {
    [RTModuleLog append:@"RTTopologyModule.moduleSetup"];
}
- (void)moduleInit {
    [RTModuleLog append:@"RTTopologyModule.moduleInit"];
}

@end
