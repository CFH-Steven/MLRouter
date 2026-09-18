//
//  AppDelegate.m
//  RouterDemo
//
//  Created by cfh on 2026/7/29.
//

#import "AppDelegate.h"
#import "ViewController.h"
#import <MLRouter/MLRouterHeader.h>
#import <MLRouter/MLRouterModule.h>
#import <MLRouter/MLRouterService.h>

@interface AppDelegate ()

@end

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ViewController alloc] init]];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    // 组件化：扫描并按依赖拓扑排序初始化全部模块，再转发 App 生命周期。
    // 注意：loadModules 内部会先确保 MLRouter 的 Mach-O 段扫描已完成（ensureRoutesLoaded），
    // 因此这里不需要、也不应该再手动关心 +initialize 的触发时机 ——
    // 早期版本正是在此处踩过坑：loadModules 先于 MLRouter 的懒加载 initialize 执行，
    // 导致模块类清单为空、所有 moduleSetup / 生命周期钩子静默失效。
    [MLRouterModuleManager loadModules];
    [MLRouterModuleManager applicationDidFinishLaunching:application];

    // 启动直接打开「框架全能力测试 Dashboard」——每个框架能力一个真实 UI 场景（由本地私有仓
    // MLRouterTestKit 段宏自注册）。组件化场景另由 mlcomp://cart/dashboard 提供，Dashboard 内有入口。
    // 说明：全局降级兜底由 TestKit 在 Dashboard 内安装（RTInstallDefaultGovernance），
    // 因为治理层场景会反复改/清兜底，需要由同一处统一管理才不会被改乱。
    dispatch_async(dispatch_get_main_queue(), ^{
        MLRouter.create.build(@"rtkit://test/dashboard").open();
    });

    // CI / 免点击验收钩子：xcrun simctl launch <sim> <bundle> -RTKitSelfCheck
    // Dashboard 的 viewDidLoad 会注册 rtkit://test/selfcheck 动态路由（J1 聚合自检的免点击入口），
    // 这里等 Dashboard 打开后延迟触发，报告页会自动弹出。
    // 注意用 simctl openurl 打开自定义 scheme 会弹「Open in ...?」系统确认框，自动化里点不了，
    // 所以走启动参数这条路。
    if ([[NSProcessInfo processInfo].arguments containsObject:@"-RTKitSelfCheck"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            MLRouter.create.build(@"rtkit://test/selfcheck").open();
        });
    }

    // 一键全量：xcrun simctl launch <sim> <bundle> -RTKitRunAll
    // 逐个静默执行 Dashboard 全部 68 个场景的 run block，最后弹一张总报告（约 2 分钟）。
    if ([[NSProcessInfo processInfo].arguments containsObject:@"-RTKitRunAll"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            MLRouter.create.build(@"rtkit://test/runall").open();
        });
    }

    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [MLRouterModuleManager applicationDidEnterBackground:application];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [MLRouterModuleManager applicationWillEnterForeground:application];
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    return [MLRouterModuleManager applicationOpenURL:url options:options];
}

@end
