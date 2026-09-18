// MLRouterService.m
#import "MLRouterService.h"
#import <objc/runtime.h>
#import <pthread/pthread.h>

// 静态表：编译期段（MLServiceSect）扫描回填的「事实」，reset 不动它
static NSMutableDictionary<NSString *, NSString *> *g_mlServiceMap = nil;
// 运行时表：registerService: 写入，优先级高于静态表，reset 只清它
static NSMutableDictionary<NSString *, NSString *> *g_mlRuntimeServiceMap = nil;
// 墓碑：被显式 unregister 的协议名，用于屏蔽静态表条目（reset 时清空即恢复）
static NSMutableSet<NSString *> *g_mlServiceTombstones = nil;
static pthread_rwlock_t g_mlServiceLock;

@implementation MLRouterService

+ (void)initialize {
    if (self == [MLRouterService class]) {
        g_mlServiceMap = [NSMutableDictionary dictionary];
        g_mlRuntimeServiceMap = [NSMutableDictionary dictionary];
        g_mlServiceTombstones = [NSMutableSet set];
        pthread_rwlock_init(&g_mlServiceLock, NULL);
    }
}

// 供 MLRouter.loadAllIsolatedRoutes 在扫描 MLServiceSect 时回调回填
+ (void)_registerServiceProtocolName:(NSString *)protocolName implClassName:(NSString *)implClassName {
    if (protocolName.length == 0 || implClassName.length == 0) return;
    pthread_rwlock_wrlock(&g_mlServiceLock);
    g_mlServiceMap[protocolName] = implClassName;
    // 段数据重新回填时撤销此前的 tombstone，避免「重新扫描却仍被屏蔽」的错位状态
    [g_mlServiceTombstones removeObject:protocolName];
    pthread_rwlock_unlock(&g_mlServiceLock);
}

// 解析协议名最终生效的实现类名。调用方需自持锁。
+ (NSString *)_resolvedImplNameLocked:(NSString *)name {
    NSString *implName = g_mlRuntimeServiceMap[name];        // 运行时优先
    if (implName.length > 0) return implName;
    if ([g_mlServiceTombstones containsObject:name]) return nil; // 已被显式移除
    return g_mlServiceMap[name];                              // 回落到编译期段注册
}

+ (BOOL)hasServiceForProtocol:(Protocol *)protocol {
    if (!protocol) return NO;
    NSString *name = NSStringFromProtocol(protocol);
    pthread_rwlock_rdlock(&g_mlServiceLock);
    BOOL has = ([self _resolvedImplNameLocked:name].length > 0);
    pthread_rwlock_unlock(&g_mlServiceLock);
    return has;
}

+ (id)serviceForProtocol:(Protocol *)protocol {
    if (!protocol) return nil;
    NSString *name = NSStringFromProtocol(protocol);
    NSString *implName = nil;
    pthread_rwlock_rdlock(&g_mlServiceLock);
    implName = [self _resolvedImplNameLocked:name];
    pthread_rwlock_unlock(&g_mlServiceLock);

    if (implName.length == 0) {
        NSLog(@"❌ [MLRouterService] 未找到协议 %@ 的服务实现（检查 MLRouterService(Protocol, Impl) 注册）", name);
        return nil;
    }
    Class impl = NSClassFromString(implName);
    if (!impl || ![impl conformsToProtocol:protocol]) {
        NSLog(@"❌ [MLRouterService] 实现类 %@ 不存在或未遵循协议 %@", implName, name);
        return nil;
    }
    return [[impl alloc] init];
}

+ (void)registerService:(Protocol *)protocol implClass:(Class)implClass {
    if (!protocol || !implClass) return;
    if (![implClass conformsToProtocol:protocol]) {
        NSLog(@"❌ [MLRouterService] %@ 未遵循协议 %@，拒绝注册", NSStringFromClass(implClass), NSStringFromProtocol(protocol));
        return;
    }
    NSString *name = NSStringFromProtocol(protocol);
    pthread_rwlock_wrlock(&g_mlServiceLock);
    g_mlRuntimeServiceMap[name] = NSStringFromClass(implClass);
    [g_mlServiceTombstones removeObject:name];
    pthread_rwlock_unlock(&g_mlServiceLock);
}

+ (void)unregisterService:(Protocol *)protocol {
    if (!protocol) return;
    NSString *name = NSStringFromProtocol(protocol);
    pthread_rwlock_wrlock(&g_mlServiceLock);
    [g_mlRuntimeServiceMap removeObjectForKey:name];
    // 若静态表里存在同名协议，需打墓碑才能真正「移除」，否则会被段注册数据顶回来
    if (g_mlServiceMap[name] != nil) [g_mlServiceTombstones addObject:name];
    pthread_rwlock_unlock(&g_mlServiceLock);
}

+ (NSArray<NSString *> *)exportedServiceProtocols {
    pthread_rwlock_rdlock(&g_mlServiceLock);
    NSMutableSet<NSString *> *names = [NSMutableSet setWithArray:g_mlServiceMap.allKeys];
    [names addObjectsFromArray:g_mlRuntimeServiceMap.allKeys];
    [names minusSet:g_mlServiceTombstones];
    NSArray *result = names.allObjects;
    pthread_rwlock_unlock(&g_mlServiceLock);
    return [result sortedArrayUsingSelector:@selector(compare:)];
}

+ (void)reset {
    pthread_rwlock_wrlock(&g_mlServiceLock);
    [g_mlRuntimeServiceMap removeAllObjects];
    [g_mlServiceTombstones removeAllObjects];
    pthread_rwlock_unlock(&g_mlServiceLock);
}

@end
