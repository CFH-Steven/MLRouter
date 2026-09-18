
#import "MLRouter.h"
#import "MLRouterHeader.h"
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <objc/runtime.h>
#import <pthread/pthread.h>
#import "MLWildcardRouteModel.h"
#import "MLRouterService.h"
#import "MLRouterModule.h"

// objc-arc.h 不在公开 SDK 头文件里，但该函数是 libobjc 公开导出符号（iOS 5+ / macOS 10.7+）。
// 它是「认领一个自动释放返回值」的标准手段：能同时正确处理
// ① 被调方真的 objc_autorelease 过（则本调用只做 retain，池里的 pending release 稍后自然抵消）
// ② 被调方走了 objc_autoreleaseReturnValue 的优化路径、把对象暂存在 TLS 里没真正入池
//    （则本调用直接消费那个 +1，避免泄漏）
// 属性必须显式标 ns_returns_retained，否则 ARC 会以为返回的是 +0。
extern id objc_retainAutoreleasedReturnValue(id obj) __attribute__((ns_returns_retained));

#pragma mark - ARC 方法家族判定

/// 判断一条方法路由的返回值是 +1（所有权随返回值转移）还是 +0（已自动释放）。
///
/// 这就是 ARC 在**调用点**做的判断，规则来自 Clang 的 ARC 方法家族约定：
/// 选择器首个冒号前的首段若以 `alloc` / `new` / `copy` / `mutableCopy` / `init` 开头，
/// 且该前缀后面**不是小写字母**，则属于「保留家族」，返回 +1；否则一律 +0。
/// （`newspaper` 不算 `new` 家族，`initWithXxx` 算 `init` 家族 —— 正是靠「后一个字符不能是小写字母」区分。）
///
/// ⚠️ 为什么必须做这个区分（P0 崩溃根因）：
/// 框架内部用 NSInvocation 调方法，拿到的只是一个裸指针，没有 ARC 在调用点替我们判断家族。
/// 旧实现不分青红皂白一律 `(__bridge_transfer id)` 抢所有权。而方法路由绝大多数是普通名字
/// （如 `makeObjectWithParams:`），ARC 编译的被调方返回的是**已自动释放（+0）**的对象 ——
/// 它已经挂在 autorelease pool 上等着被释放。此时再 `__bridge_transfer` 等于多抢一份所有权，
/// 于是本次 runloop / XCTest 的池排空时，池对**已被释放**的对象再 objc_release ⇒ SIGSEGV。
/// 崩溃栈落在 AutoreleasePoolPage::releaseUntil，与路由代码毫无关联，极难定位；
/// 且是否触发取决于 autorelease 返回值优化标记的归属，表现为「偶发崩溃」。
static BOOL MLRouterSelectorReturnsRetained(SEL selector) {
    if (!selector) return NO;
    NSString *name = NSStringFromSelector(selector);
    NSRange colon = [name rangeOfString:@":"];
    NSString *head = (colon.location == NSNotFound) ? name : [name substringToIndex:colon.location];
    static NSArray<NSString *> *families = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        families = @[@"alloc", @"new", @"copy", @"mutableCopy", @"init"];
    });
    for (NSString *family in families) {
        if (![head hasPrefix:family]) continue;
        if (head.length == family.length) return YES;          // 恰好就是 alloc / new / copy ...
        unichar next = [head characterAtIndex:family.length];
        if (!(next >= 'a' && next <= 'z')) return YES;         // 前缀后紧跟非小写字母才算家族成员
    }
    return NO;
}
@implementation UIViewController (MLRouter)

- (void)setMl_routerParams:(NSDictionary *)ml_routerParams {
    objc_setAssociatedObject(self, @selector(ml_routerParams), ml_routerParams, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSDictionary *)ml_routerParams {
    return objc_getAssociatedObject(self, @selector(ml_routerParams));
}

@end

@implementation MLRouter

// 物理三表精确哈希匹配静态字典 (O(1) 性能最优路径)
static NSMutableDictionary<NSString *, NSString *> *g_mlPageMap = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *g_mlMethodMap = nil;
static NSMutableDictionary<NSString *, NSString *> *g_mlViewMap = nil;

// 全网 404 自愈资产双向大名单映射字典
static NSMutableDictionary<NSString *, NSString *> *g_mlClassSanityCheckMap = nil;
// 编译期本地硬重定向重写映射字典
static NSMutableDictionary<NSString *, NSString *> *g_mlRedirectMap = nil;

// 物理三表万能路径星号 * 模糊检索二级正则兜底表
static NSMutableArray<MLWildcardRouteModel *> *g_mlPageWildcards = nil;
static NSMutableArray<MLWildcardRouteModel *> *g_mlMethodWildcards = nil;
static NSMutableArray<MLWildcardRouteModel *> *g_mlViewWildcards = nil;

// 全网全自动抓取并根据优先级排好序的全局静态拦截链表（存 Class，执行时再实例化，避免单例状态污染）
static NSMutableArray<Class> *g_mlGlobalInterceptors = nil;
static pthread_rwlock_t g_mlRwLock; // 高并发多线程精细读写锁

// 动态路由（运行时/远程下发注册，优先级低于编译期静态段，高于 404 兜底）
static NSMutableDictionary<NSString *, id> *g_mlDynamicExactMap = nil;
static NSMutableArray<MLWildcardRouteModel *> *g_mlDynamicWildcards = nil;
// 治理层：安全白名单 + 降级兜底
static NSSet<NSString *> *g_mlAllowedSchemes = nil;
static NSSet<NSString *> *g_mlAllowedPaths = nil;
static BOOL (^g_mlRouteValidator)(NSURL *url) = nil;
static id (^g_mlFallbackHandler)(MLRouterRequest *request, NSError *error) = nil;
static Class g_mlFallbackVCClass = nil;
// 🔒 PII 脱敏键集（nil = 用默认集；空集 = 关闭脱敏）
static NSSet<NSString *> *g_mlRedactedQueryKeys = nil;

// 段扫描幂等标志：受 g_mlEnsureLock 保护（不能用 g_mlRwLock，loadAllIsolatedRoutes 内部会持它）
static BOOL g_mlRoutesLoaded = NO;
static pthread_mutex_t g_mlEnsureLock = PTHREAD_MUTEX_INITIALIZER;

+ (void)initialize {
    if (self == [MLRouter class]) {
        g_mlPageMap = [NSMutableDictionary dictionary];
        g_mlMethodMap = [NSMutableDictionary dictionary];
        g_mlViewMap = [NSMutableDictionary dictionary];
        g_mlClassSanityCheckMap = [NSMutableDictionary dictionary];
        g_mlRedirectMap = [NSMutableDictionary dictionary];
        g_mlGlobalInterceptors = [NSMutableArray array];
        g_mlDynamicExactMap = [NSMutableDictionary dictionary];
        g_mlDynamicWildcards = [NSMutableArray array];
        
        g_mlPageWildcards = [NSMutableArray array];
        g_mlMethodWildcards = [NSMutableArray array];
        g_mlViewWildcards = [NSMutableArray array];
        
        pthread_rwlock_init(&g_mlRwLock, NULL);
        [self ensureRoutesLoaded];
    }
}

// 🔒 幂等的段扫描入口。+initialize 会自动走一次；外部依赖路由表就绪的代码应显式调用。
// 独立互斥锁而非读写锁：loadAllIsolatedRoutes 自身会反复加 g_mlRwLock 写锁，
// 若此处用同一把锁则必然自锁死；且 +initialize 保证首次进入时单线程，无并发风险。
+ (void)ensureRoutesLoaded {
    pthread_mutex_lock(&g_mlEnsureLock);
    if (!g_mlRoutesLoaded) {
        [self loadAllIsolatedRoutes];
        g_mlRoutesLoaded = YES;
    }
    pthread_mutex_unlock(&g_mlEnsureLock);
}

+ (MLRouter *)create {
    return [[MLRouter alloc] init];
}

// 纯粹的万能路径多星号/双星号贪婪位置序列化状态机 [INDEX]
+ (void)_parseWildcardPath:(NSString *)path intoArray:(NSMutableArray *)wildcardArray info:(id)info {
    if (![path containsString:@"*"]) return;

    // 🔒【P1 修复】单次从左到右扫描，保证 paramKeys 顺序与正则捕获组编号顺序**严格一一对应**。
    // 旧实现是「先整体扫一遍所有 ** ，再整体扫一遍所有 *」，两轮各自替换正则串里最左的那个星号。
    // 当星号类型交错出现时（例如 a/*/b/**/c/*），第二轮插入的 ([^/]+) 会插到第一轮已经放好的 (.+)
    // 前面，于是 paramKeys 的顺序与捕获组顺序错位 —— 捕获值被写进错误的参数名里。
    // 两个星号的简单场景（a/*/b/** 或 a/**/b/*）因为顺序恰好一致而看不出问题，属于潜伏缺陷。
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    NSMutableString *pattern = [NSMutableString string];
    NSInteger asteriskCounter = 1;
    NSUInteger i = 0;
    NSUInteger len = path.length;

    while (i < len) {
        unichar c = [path characterAtIndex:i];
        if (c == '*') {
            BOOL isGreedy = (i + 1 < len) && [path characterAtIndex:i + 1] == '*';
            [keys addObject:[NSString stringWithFormat:@"wildcard_%ld", (long)asteriskCounter++]];
            [pattern appendString:(isGreedy ? @"(.+)" : @"([^/]+)")];
            i += (isGreedy ? 2 : 1);
            continue;
        }
        // 转义正则元字符，防止 URL 里的 . ? ( ) 等被当成正则语法
        if (c == '.' || c == '$' || c == '^' || c == '?' || c == '+' ||
            c == '(' || c == ')' || c == '[' || c == ']' || c == '{' ||
            c == '}' || c == '|' || c == '\\') {
            [pattern appendFormat:@"\\%C", c];
        } else {
            [pattern appendFormat:@"%C", c];
        }
        i++;
    }

    NSString *regexPattern = [NSString stringWithFormat:@"^%@$", pattern];
    NSError *error = nil;
    NSRegularExpression *finalRegex = [NSRegularExpression regularExpressionWithPattern:regexPattern
                                                                               options:NSRegularExpressionCaseInsensitive
                                                                                 error:&error];
    if (!finalRegex) {
        // 旧实现静默丢弃编译失败的路由，线上只会表现为「莫名 404」，这里补上诊断
        NSLog(@"❌ [MLRouter] 通配符路由 %@ 生成的正则 %@ 编译失败：%@", path, regexPattern, error);
        return;
    }
    if (info) {
        MLWildcardRouteModel *model = [[MLWildcardRouteModel alloc] init];
        model.regex = finalRegex;
        model.paramKeys = [keys copy];
        model.routeInfo = info;
        [wildcardArray addObject:model];
    }
}

// 纯 C 语言零动态内存分配：高可用全自动文件名拆箱切片还原算法
+ (NSString *)_extractClassNameFromFilePath:(const char *)filePath {
    if (!filePath || strlen(filePath) == 0) return @"";
    const char *lastSlash = strrchr(filePath, '/');
    const char *fileNameStart = lastSlash ? (lastSlash + 1) : filePath;
    const char *lastDot = strrchr(fileNameStart, '.');
    if (!lastDot) return [NSString stringWithUTF8String:fileNameStart];
    size_t nameLength = lastDot - fileNameStart;
    if (nameLength <= 0) return @"";
    return [[NSString alloc] initWithBytes:fileNameStart length:nameLength encoding:NSUTF8StringEncoding];
}

// 智能类名解析：新显式类名宏写入的是真实类名字符串（如 "TestViewController"，不含 "/")，
// 旧宏写入的是 __FILE__ 文件路径（含 "/" 与 ".m" 后缀）。据此自动区分，
// 路径走文件名推导，否则直接当类名，根治"文件名 != 类名"导致的静默失效。
+ (NSString *)_resolveClassName:(const char *)rawName {
    if (!rawName || strlen(rawName) == 0) return nil;
    NSString *s = [NSString stringWithUTF8String:rawName];
    if ([s containsString:@"/"] || [s hasSuffix:@".m"] || [s hasSuffix:@".h"] || [s hasSuffix:@".mm"]) {
        return [MLRouter _extractClassNameFromFilePath:rawName];
    }
    return s;
}

+ (void)loadAllIsolatedRoutes {
    uint32_t count = 0;
    uint32_t i = 0;
    unsigned long j = 0;
    unsigned long items = 0;
    const struct mach_header_64 *mhp = NULL;
    const char *imageName = NULL;
    unsigned long sectSize = 0;
    MLRouterSectionData *sectData = NULL;
    NSString *cachedClassName = nil;
    NSMutableArray *tempInterceptors = [NSMutableArray array];
    
    count = _dyld_image_count();
    for (i = 0; i < count; i++) {
        mhp = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!mhp) continue;
        
        imageName = _dyld_get_image_name(i);
        if (!imageName) continue;
        
        if (strstr(imageName, "/System/Library/") != NULL || strstr(imageName, "/usr/lib/") != NULL) {
            continue;
        }
        {
            sectSize = 0;
            sectData = (MLRouterSectionData *)getsectiondata(mhp, "__DATA", "MLPageSect", &sectSize);
            if (sectData && sectSize > 0) {
                items = sectSize / sizeof(MLRouterSectionData);
                for (j = 0; j < items; j++) {
                    if (!sectData[j].urlPath || !sectData[j].className) continue;
                    
                    NSString *p = [NSString stringWithUTF8String:sectData[j].urlPath];
                    cachedClassName = [MLRouter _resolveClassName:sectData[j].className];
                    
                    if (p.length > 0 && cachedClassName.length > 0) {
                        pthread_rwlock_wrlock(&g_mlRwLock);
                        [g_mlClassSanityCheckMap setObject:p forKey:cachedClassName];
                        if ([p containsString:@"*"]) {
                            [MLRouter _parseWildcardPath:p intoArray:g_mlPageWildcards info:cachedClassName];
                        } else {
                            g_mlPageMap[p] = cachedClassName;
                        }
                        pthread_rwlock_unlock(&g_mlRwLock);
                    }
                }
            }
        }
        {
            sectSize = 0;
            sectData = (MLRouterSectionData *)getsectiondata(mhp, "__DATA", "MLMethodSect", &sectSize);
            if (sectData && sectSize > 0) {
                items = sectSize / sizeof(MLRouterSectionData);
                for (j = 0; j < items; j++) {
                    if (!sectData[j].urlPath || !sectData[j].className || !sectData[j].selectorName) continue;
                    
                    NSString *p = [NSString stringWithUTF8String:sectData[j].urlPath];
                    NSString *s = [NSString stringWithUTF8String:sectData[j].selectorName];
                    cachedClassName = [MLRouter _resolveClassName:sectData[j].className];
                    
                    if (p.length > 0 && cachedClassName.length > 0 && s.length > 0) {
                        pthread_rwlock_wrlock(&g_mlRwLock);
                        [g_mlClassSanityCheckMap setObject:p forKey:cachedClassName];
                        NSDictionary *info = @{@"class": cachedClassName, @"selector": s};
                        if ([p containsString:@"*"]) {
                            [MLRouter _parseWildcardPath:p intoArray:g_mlMethodWildcards info:info];
                        } else {
                            g_mlMethodMap[p] = info;
                        }
                        pthread_rwlock_unlock(&g_mlRwLock);
                    }
                }
            }
        }
        {
            sectSize = 0;
            sectData = (MLRouterSectionData *)getsectiondata(mhp, "__DATA", "MLViewSect", &sectSize);
            if (sectData && sectSize > 0) {
                items = sectSize / sizeof(MLRouterSectionData);
                for (j = 0; j < items; j++) {
                    if (!sectData[j].urlPath || !sectData[j].className) continue;
                    
                    NSString *p = [NSString stringWithUTF8String:sectData[j].urlPath];
                    cachedClassName = [MLRouter _resolveClassName:sectData[j].className];
                    
                    if (p.length > 0 && cachedClassName.length > 0) {
                        pthread_rwlock_wrlock(&g_mlRwLock);
                        [g_mlClassSanityCheckMap setObject:p forKey:cachedClassName];
                        if ([p containsString:@"*"]) {
                            [MLRouter _parseWildcardPath:p intoArray:g_mlViewWildcards info:cachedClassName];
                        } else {
                            g_mlViewMap[p] = cachedClassName;
                        }
                        pthread_rwlock_unlock(&g_mlRwLock);
                    }
                }
            }
        }

        {
            sectSize = 0;
            sectData = (MLRouterSectionData *)getsectiondata(mhp, "__DATA", "MLRedirectSect", &sectSize);
            if (sectData && sectSize > 0) {
                items = sectSize / sizeof(MLRedirectSectionData);
                for (j = 0; j < items; j++) {
                    if (!sectData[j].urlPath || !sectData[j].selectorName) continue;
                    
                    NSString *fromPath = [NSString stringWithUTF8String:sectData[j].urlPath];
                    NSString *toPath = [NSString stringWithUTF8String:sectData[j].selectorName];
                    
                    if (fromPath.length > 0 && toPath.length > 0) {
                        pthread_rwlock_wrlock(&g_mlRwLock);
                        g_mlRedirectMap[fromPath] = toPath;
                        pthread_rwlock_unlock(&g_mlRwLock);
                    }
                }
            }
        }
        
        {
            sectSize = 0;
            sectData = (MLRouterSectionData *)getsectiondata(mhp, "__DATA", "MLInterceptSect", &sectSize);
            if (sectData && sectSize > 0) {
                items = sectSize / sizeof(MLRouterSectionData);
                for (j = 0; j < items; j++) {
                    if (!sectData[j].className) continue;
                    
                    cachedClassName = [MLRouter _resolveClassName:sectData[j].className];
                    NSString *pStr = sectData[j].selectorName ? [NSString stringWithUTF8String:sectData[j].selectorName] : @"100";
                    NSInteger priority = [pStr integerValue];
                    Class interceptorClass = NSClassFromString(cachedClassName);
                    
                    if (interceptorClass && [interceptorClass conformsToProtocol:@protocol(MLRouterInterceptor)]) {
                        [tempInterceptors addObject:@{@"class": interceptorClass, @"priority": @(priority)}];
                    } else if (!interceptorClass) {
                        // 段表里有类名但运行期找不到类：典型为漏加 -ObjC / 类被链接器裁剪 / 类名写错
                        NSLog(@"❌ [MLRouter] 拦截器类 %@ 不存在（段已注册但 NSClassFromString 返回 nil），该拦截器被跳过。请检查类名拼写与 -ObjC 链接标志。", cachedClassName);
                    } else {
                        // 类存在但没声明协议遵循：这是「拦截器静默不生效」的头号原因，
                        // 旧实现这里什么都不打印，线上只会表现为「埋点/鉴权切面莫名不执行」。
                        NSLog(@"❌ [MLRouter] 拦截器 %@ 未声明遵循 MLRouterInterceptor 协议（请在 @interface 后补 <MLRouterInterceptor>），该拦截器被跳过。", cachedClassName);
                    }
                }
            }
        }

        // 服务发现段 MLServiceSect：protocolName -> implClassName
        {
            sectSize = 0;
            sectData = (MLRouterSectionData *)getsectiondata(mhp, "__DATA", "MLServiceSect", &sectSize);
            if (sectData && sectSize > 0) {
                items = sectSize / sizeof(MLRouterSectionData);
                for (j = 0; j < items; j++) {
                    if (!sectData[j].urlPath || !sectData[j].className) continue;
                    NSString *protoName = [NSString stringWithUTF8String:sectData[j].urlPath];
                    NSString *implName = [NSString stringWithUTF8String:sectData[j].className];
                    if (protoName.length > 0 && implName.length > 0) {
                        [MLRouterService _registerServiceProtocolName:protoName implClassName:implName];
                    }
                }
            }
        }

        // 模块段 MLModuleSect：moduleClassName
        {
            sectSize = 0;
            sectData = (MLRouterSectionData *)getsectiondata(mhp, "__DATA", "MLModuleSect", &sectSize);
            if (sectData && sectSize > 0) {
                items = sectSize / sizeof(MLRouterSectionData);
                for (j = 0; j < items; j++) {
                    if (!sectData[j].className) continue;
                    NSString *clsName = [NSString stringWithUTF8String:sectData[j].className];
                    if (clsName.length > 0) [MLRouterModuleManager _registerModuleClassName:clsName];
                }
            }
        }
    }
    
    if (tempInterceptors.count > 0) {
        [tempInterceptors sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
            return [obj1[@"priority"] compare:obj2[@"priority"]];
        }];
        pthread_rwlock_wrlock(&g_mlRwLock);
        for (NSDictionary *dict in tempInterceptors) {
            [g_mlGlobalInterceptors addObject:dict[@"class"]];
        }
        pthread_rwlock_unlock(&g_mlRwLock);
    }
    
    // 🔒 通配符表确定性排序：捕获段数（paramKeys.count）多的更具体，优先匹配，
    // 消除 dyld 加载顺序导致多通配符竞合时行为不确定的隐患。
    NSComparator wildcardCmp = ^NSComparisonResult(MLWildcardRouteModel *a, MLWildcardRouteModel *b) {
        NSInteger ca = (NSInteger)a.paramKeys.count;
        NSInteger cb = (NSInteger)b.paramKeys.count;
        if (ca != cb) return cb - ca; // 降序：多捕获优先
        NSUInteger la = [a.routeInfo description].length;
        NSUInteger lb = [b.routeInfo description].length;
        if (la != lb) return (la > lb) ? NSOrderedAscending : NSOrderedDescending;
        // 🔒 必须返回 NSOrderedSame：旧实现平局时恒定返回 Descending，违反比较器的严格弱序契约，
        // NSMutableArray 的 sort 在违反契约时行为未定义（可能乱序甚至越界）。
        return NSOrderedSame;
    };
    [g_mlPageWildcards sortUsingComparator:wildcardCmp];
    [g_mlMethodWildcards sortUsingComparator:wildcardCmp];
    [g_mlViewWildcards sortUsingComparator:wildcardCmp];
}

- (MLRouterBuildBlock)build {
    return ^MLRouterRequest *(NSString *urlStr) {
        return [[MLRouterRequest alloc] initWithURL:urlStr router:self];
    };
}

- (id)executeRequest:(MLRouterRequest *)request {
    __block id finalReturnValue = nil;
    
    [self executeInterceptorsAtIndex:0 request:request completion:^(MLRouterRequest *finalRequest, BOOL isSuccess, NSError *error) {
        if (isSuccess) {
            finalReturnValue = [self _finalRuntimeExecuteWithRequest:finalRequest];
        } else {
            // 🔒 兑现 setFallbackHandler: 的文档契约：「路由未命中或被拦截时回调」。
            // 被拦截器 reject 的路由与 404 一样走降级兜底，避免线上出现无提示的白屏。
            NSError *rejectError = error ?: [NSError errorWithDomain:@"MLRouter"
                                                                code:403
                                                            userInfo:@{NSLocalizedDescriptionKey: @"request rejected by interceptor"}];
            finalReturnValue = [self _handleFallback:finalRequest error:rejectError];
        }
    }];
    
    return finalReturnValue;
}

- (void)executeInterceptorsAtIndex:(NSUInteger)index
                           request:(MLRouterRequest *)request
                        completion:(void(^)(MLRouterRequest *req, BOOL isSuccess, NSError * _Nullable error))completion {
    // 持读锁仅做数组快照拷贝，随后立即解锁再遍历，避免持锁调用用户拦截器代码
    // （拦截器内若再次触发路由，可能重入读锁导致未定义行为）。
    NSArray<Class> *interceptors = nil;
    pthread_rwlock_rdlock(&g_mlRwLock);
    interceptors = [g_mlGlobalInterceptors copy];
    pthread_rwlock_unlock(&g_mlRwLock);
    
    NSUInteger totalCount = interceptors.count;
    if (index >= totalCount) {
        if (completion) completion(request, YES, nil);
        return;
    }
    
    // 每次执行都重新实例化拦截器，避免全局单例实例在并发/多次调用间共享可变状态。
    Class interceptorClass = interceptors[index];
    id<MLRouterInterceptor> interceptor = [[interceptorClass alloc] init];
    
    __weak typeof(self) weakSelf = self;
    [interceptor processRequest:request next:^(MLRouterRequest * _Nonnull nextRequest) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf executeInterceptorsAtIndex:(index + 1) request:nextRequest completion:completion];
        }
    } reject:^(NSError * _Nullable error) {
        if (completion) completion(request, NO, error);
    }];
}

- (id)_finalRuntimeExecuteWithRequest:(MLRouterRequest *)request {
    NSURL *url = [NSURL URLWithString:request.urlStr];
    if (!url) return nil;
    
    NSString *basePath = [NSString stringWithFormat:@"%@://%@", url.scheme, url.host];
    if (url.path.length > 0) basePath = [basePath stringByAppendingString:url.path];
    
    // 🔒 重定向链递归解析（支持 A->B->C 多级跳转），带防环上限，避免无限循环。
    NSInteger redirectGuard = 0;
    while (redirectGuard++ < 16) {
        pthread_rwlock_rdlock(&g_mlRwLock);
        NSString *redirectedPath = g_mlRedirectMap[basePath];
        pthread_rwlock_unlock(&g_mlRwLock);
        if (redirectedPath.length == 0) break;

        NSURLComponents *urlComponents = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *queryStr = urlComponents.query.length > 0 ? [NSString stringWithFormat:@"?%@", urlComponents.query] : @"";
        NSString *newFullUrl = [NSString stringWithFormat:@"%@%@", redirectedPath, queryStr];

        request.urlStr = newFullUrl;
        url = [NSURL URLWithString:newFullUrl];
        basePath = redirectedPath;
    }
    
    // 🔒 安全白名单：未通过校验的路由直接走降级兜底，杜绝 H5 等外部来源任意调 native。
    if (![self _isRouteAllowed:url basePath:basePath]) {
        return [self _handleFallback:request error:[NSError errorWithDomain:@"MLRouter" code:403 userInfo:@{NSLocalizedDescriptionKey: @"route blocked by whitelist/validator"}]];
    }
    
    NSMutableDictionary *extractedWildcardParams = [NSMutableDictionary dictionary];
    NSMutableDictionary *finalParams = [NSMutableDictionary dictionary];
    
    NSURLComponents *urlComps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in urlComps.queryItems) {
        if (item.name && item.value) finalParams[item.name] = item.value;
    }
    
    Class clsV = nil;
    pthread_rwlock_rdlock(&g_mlRwLock);
    NSString *nV = g_mlViewMap[basePath];
    pthread_rwlock_unlock(&g_mlRwLock);
    
    if (nV.length > 0) {
        clsV = NSClassFromString(nV);
    } else {
        pthread_rwlock_rdlock(&g_mlRwLock);
        for (MLWildcardRouteModel *m in g_mlViewWildcards) {
            NSTextCheckingResult *res = [m.regex firstMatchInString:basePath options:0 range:NSMakeRange(0, basePath.length)];
            if (res) {
                clsV = NSClassFromString(m.routeInfo);
                for (int k = 0; k < m.paramKeys.count; k++) {
                    if (k + 1 < res.numberOfRanges) {
                        extractedWildcardParams[m.paramKeys[k]] = [basePath substringWithRange:[res rangeAtIndex:k+1]];
                    }
                }
                break;
            }
        }
        pthread_rwlock_unlock(&g_mlRwLock);
    }
    if (clsV && [clsV isSubclassOfClass:[UIView class]]) {
        if (request.params) [finalParams addEntriesFromDictionary:request.params];
        [finalParams addEntriesFromDictionary:extractedWildcardParams];
        
        UIView *v = [[clsV alloc] initWithFrame:CGRectZero];
        [self _safelyMapParameters:[finalParams copy] toInstance:v];
        if (request.completionBlock) request.completionBlock(v);
        return v;
    }
    
    Class clsP = nil;
    pthread_rwlock_rdlock(&g_mlRwLock);
    NSString *nP = g_mlPageMap[basePath];
    pthread_rwlock_unlock(&g_mlRwLock);
    
    if (nP.length > 0) {
        clsP = NSClassFromString(nP);
    } else {
        pthread_rwlock_rdlock(&g_mlRwLock);
        for (MLWildcardRouteModel *m in g_mlPageWildcards) {
            NSTextCheckingResult *res = [m.regex firstMatchInString:basePath options:0 range:NSMakeRange(0, basePath.length)];
            if (res) {
                clsP = NSClassFromString(m.routeInfo);
                for (int k = 0; k < m.paramKeys.count; k++) {
                    if (k + 1 < res.numberOfRanges) {
                        extractedWildcardParams[m.paramKeys[k]] = [basePath substringWithRange:[res rangeAtIndex:k+1]];
                    }
                }
                break;
            }
        }
        pthread_rwlock_unlock(&g_mlRwLock);
    }
    if (clsP && [clsP isSubclassOfClass:[UIViewController class]]) {
        if (request.params) [finalParams addEntriesFromDictionary:request.params];
        [finalParams addEntriesFromDictionary:extractedWildcardParams];
        // 🔒【P0 修复 · 主线程契约】页面路由的 VC 构造 / 参数映射 / present 必须**整体**在主线程完成。
        // 旧实现只在 present 那一步 dispatch 到主线程，`[[clsP alloc] init]` 与
        // `_safelyMapParameters:`（KVC setValue:forKey:）仍跑在调用方线程。
        // 只要调用方在子线程调 open()（后台推送跳转、网络回调、并发测试都很常见），
        // 就构成「UI API called on a background thread」——Main Thread Checker 会直接掐死进程，
        // 线上则是 UIKit 未定义行为（偶发 UI 错乱/崩溃）。open() 仍同步返回 @(YES)，
        // completion 依旧在主线程异步回调，语义不变。
        [self _presentPageClass:clsP params:[finalParams copy] request:request];
        return @(YES);
    }
    
    NSDictionary *mInfo = nil;
    pthread_rwlock_rdlock(&g_mlRwLock);
    mInfo = g_mlMethodMap[basePath];
    pthread_rwlock_unlock(&g_mlRwLock);
    
    if (!mInfo) {
        pthread_rwlock_rdlock(&g_mlRwLock);
        for (MLWildcardRouteModel *m in g_mlMethodWildcards) {
            NSTextCheckingResult *res = [m.regex firstMatchInString:basePath options:0 range:NSMakeRange(0, basePath.length)];
            if (res) {
                mInfo = m.routeInfo;
                for (int k = 0; k < m.paramKeys.count; k++) {
                    if (k + 1 < res.numberOfRanges) {
                        extractedWildcardParams[m.paramKeys[k]] = [basePath substringWithRange:[res rangeAtIndex:k+1]];
                    }
                }
                break;
            }
        }
        pthread_rwlock_unlock(&g_mlRwLock);
    }
    if (mInfo) {
        Class cls = NSClassFromString(mInfo[@"class"]);
        SEL selector = NSSelectorFromString(mInfo[@"selector"]);
        
        if (cls && selector) {
            // 🌟【动静态方法自适应探针】：优先探测工厂类方法（+ 方法），否则回退实例方法。
            NSMethodSignature *sig = [cls methodSignatureForSelector:selector];
            // ⚠️【P0 修复 · 所有权】这里**不能**用 `__autoreleasing`。
            // `__autoreleasing` 的 ARC 契约是「变量里装的是 +0（已进池）的值」，
            // 而 `[[cls alloc] init]` 是 +1、`(__bridge_transfer id)` 转移来的也是 +1。
            // 把 +1 值塞进 `__autoreleasing` 局部变量，ARC 会按 +0 语义处理：不做额外 retain，
            // 于是这个 +1 被「当作已由池持有」，运行期表现为**多出一次 release**。
            // 症状极其隐蔽：不在路由执行处崩，而是在本次 XCTest/runloop 的 autorelease pool 排空时
            // 对已释放对象再 objc_release 而 SIGSEGV（崩溃栈落在 AutoreleasePoolPage::releaseUntil，
            // 看起来跟路由毫无关系）。用默认的 __strong，ARC 才能正确持有并在返回时做 retain/autorelease 平衡。
            id instanceTarget = nil;
            id targetInstance = nil;

            if (sig) {
                targetInstance = cls; // 类方法：宿主对齐 Class 自身，无需实例化
            } else {
                instanceTarget = [[cls alloc] init];
                sig = [instanceTarget methodSignatureForSelector:selector];
                if (sig) targetInstance = instanceTarget;
            }

            // 🔒 方法签名校验：方法路由约定至少接收 (NSDictionary *)params（index 2）。
            // 找不到方法或签名不符（如漏写 params 参数）直接拒绝并诊断，避免 NSInvocation 调用崩溃。
            if (!targetInstance || !sig) {
                [self _diagnoseRouteErrorWithRequest:request];
                NSLog(@"❌ [MLRouter] 方法路由 %@ 未找到可响应的 selector: %@",
                      [MLRouter redactedURLString:request.urlStr], NSStringFromSelector(selector));
                return nil;
            }
            if (sig.numberOfArguments < 3) {
                NSLog(@"❌ [MLRouter] 方法路由 %@ 的 selector %@ 签名不符：方法路由约定第一个参数必须为 (NSDictionary *)params",
                      [MLRouter redactedURLString:request.urlStr], NSStringFromSelector(selector));
                return nil;
            }

            if (request.params) [finalParams addEntriesFromDictionary:request.params];
            [finalParams addEntriesFromDictionary:extractedWildcardParams];

            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:targetInstance];
            [inv setSelector:selector];

            NSDictionary *argP = [finalParams copy];
            void (^cBlock)(id) = request.completionBlock;

            [inv setArgument:&argP atIndex:2];
            if (sig.numberOfArguments > 3) {
                [inv setArgument:&cBlock atIndex:3]; // 方法内部通过此 block 异步回传结果
            }
            [inv invoke];

            // 🔒 返回值所有权（P0）：必须按 ARC 方法家族区分 +1 / +0，不能一律 __bridge_transfer。
            //   - `alloc/new/copy/mutableCopy/init` 家族 ⇒ 返回值就是 +1，直接接管；
            //   - 其余（绝大多数方法路由）⇒ 返回值是 +0（被调方已 objc_autorelease 过），
            //     必须用 objc_retainAutoreleasedReturnValue 认领，否则池排空时会二次释放而崩溃。
            // 承载它的局部变量必须是 __strong（默认），绝不能是 __autoreleasing。
            id finalRetVal = nil;
            const char *retType = sig.methodReturnType;
            if (sig.methodReturnLength > 0 && retType && (retType[0] == _C_ID || retType[0] == _C_CLASS)) {
                void *tempReturnValue = NULL;
                [inv getReturnValue:&tempReturnValue];
                if (tempReturnValue != NULL) {
                    if (MLRouterSelectorReturnsRetained(selector)) {
                        finalRetVal = (__bridge_transfer id)tempReturnValue;              // +1：所有权转移
                    } else {
                        finalRetVal = objc_retainAutoreleasedReturnValue((__bridge id)tempReturnValue); // +0：按 ARC 规则认领
                    }
                }
            }
            // 同步方法（无 block 参数）通过 completion 回传返回值；带 block 参数的方法自行调用 block。
            if (sig.numberOfArguments <= 3 && request.completionBlock) {
                request.completionBlock(finalRetVal);
            }
            return finalRetVal;
        }
        return nil;
    }
    // 🔒 动态路由（运行时/远程下发）：静态段未命中时尝试动态 handler。
    // 用 matched 出参而非「返回值非 nil」判定命中 —— handler 合法返回 nil（业务上表示无数据）
    // 时不应被误判为「路由未命中」去走 404 兜底并打假警报。
    BOOL dynamicMatched = NO;
    id dynamicResult = [self _executeDynamicRouteWithBasePath:basePath
                                               wildcardParams:extractedWildcardParams
                                                     request:request
                                                  finalParams:finalParams
                                                      matched:&dynamicMatched];
    if (dynamicMatched) return dynamicResult;

    [self _diagnoseRouteErrorWithRequest:request];
    return [self _handleFallback:request
                           error:[NSError errorWithDomain:@"MLRouter"
                                                     code:404
                                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"no route matched: %@", request.urlStr]}]];
}

- (void)_diagnoseRouteErrorWithRequest:(MLRouterRequest *)request {
    NSURL *url = [NSURL URLWithString:request.urlStr];
    NSString *basePath = [NSString stringWithFormat:@"%@://%@", url.scheme, url.host];
    if (url.path.length > 0) basePath = [basePath stringByAppendingString:url.path];
    // 🔒 PII：日志里绝不能出现原始敏感参数值（token / 手机号等），统一走脱敏入口
    NSLog(@"\n❌❌❌ [MLRouter 404 灾难级诊断警报启动] ❌❌❌\n🚨 无法匹配的非法 URL 请求为: %@",
          [MLRouter redactedURLString:request.urlStr]);
}

- (void)_safelyMapParameters:(NSDictionary *)params toInstance:(id)instance {
    Class cls = [instance class];
    [params enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        objc_property_t prop = class_getProperty(cls, key.UTF8String);
        if (!prop) return; // 🔒 严格属性 KVC 崩溃防线

        const char *attr = property_getAttributes(prop);
        NSString *atStr = [NSString stringWithUTF8String:attr];

        // 🔒【防类型混淆】block 属性（编码 `T@?`）必须在 `T@` 之前拦下。
        // `T@?` 同样以 `T@` 开头，旧实现会把它当成普通对象属性走 setValue:，
        // URL 里的字符串就被直接写进了 block 的存储位 —— 不报错、不崩溃，
        // 但之后任何一次调用该 block 都是拿字符串当函数指针，必崩（且栈完全看不出是路由干的）。
        // 参数只可能来自 URL，不可能是 block，直接不参与映射。
        if ([atStr hasPrefix:@"T@?"]) return;

        if ([atStr hasPrefix:@"T@"]) {                 // 对象属性（含 id / 具体类 / 协议约束）
            [instance setValue:obj forKey:key];
            return;
        }

        // 非对象类型只接受「能当数字用」的值（NSNumber / NSString 等实现了 doubleValue 的）。
        // NSValue（结构体 / 指针 / SEL）、NSNull、NSDate 等一律静默跳过 —— 宁可不赋值，不可崩。
        if (![obj respondsToSelector:@selector(doubleValue)]) return;

        // ⚠️【精度】取值链要按「哪些选择器真的存在」来设计：
        //   · NSNumber 实现了完整的 longLongValue / unsignedLongLongValue 家族；
        //   · NSString 只实现了 intValue / integerValue / longLongValue / floatValue /
        //     doubleValue / boolValue —— **没有** unsignedXxxValue / shortValue 家族。
        // 对 NSString 调 unsignedLongLongValue / shortValue 就是 unrecognized selector 崩溃。
        // 因此：能取 longLongValue 就取（NSNumber 与 NSString 都有，比 double 中转精确得多，
        // 不会把 19 位订单号 / 纳秒时间戳压成 2^53 的近似值）；unsigned 家族仅在确认 NSNumber 时取。
        NSNumber *num = [obj isKindOfClass:[NSNumber class]] ? (NSNumber *)obj : nil;
        double v = [obj doubleValue];
        long long ll = [obj respondsToSelector:@selector(longLongValue)] ? [obj longLongValue]
                                                                        : (long long)v;
        unsigned long long ull = num ? num.unsignedLongLongValue : (unsigned long long)ll;

        // 类型码必须逐个精确匹配（大小写敏感）：Tq/TQ、Ti/TI、Ts/TS、Tc/TC 都是不同类型。
        // ⚠️ 旧实现只覆盖了 Ti/Tq/TI/TQ + TB/Tc + Tf/Td，
        // **漏了 short(Ts) / unsigned short(TS) / unsigned char(TC)** ——
        // 这三种属性的表现是「路由能命中、页面能打开、参数就是不生效」，
        // 又一处静默失效，且查起来毫无线索。
        if ([atStr hasPrefix:@"Tq"]) {
            [instance setValue:@(ll) forKey:key];                  // long long
        } else if ([atStr hasPrefix:@"TQ"]) {
            [instance setValue:@(ull) forKey:key];                 // unsigned long long
        } else if ([atStr hasPrefix:@"Ti"]) {
            [instance setValue:@((int)ll) forKey:key];             // int
        } else if ([atStr hasPrefix:@"TI"]) {
            [instance setValue:@((unsigned int)ull) forKey:key];   // unsigned int
        } else if ([atStr hasPrefix:@"Ts"]) {
            [instance setValue:@((short)ll) forKey:key];           // short
        } else if ([atStr hasPrefix:@"TS"]) {
            [instance setValue:@((unsigned short)ull) forKey:key]; // unsigned short
        } else if ([atStr hasPrefix:@"TB"]) {
            [instance setValue:@([obj boolValue]) forKey:key];     // BOOL
        } else if ([atStr hasPrefix:@"Tc"]) {
            [instance setValue:@((char)ll) forKey:key];            // char
        } else if ([atStr hasPrefix:@"TC"]) {
            [instance setValue:@((unsigned char)ull) forKey:key];  // unsigned char
        } else if ([atStr hasPrefix:@"Tf"]) {
            [instance setValue:@((float)v) forKey:key];            // float
        } else if ([atStr hasPrefix:@"Td"]) {
            [instance setValue:@(v) forKey:key];                   // double
        }
    }];
}

- (UIViewController *)_findTopViewController:(UIViewController *)vc {
    if ([vc isKindOfClass:[UINavigationController class]]) return [self _findTopViewController:[(UINavigationController *)vc topViewController]];
    if ([vc isKindOfClass:[UITabBarController class]]) return [self _findTopViewController:[(UITabBarController *)vc selectedViewController]];
    if (vc.presentedViewController) return [self _findTopViewController:vc.presentedViewController];
    return vc;
}

#pragma mark - 治理层辅助方法

- (BOOL)_isRouteAllowed:(NSURL *)url basePath:(NSString *)basePath {
    if (g_mlRouteValidator) return g_mlRouteValidator(url);
    if (g_mlAllowedSchemes && ![g_mlAllowedSchemes containsObject:url.scheme]) return NO;
    if (g_mlAllowedPaths) {
        BOOL matched = NO;
        for (NSString *p in g_mlAllowedPaths) {
            if ([basePath isEqualToString:p] || [basePath hasPrefix:p]) { matched = YES; break; }
        }
        if (!matched) return NO;
    }
    return YES;
}

- (id)_handleFallback:(MLRouterRequest *)request error:(NSError *)error {
    id result = nil;
    if (g_mlFallbackHandler) {
        result = g_mlFallbackHandler(request, error);
        // 🔒 兑现 MLRouter.h 的文档契约：「降级兜底：路由未命中或被拦截时回调，
        // 返回的 UIViewController 会被自动 present」。
        // 修复前此处只把 VC 当返回值丢出去、从不 present，导致两条实际后果：
        //   ① 未命中路由时页面毫无反馈（用户以为按钮坏了）；
        //   ② .open() 返回一个 UIViewController，与「页面路由返回 @(YES)」的语义冲突，
        //      让人误以为「open 返回控制器」是设定行为。
        if ([result isKindOfClass:[UIViewController class]]) {
            UIViewController *fbVC = (UIViewController *)result;
            [self _attachFallbackContextTo:fbVC request:request error:error];
            [self _presentViewController:fbVC request:request];
            return @(YES);
        }
    } else if (g_mlFallbackVCClass && [g_mlFallbackVCClass isSubclassOfClass:[UIViewController class]]) {
        // 同上：兜底 VC 的实例化同样必须在主线程（UIViewController 的 init 是 UI API）。
        Class fbClass = g_mlFallbackVCClass;
        void (^work)(void) = ^{
            UIViewController *fbVC = [[fbClass alloc] init];
            [self _attachFallbackContextTo:fbVC request:request error:error];
            [self _presentViewController:fbVC request:request];
        };
        if ([NSThread isMainThread]) work();
        else dispatch_async(dispatch_get_main_queue(), work);
        result = @(YES);
    } else {
        NSLog(@"❌ [MLRouter] 路由 %@ 无匹配且无兜底 handler/VC，返回 nil",
              [MLRouter redactedURLString:request.urlStr]);
    }
    // 非 VC 结果（业务数据）仍按原契约通过 completion 回传；VC 已在上面 present 并返回 @(YES)。
    if (request.completionBlock && result && ![result isKindOfClass:[UIViewController class]]) {
        request.completionBlock(result);
    }
    return result;
}

// 兜底页最需要的上下文就是「是哪条 URL 挂的、为什么挂」。
// handler 自己已经填了 ml_routerParams 就不覆盖（尊重业务自定义）。
- (void)_attachFallbackContextTo:(UIViewController *)vc request:(MLRouterRequest *)request error:(NSError *)error {
    if (!vc || vc.ml_routerParams) return;
    NSMutableDictionary *ctx = [NSMutableDictionary dictionary];
    if (request.urlStr) ctx[@"ml_fallbackURL"] = request.urlStr;
    if (error) {
        ctx[@"ml_fallbackErrorCode"] = @(error.code);
        if (error.localizedDescription) ctx[@"ml_fallbackErrorMessage"] = error.localizedDescription;
    }
    if (request.params.count > 0) ctx[@"ml_fallbackParams"] = [request.params copy];
    vc.ml_routerParams = [ctx copy];
}

// 页面路由统一入口：把「实例化 + 参数映射 + ml_routerParams 注入 + present」封装成一个
// 不可分割的主线程工作单元。**整段**必须在主线程执行，不能只把 present 挪过去 ——
// UIViewController 的 init 与 setValue:forKey: 都是 UI API，在后台线程调用属未定义行为。
- (void)_presentPageClass:(Class)clsP params:(NSDictionary *)params request:(MLRouterRequest *)request {
    if (!clsP) return;
    void (^work)(void) = ^{
        UIViewController *vc = [[clsP alloc] init];
        [self _safelyMapParameters:params toInstance:vc];
        vc.ml_routerParams = params;
        [self _presentViewController:vc request:request];
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

// 统一 present：保证主线程执行，并回调 completion（主线程）
- (void)_presentViewController:(UIViewController *)vc request:(MLRouterRequest *)request {
    if (!vc) return;
    void (^present)(void) = ^{
        UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
        if (!top) {
            // 🔒【扩展进程 / 无宿主 UI 环境】App Extension 里 sharedApplication 无 keyWindow。
            // 旧实现把 present 消息发给 nil 静默 no-op，却仍把**从未上屏的 VC** 通过
            // completion 当「结果对象」发出去 —— 双通道契约的静默失效。
            // 现在显式诊断（走 PII 脱敏入口）+ completion(nil)：拿不到 VC 即知道没上屏。
            NSLog(@"\n❌ [MLRouter] 页面路由无法呈现：无 keyWindow（扩展进程 / 无宿主 UI 环境）。URL: %@",
                  [MLRouter redactedURLString:request.urlStr]);
            if (request.completionBlock) request.completionBlock(nil);
            return;
        }
        while (top.presentedViewController) top = top.presentedViewController;
        if ([top isKindOfClass:[UINavigationController class]] && request.transitionStyle == MLRouteTransitionStylePush) {
            [(UINavigationController *)top pushViewController:vc animated:request.animated];
        } else {
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            [top presentViewController:nav animated:request.animated completion:nil];
        }
        // 🔒【双通道契约 · 务必别改】页面路由的两条结果通道承载不同语义：
        //   · open() 的**同步返回值** = 「受理信号」，页面路由恒为 @(YES)（仅表示已 present）。
        //     它绝不能是 VC —— 因为页面是异步在主线程 present 的，同步返回时 VC 可能都还没构造出来；
        //     而历史上把兜底 handler 的 VC 从 open() 漏出去，直接导致了
        //     「mluser://user/total 调 open 拿到一个控制器」这种误判（其实是那条 URL 没命中、走了兜底）。
        //   · withCompletion 的**回调值** = 「结果对象」，页面路由传**被 present 的 VC 实例**。
        //     这是调用方唯一能在页面 present 后拿到 VC 本体做后续配置 / 断言的通道
        //     （真实 UI 测试场景全靠它断言参数映射与 ml_routerParams）。
        // 一句话：open() 回答「成不成」，completion 回答「成了之后拿到什么」。
        if (request.completionBlock) request.completionBlock(vc);
    };
    if ([NSThread isMainThread]) present();
    else dispatch_async(dispatch_get_main_queue(), present);
}

- (id)_executeDynamicRouteWithBasePath:(NSString *)basePath
                        wildcardParams:(NSMutableDictionary *)wildcardParams
                              request:(MLRouterRequest *)request
                           finalParams:(NSMutableDictionary *)finalParams
                               matched:(BOOL *)outMatched {
    if (outMatched) *outMatched = NO;
    id (^handler)(NSDictionary *, MLRouterRequest *) = nil;
    NSMutableDictionary *wp = [wildcardParams mutableCopy];
    pthread_rwlock_rdlock(&g_mlRwLock);
    handler = g_mlDynamicExactMap[basePath];
    pthread_rwlock_unlock(&g_mlRwLock);
    if (!handler) {
        pthread_rwlock_rdlock(&g_mlRwLock);
        for (MLWildcardRouteModel *m in g_mlDynamicWildcards) {
            NSTextCheckingResult *res = [m.regex firstMatchInString:basePath options:0 range:NSMakeRange(0, basePath.length)];
            if (res) {
                handler = m.routeInfo;
                for (int k = 0; k < m.paramKeys.count; k++) {
                    if (k + 1 < res.numberOfRanges) wp[m.paramKeys[k]] = [basePath substringWithRange:[res rangeAtIndex:k+1]];
                }
                break;
            }
        }
        pthread_rwlock_unlock(&g_mlRwLock);
    }
    if (!handler) return nil;
    if (outMatched) *outMatched = YES;   // 命中已注册 handler：后续即便返回 nil 也不再走 404
    if (request.params) [finalParams addEntriesFromDictionary:request.params];
    [finalParams addEntriesFromDictionary:wp];
    id result = handler([finalParams copy], request);
    if ([result isKindOfClass:[UIViewController class]]) {
        [self _presentViewController:result request:request];
        return @(YES);
    }
    if (request.completionBlock) request.completionBlock(result);
    return result;
}

#pragma mark - 治理层公开 API

+ (void)registerRoute:(NSString * _Nonnull)urlPattern
              handler:(id _Nullable (^_Nonnull)(NSDictionary * _Nonnull params, MLRouterRequest * _Nonnull request))handler {
    if (urlPattern.length == 0 || !handler) return;
    if ([urlPattern containsString:@"*"]) {
        pthread_rwlock_wrlock(&g_mlRwLock);
        [MLRouter _parseWildcardPath:urlPattern intoArray:g_mlDynamicWildcards info:[handler copy]];
        pthread_rwlock_unlock(&g_mlRwLock);
    } else {
        pthread_rwlock_wrlock(&g_mlRwLock);
        g_mlDynamicExactMap[urlPattern] = [handler copy];
        pthread_rwlock_unlock(&g_mlRwLock);
    }
}

+ (void)unregisterRoute:(NSString * _Nonnull)urlPattern {
    if (urlPattern.length == 0) return;
    pthread_rwlock_wrlock(&g_mlRwLock);
    [g_mlDynamicExactMap removeObjectForKey:urlPattern];
    NSMutableArray *kept = [NSMutableArray array];
    for (MLWildcardRouteModel *m in g_mlDynamicWildcards) {
        if (![m.regex.pattern isEqualToString:urlPattern]) [kept addObject:m];
    }
    g_mlDynamicWildcards = [kept mutableCopy];
    pthread_rwlock_unlock(&g_mlRwLock);
}

+ (void)setAllowedSchemes:(NSSet<NSString *> *)schemes { g_mlAllowedSchemes = [schemes copy]; }
+ (void)setAllowedURLPaths:(NSSet<NSString *> *)paths { g_mlAllowedPaths = [paths copy]; }
+ (void)setRouteValidator:(BOOL (^)(NSURL *))validator { g_mlRouteValidator = [validator copy]; }
+ (void)setFallbackHandler:(id (^)(MLRouterRequest *, NSError *))handler { g_mlFallbackHandler = [handler copy]; }
+ (void)setFallbackViewControllerClass:(Class)cls { g_mlFallbackVCClass = cls; }
+ (void)setRedactedQueryKeys:(NSSet<NSString *> *)keys { g_mlRedactedQueryKeys = [keys copy]; }

+ (NSString *)redactedURLString:(NSString *)urlStr {
    if (urlStr.length == 0) return urlStr;
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url || url.query.length == 0) return urlStr;   // 无 query：没有可泄露的参数值
    // 默认键集（安全默认）；显式传入自定义集整体替换；空集 = 关闭
    static NSSet<NSString *> *defaultKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaultKeys = [NSSet setWithArray:@[@"token", @"access_token", @"password", @"pwd",
                                            @"passwd", @"phone", @"mobile", @"idcard", @"secret"]];
    });
    NSSet<NSString *> *keys = g_mlRedactedQueryKeys ?: defaultKeys;
    if (keys.count == 0) return urlStr;
    NSMutableSet<NSString *> *lowerKeys = [NSMutableSet set];
    for (NSString *k in keys) [lowerKeys addObject:k.lowercaseString];

    NSURLComponents *comps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    BOOL changed = NO;
    for (NSURLQueryItem *item in comps.queryItems) {
        if (item.name && [lowerKeys containsObject:item.name.lowercaseString]) {
            // 占位符必须是「百分号编码后不变」的纯字母串 —— <redacted> 会被 NSURLComponents
            // 编码成 %3Credacted%3E，断言与人工核对都会踩坑（实测踩过）
            [items addObject:[NSURLQueryItem queryItemWithName:item.name value:@"REDACTED"]];
            changed = YES;
        } else {
            [items addObject:item];
        }
    }
    if (!changed) return urlStr;
    comps.queryItems = items;
    return comps.URL.absoluteString ?: urlStr;
}

+ (void)resetRouter {
    pthread_rwlock_wrlock(&g_mlRwLock);
    [g_mlDynamicExactMap removeAllObjects];
    [g_mlDynamicWildcards removeAllObjects];
    g_mlAllowedSchemes = nil;
    g_mlAllowedPaths = nil;
    g_mlRouteValidator = nil;
    g_mlFallbackHandler = nil;
    g_mlFallbackVCClass = nil;
    g_mlRedactedQueryKeys = nil;
    pthread_rwlock_unlock(&g_mlRwLock);
}

+ (void)resetGovernance {
    // 刻意不碰 g_mlDynamicExactMap / g_mlDynamicWildcards：
    // 模块自举（moduleSetup）注册的动态路由与手动注册的动态路由共用同一张表，
    // 整体清空会让场景测试把组件能力一起干掉且无法恢复（段扫描幂等，模块不会再 loadModules）。
    pthread_rwlock_wrlock(&g_mlRwLock);
    g_mlAllowedSchemes = nil;
    g_mlAllowedPaths = nil;
    g_mlRouteValidator = nil;
    g_mlFallbackHandler = nil;
    g_mlFallbackVCClass = nil;
    g_mlRedactedQueryKeys = nil;
    pthread_rwlock_unlock(&g_mlRwLock);
}

+ (NSDictionary *)exportRouteTable {
    pthread_rwlock_rdlock(&g_mlRwLock);
    NSArray *pages = g_mlPageMap.allKeys;
    NSArray *methods = g_mlMethodMap.allKeys;
    NSArray *views = g_mlViewMap.allKeys;
    NSArray *dynamic = g_mlDynamicExactMap.allKeys;
    NSMutableArray *wildcards = [NSMutableArray array];
    for (MLWildcardRouteModel *m in g_mlPageWildcards) [wildcards addObject:m.regex.pattern];
    for (MLWildcardRouteModel *m in g_mlMethodWildcards) [wildcards addObject:m.regex.pattern];
    for (MLWildcardRouteModel *m in g_mlViewWildcards) [wildcards addObject:m.regex.pattern];
    for (MLWildcardRouteModel *m in g_mlDynamicWildcards) [wildcards addObject:m.regex.pattern];
    NSDictionary *redirects = [g_mlRedirectMap copy];
    pthread_rwlock_unlock(&g_mlRwLock);
    return @{
        @"pages": pages,
        @"methods": methods,
        @"views": views,
        @"dynamic": dynamic,
        @"wildcards": wildcards,
        @"redirects": redirects,
        @"services": [MLRouterService exportedServiceProtocols],
        @"modules": [MLRouterModuleManager exportedModuleNames],
    };
}

@end
