// MLRouterModule.m
#import "MLRouterModule.h"
#import <objc/runtime.h>
#import <pthread/pthread.h>

// 两张类清单表 —— 与服务层同构的隔离模型：
//   segment 表：由 MLModuleSect 段扫描回填的「静态事实」（App 里真实存在哪些模块），reset 不动它；
//   runtime 表：registerModuleClass: 运行时注册（测试 mock / 动态模块），reset 只清它。
// 早期只有一张表，reset 清空它 —— 但段扫描是幂等的（只成功执行一次），清掉之后再也回填不回来，
// 会让 reset 之后的 loadModules 永远拿到空列表 ⇒ 模块能力在 App 生命周期内不可恢复。
static NSMutableArray<Class> *g_mlSegmentModuleClasses = nil;          // 段扫描回填
static NSMutableArray<Class> *g_mlRuntimeModuleClasses = nil;          // 运行时注册
static NSMutableArray<id<MLRouterModule>> *g_mlModuleInstances = nil;  // 已实例化模块（单例）
static BOOL g_mlModulesLoaded = NO;
static pthread_rwlock_t g_mlModuleLock;

@implementation MLRouterModuleManager

+ (void)initialize {
    if (self == [MLRouterModuleManager class]) {
        g_mlSegmentModuleClasses = [NSMutableArray array];
        g_mlRuntimeModuleClasses = [NSMutableArray array];
        g_mlModuleInstances = [NSMutableArray array];
        pthread_rwlock_init(&g_mlModuleLock, NULL);
    }
}

// 供 MLRouter.loadAllIsolatedRoutes 在扫描 MLModuleSect 时回调
+ (void)_registerModuleClassName:(NSString *)className {
    if (className.length == 0) return;
    Class cls = NSClassFromString(className);
    if (!cls) {
        NSLog(@"❌ [MLRouterModule] 模块类 %@ 不存在", className);
        return;
    }
    if (![cls conformsToProtocol:@protocol(MLRouterModule)]) {
        NSLog(@"❌ [MLRouterModule] %@ 未遵循 MLRouterModule 协议，跳过。"
              @"请在它的 @interface 后补上 <MLRouterModule>（只写 MLRouterModule(类名) 段宏是不够的，"
              @"段宏只登记类名，框架扫描后会用 conformsToProtocol: 做准入校验）。"
              @"漏写会导致该模块的 moduleSetup / moduleInit / 生命周期钩子 / 自举动态路由全部静默失效。",
              className);
        return;
    }
    pthread_rwlock_wrlock(&g_mlModuleLock);
    if (![g_mlSegmentModuleClasses containsObject:cls]) [g_mlSegmentModuleClasses addObject:cls];
    pthread_rwlock_unlock(&g_mlModuleLock);
}

+ (void)registerModuleClass:(Class)moduleClass {
    if (!moduleClass) return;
    pthread_rwlock_wrlock(&g_mlModuleLock);
    if (![g_mlRuntimeModuleClasses containsObject:moduleClass]) [g_mlRuntimeModuleClasses addObject:moduleClass];
    pthread_rwlock_unlock(&g_mlModuleLock);
}

// 段表 ∪ 运行时表（段表在前，保证「编译期注册优先」的直觉顺序；重复项只留一份）
+ (NSArray<Class> *)_mergedModuleClassesLocked {
    NSMutableArray<Class> *merged = [NSMutableArray arrayWithArray:g_mlSegmentModuleClasses];
    for (Class cls in g_mlRuntimeModuleClasses) {
        if (![merged containsObject:cls]) [merged addObject:cls];
    }
    return merged;
}

+ (void)loadModules {
    // 🔒【P0 时序修复】必须先确保 MLRouter 的 Mach-O 段扫描已经执行完毕。
    // 模块类清单（segment 表）是由 MLRouter.loadAllIsolatedRoutes 扫描 MLModuleSect
    // 回填的，而该扫描挂在 MLRouter 的 +initialize 上 —— 懒触发。若在这里直接往下走，
    // 由于本方法通常是 App 启动后第一个碰路由框架的调用点，MLRouter 还没收到过任何消息，
    // 扫描尚未发生，模块类清单必为空 → 全部模块 moduleSetup/moduleInit 与生命周期钩子
    // 静默失效，模块自举注册的动态路由整体缺失。
    // 用 NSClassFromString + performSelector 触发，避免 MLRouter 与 MLRouterModule 头文件互相 import。
    Class routerClass = NSClassFromString(@"MLRouter");
    if (routerClass) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        SEL ensureSel = NSSelectorFromString(@"ensureRoutesLoaded");
        if ([routerClass respondsToSelector:ensureSel]) {
            [routerClass performSelector:ensureSel];
        }
#pragma clang diagnostic pop
    }

    pthread_rwlock_wrlock(&g_mlModuleLock);
    if (g_mlModulesLoaded) { pthread_rwlock_unlock(&g_mlModuleLock); return; }
    NSArray<Class> *classes = [self _mergedModuleClassesLocked];
    pthread_rwlock_unlock(&g_mlModuleLock);

    if (classes.count == 0) {
        NSLog(@"⚠️ [MLRouterModule] 未扫描到任何模块（MLModuleSect 为空）。请确认模块类使用了 MLRouterModule(类名) 段宏，且宿主开启了 -ObjC 链接标志。");
    }

    // 1. 实例化（模块为单例）
    NSMutableArray *instances = [NSMutableArray array];
    for (Class cls in classes) {
        [instances addObject:[[cls alloc] init]];
    }

    // 2. 按依赖拓扑排序（Kahn/DFS 后序），priority 作平局裁决
    NSArray *sorted = [self _topologicallySortedModules:instances];

    // 3. 先全部 moduleSetup（保证依赖方注册的服务先就位），再全部 moduleInit
    for (id<MLRouterModule> m in sorted) {
        if ([m respondsToSelector:@selector(moduleSetup)]) [m moduleSetup];
    }
    for (id<MLRouterModule> m in sorted) {
        if ([m respondsToSelector:@selector(moduleInit)]) [m moduleInit];
    }

    pthread_rwlock_wrlock(&g_mlModuleLock);
    [g_mlModuleInstances removeAllObjects];
    [g_mlModuleInstances addObjectsFromArray:sorted];
    g_mlModulesLoaded = YES;
    pthread_rwlock_unlock(&g_mlModuleLock);
}

+ (NSArray *)_topologicallySortedModules:(NSArray *)modules {
    // Kahn 入度算法（迭代，无递归/无 retain cycle）：依赖方（被依赖者）先初始化。
    NSMutableArray *result = [NSMutableArray array];
    NSMutableDictionary *byName = [NSMutableDictionary dictionary];
    NSMutableDictionary *inDegree = [NSMutableDictionary dictionary];      // name -> 入度（依赖数量）
    NSMutableDictionary *dependents = [NSMutableDictionary dictionary];  // name -> 依赖它的模块名列表

    // ⚠️【P0 修复 · 元数据接收者】modulePriority / moduleDependencies 在 MLRouterModule 协议里
    // 声明为**类方法**（+），而这里循环拿到的是**实例**。旧实现写成
    //     [m respondsToSelector:@selector(modulePriority)]
    // 在实例上查的是「实例方法表」，类方法位于元类上，永远查不到 → 恒返回 0；
    // 同理 moduleDependencies 恒被当作 @[]，**依赖边一条都没建**。
    // 直接后果：拓扑排序退化成「按数组顺序 LIFO 弹出」，文档承诺的
    // 「modulePriority 越大越先初始化」「依赖优先于优先级」全部静默失效 ——
    // 组件化里跨模块初始化顺序随机，且没有任何报错。必须用 [m class] 去问类方法。
    NSInteger (^priorityOf)(id) = ^NSInteger(id m) {
        Class cls = [m class];
        if ([cls respondsToSelector:@selector(modulePriority)]) return [cls modulePriority];
        return 0;
    };
    NSArray * (^dependenciesOf)(id) = ^NSArray *(id m) {
        Class cls = [m class];
        if ([cls respondsToSelector:@selector(moduleDependencies)]) return [cls moduleDependencies] ?: @[];
        return @[];
    };
    NSComparisonResult (^byPriority)(id, id) = ^NSComparisonResult(id a, id b) {
        // 🔒 必须排成【升序】：数组尾部即当前最高优先级。下方用 lastObject/removeLastObject 弹出，
        // 因此只有升序才能实现文档约定的「modulePriority 越大越先初始化」。
        // NSComparator 语义：返回 NSOrderedAscending 表示 a 排在 b 前面。
        // 所以 pa < pb 时返回 Ascending（小在前），排完尾部就是最大者。
        // 平局必须返回 NSOrderedSame，满足比较器的严格弱序契约。
        NSInteger pa = priorityOf(a);
        NSInteger pb = priorityOf(b);
        if (pa == pb) return NSOrderedSame;
        return (pa < pb) ? NSOrderedAscending : NSOrderedDescending;
    };

    for (id m in modules) {
        NSString *name = NSStringFromClass([m class]);
        byName[name] = m;
        inDegree[name] = @(0);
    }
    for (id m in modules) {
        NSString *name = NSStringFromClass([m class]);
        NSArray *deps = dependenciesOf(m);
        for (NSString *dep in deps) {
            if (!byName[dep]) {
                NSLog(@"❌ [MLRouterModule] %@ 依赖的模块 %@ 未注册，忽略该依赖", name, dep);
                continue;
            }
            inDegree[name] = @([inDegree[name] integerValue] + 1);
            NSMutableArray *list = dependents[dep];
            if (!list) { list = [NSMutableArray array]; dependents[dep] = list; }
            [list addObject:name];
        }
    }

    // 入度为 0 的节点入队（升序，尾部为最高优先级）
    NSMutableArray *queue = [NSMutableArray array];
    for (id m in modules) {
        if ([inDegree[NSStringFromClass([m class])] integerValue] == 0) [queue addObject:m];
    }
    [queue sortUsingComparator:byPriority];

    while (queue.count > 0) {
        id m = queue.lastObject;     // 弹出当前最高优先级
        [queue removeLastObject];
        [result addObject:m];
        NSString *name = NSStringFromClass([m class]);
        for (NSString *depName in dependents[name]) {
            NSInteger d = [inDegree[depName] integerValue] - 1;
            inDegree[depName] = @(d);
            if (d == 0) [queue addObject:byName[depName]];
        }
        [queue sortUsingComparator:byPriority];
    }

    if (result.count != modules.count) {
        NSLog(@"❌ [MLRouterModule] 检测到模块循环依赖，部分模块未初始化（已初始化的 %lu / 共 %lu）",
              (unsigned long)result.count, (unsigned long)modules.count);
    }
    return result;
}

+ (void)applicationDidFinishLaunching:(UIApplication *)application {
    pthread_rwlock_rdlock(&g_mlModuleLock);
    NSArray *arr = [g_mlModuleInstances copy];
    pthread_rwlock_unlock(&g_mlModuleLock);
    for (id<MLRouterModule> m in arr) {
        if ([m respondsToSelector:@selector(applicationDidFinishLaunching:)]) [m applicationDidFinishLaunching:application];
    }
}

+ (void)applicationDidEnterBackground:(UIApplication *)application {
    pthread_rwlock_rdlock(&g_mlModuleLock);
    NSArray *arr = [g_mlModuleInstances copy];
    pthread_rwlock_unlock(&g_mlModuleLock);
    for (id<MLRouterModule> m in arr) {
        if ([m respondsToSelector:@selector(applicationDidEnterBackground:)]) [m applicationDidEnterBackground:application];
    }
}

+ (void)applicationWillEnterForeground:(UIApplication *)application {
    pthread_rwlock_rdlock(&g_mlModuleLock);
    NSArray *arr = [g_mlModuleInstances copy];
    pthread_rwlock_unlock(&g_mlModuleLock);
    for (id<MLRouterModule> m in arr) {
        if ([m respondsToSelector:@selector(applicationWillEnterForeground:)]) [m applicationWillEnterForeground:application];
    }
}

+ (BOOL)applicationOpenURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    pthread_rwlock_rdlock(&g_mlModuleLock);
    NSArray *arr = [g_mlModuleInstances copy];
    pthread_rwlock_unlock(&g_mlModuleLock);
    BOOL handled = NO;
    for (id<MLRouterModule> m in arr) {
        if ([m respondsToSelector:@selector(applicationOpenURL:options:)]) {
            if ([m applicationOpenURL:url options:options]) handled = YES;
        }
    }
    return handled;
}

+ (void)reset {
    pthread_rwlock_wrlock(&g_mlModuleLock);
    [g_mlModuleInstances removeAllObjects];
    // 🔒 只清「运行时注册」的类，保留段扫描回填的 segment 类清单。
    // 段扫描是幂等的（MLRouter.ensureRoutesLoaded 只成功执行一次），清掉之后再也回填不回来，
    // 会让 reset 之后的 loadModules 永远拿不到编译期注册的模块 ⇒ 模块能力在 App 生命周期内
    // 不可恢复。reset 的语义是「回滚运行时状态」，不是「抹掉编译期事实」。
    // 清掉 runtime 表后测试注册的 mock 模块不再残留，配合 g_mlModulesLoaded 复位即可重复 loadModules。
    [g_mlRuntimeModuleClasses removeAllObjects];
    g_mlModulesLoaded = NO;
    pthread_rwlock_unlock(&g_mlModuleLock);
}

+ (NSArray<NSString *> *)exportedModuleNames {
    pthread_rwlock_rdlock(&g_mlModuleLock);
    NSMutableArray *names = [NSMutableArray array];
    for (id<MLRouterModule> m in g_mlModuleInstances) [names addObject:NSStringFromClass([m class])];
    pthread_rwlock_unlock(&g_mlModuleLock);
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

@end
