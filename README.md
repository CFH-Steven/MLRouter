# MLRouter

**企业级 iOS 组件化路由框架** —— 编译期 Mach-O 段注册 + dyld 扫描，零硬编码类名清单、跨 Pod 零手动接线、Release strip 环境实测可用。

**核心特性：**

- **去单例设计** - 每次调用创建轻量实例，用完即销毁，零内存占用
- **全链式点语法** - DSL 风格的 API 设计，流畅易用
- **三大路由类型** - 页面跳转、方法调用、视图组件获取
- **通配符路由** - 支持单 `*` 和多级 `**` 模糊匹配，参数确定性捕获
- **AOP 拦截器** - 职责链模式，支持优先级排序
- **组件化三层** - Service 协议服务发现 / Module 模块自举与生命周期 / 治理层（白名单·兜底·动态路由）
- **多仓支持** - 跨 Pod 自动扫描注册，组件化开发友好
- **线程安全** - 读写锁保护，页面路由任意线程可调（自动切主线程）
- **KVC 参数映射** - 自动将 URL 参数映射到对象属性（13 个类型码逐一处理）
- **404 自愈诊断** - 路由未找到时提供可归因排查信息，日志自带 PII 脱敏

---

## 目录

1. [技术原理](#一技术原理30-秒看懂)
2. [架构设计](#二架构设计)
3. [段注册宏完整参考（注解宏速查）](#三段注册宏完整参考注解宏速查)
4. [快速接入（5 分钟）](#四快速接入5-分钟)
5. [使用指南](#五使用指南)
6. [注意事项与关键契约](#六注意事项与关键契约)
7. [测试与质量保障](#七测试与质量保障)
8. [示例项目](#八示例项目)

---

## 一、技术原理（30 秒看懂）

MLRouter 的核心是**编译期注册、运行时扫描**，全程不依赖反射遍历类、不维护硬编码类名清单：

```
编译期                          链接期                    运行时
────────                       ────────                 ────────
段宏把注册信息                  链接器把各镜像的           dyld 扫描全部已加载镜像
以二进制结构写入                 自定义 section 汇总        的自定义 section，
Mach-O __DATA 自定义 section    进最终可执行文件           一次性回填路由表
```

**关键设计决策：**

| 决策 | 收益 |
|------|------|
| 注册信息写入 `__DATA` 自定义 section，而非运行时 `+load` 遍历 | 零冷启动遍历成本；`NSClassFromString` 精确取类，**Release strip 下实测可用** |
| 运行时用 dyld 扫描全部已链接镜像（App / 静态库 / 动态框架 / 远端二进制） | 组件只写段宏即自动生效，**跨 Pod 零手动接线** |
| 精确路由用字典 O(1) 查找，通配符编译成正则 + 捕获段数降序排序 | 查找性能确定性（有复杂度测试钉住，表 ×100 耗时不线性增长） |
| 扫描幂等（`ensureRoutesLoaded` 只成功执行一次） | 可安全多次调用，测试隔离不毁真实功能 |

**七个自定义 section（路由类型 → section 名）：**

| 注册内容 | section | 宏 |
|---|---|---|
| 页面路由 | `__DATA,MLPageSect` | `MLRouterPage` / `MLRouterPageClass` |
| 方法路由 | `__DATA,MLMethodSect` | `MLRouterMethod` / `MLRouterMethodClass` |
| 视图路由 | `__DATA,MLViewSect` | `MLRouterView` / `MLRouterViewClass` |
| 重定向映射 | `__DATA,MLRedirectSect` | `MLRouterRedirect` |
| 拦截器 | `__DATA,MLInterceptSect` | `MLRouterInterceptor` / `MLRouterInterceptorClass` |
| 服务发现 | `__DATA,MLServiceSect` | `MLRouterService` |
| 模块自举 | `__DATA,MLModuleSect` | `MLRouterModule` |

**扩展进程（App Extension）支持**：非 UI 路由（方法路由 / 导出表 / 服务发现）**零 `UIApplication` 依赖**，extension 里可放心使用；页面路由在无 keyWindow 环境下不会静默失败——`completion(nil)` + 可归因诊断日志（有测试钉住该契约）。

---

## 二、架构设计

```
┌─────────────────────────────────────────────────────────┐
│                      MLRouterInstance()                  │
│                    (每次调用创建轻量实例)                  │
└─────────────────────────┬───────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────┐
│                    MLRouterRequest                       │
│  ┌──────────────────────────────────────────────────┐   │
│  │  .build(url) → .withParam() → .withParams()     │   │
│  │  → .withCompletion() → .withTransitionStyle()   │   │
│  │  → .withAnimation() → .open()                   │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────┬───────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
    ┌──────────┐   ┌──────────┐   ┌──────────┐
    │页面路由   │   │方法路由   │   │视图路由   │
    │(Page)    │   │(Method)  │   │(View)    │
    └──────────┘   └──────────┘   └──────────┘
          │               │               │
          └───────────────┼───────────────┘
                          │
┌─────────────────────────▼───────────────────────────────┐
│               InterceptorChain (职责链)                  │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐              │
│  │Intercept│───▶│Intercept│───▶│Intercept│───▶内核执行  │
│  │  (10)   │    │  (20)   │    │  (30)   │              │
│  └─────────┘    └─────────┘    └─────────┘              │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────┐
│               dyld 镜像扫描 (mach-o)                     │
│  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐        │
│  │App     │  │Pod A   │  │Pod B   │  │私有仓   │        │
│  │Target  │  │Static  │  │Dynamic │  │Binary  │        │
│  └────────┘  └────────┘  └────────┘  └────────┘        │
│  （七个自定义 section，见「技术原理」表格）                 │
└─────────────────────────────────────────────────────────┘
```

**请求执行管线（一次 `open()` 内部发生的事）：**

```
校验（validator > scheme 白名单 > path 白名单，均在重定向解析之后校验最终 URL）
  → 重定向解析（支持 A→B→C 多级链，防环上限 16 跳，query 原样保留）
  → 拦截器职责链（priority 升序；reject 熔断 → 走兜底）
  → 路由查找（静态段精确 O(1) → 静态通配符 → 动态路由）
  → 执行（页面：主线程工作单元「实例化+参数映射+present」；方法：NSInvocation 调用；
     视图：实例化+参数映射后返回）
  → 未命中/被拦截 → 兜底（handler 优先于 VC class）
```

**源码结构（MLRouter/Classes/）：**

| 文件 | 职责 |
|---|---|
| `MLRouter.{h,m}` | 路由内核：段扫描、查找、执行管线、治理 API、PII 脱敏 |
| `MLRouterRequest.{h,m}` | 链式 DSL 请求对象 |
| `MLRouterModule.{h,m}` | 模块协议 + `MLRouterModuleManager`（拓扑排序、生命周期转发） |
| `MLRouterService.{h,m}` | 协议驱动服务发现（静态段表 + 运行时表双表模型） |
| `MLRouterInterceptor.h` | 拦截器协议契约 |
| `MLRouterMacros.h` | 全部段注册宏（含显式类名宏） |

---

## 三、段注册宏完整参考（注解宏速查）

MLRouter 的全部注册能力（页面 / 方法 / 视图 / 重定向 / 拦截器 / Service / Module）都通过**编译期段注解宏**完成。宏在编译期把一条 `{urlPath, className, selector/priority}` 结构体写入 Mach-O 的专属 `__DATA` section；运行时 `MLRouter.loadAllIsolatedRoutes` 借助 dyld 扫描主二进制与所有非系统动态库，自动回填路由表。**你不需要任何集中式注册清单，也不需要手动接线**——组件只要 `#import <MLRouter/MLRouterHeader.h>` 并写上宏即可被自动发现。

> 宏自带分号（`MLRouterPage(x);` 已内含 `;`），调用处写不写分号都合法（多一个空语句无副作用）。

### 3.1 宏总览（12 个）

| 宏 | 写入段 | 用途 | 放置位置 | 类名来源 |
|---|---|---|---|---|
| `MLRouterPage(url)` | `MLPageSect` | 页面路由 | 目标类 `.m`（文件级） | `__FILE__` 推导 |
| `MLRouterMethod(url, sel)` | `MLMethodSect` | 方法路由 | 目标类 `.m`（文件级） | `__FILE__` 推导 |
| `MLRouterView(url)` | `MLViewSect` | 视图组件路由 | 目标类 `.m`（文件级） | `__FILE__` 推导 |
| `MLRouterRedirect(from, to)` | `MLRedirectSect` | 重定向 | 任意 `.m`（文件级） | — |
| `MLRouterInterceptor(priority)` | `MLInterceptSect` | 拦截器 | **必须写在 `@implementation` 内** | `__FILE__` 推导 |
| `MLRouterPageClass(cls, url)` | `MLPageSect` | 页面路由（显式类名） | 任意 `.m`（推荐 `@implementation` 内） | 显式字符串 |
| `MLRouterMethodClass(cls, url, sel)` | `MLMethodSect` | 方法路由（显式类名） | 任意 `.m`（推荐 `@implementation` 内） | 显式字符串 |
| `MLRouterViewClass(cls, url)` | `MLViewSect` | 视图路由（显式类名） | 任意 `.m`（推荐 `@implementation` 内） | 显式字符串 |
| `MLRouterInterceptorClass(cls, priority)` | `MLInterceptSect` | 拦截器（显式类名） | **必须写在 `@implementation` 内** | 显式字符串 |
| `MLRouterService(proto, impl)` | `MLServiceSect` | 协议驱动服务发现 | 写在 `@implementation impl` 内 | — |
| `MLRouterModule(cls)` | `MLModuleSect` | 模块自举 + 生命周期 | 写在 `@implementation cls` 内 | — |

> 段名与「架构设计」一节里的 7 个物理段一一对应：`MLPageSect / MLMethodSect / MLViewSect / MLRedirectSect / MLInterceptSect / MLServiceSect / MLModuleSect`。

### 3.2 两种类名形态：隐式（文件名推导）vs 显式（推荐）

- **隐式宏**（`MLRouterPage` / `MLRouterMethod` / `MLRouterView` / `MLRouterInterceptor`）：className 字段存的是 `__FILE__` 路径，运行时剥离路径与 `.m/.h/.mm` 后缀反推类名。隐含约定 **「文件名 == 类名」**。一旦 `.m` 文件名与 `@interface` 类名不一致，`NSClassFromString` 返回 nil，路由**静默失效**（不崩、不打日志、URL 直接走 404 兜底）。
- **显式宏**（带 `Class` 后缀）：className 字段直接存真实类名字符串（如 `"TestViewController"`，不含 `/`），运行时识别为类名直接使用，**彻底消除文件名依赖**。

**结论：新代码一律用显式宏**（`MLRouterPageClass` 等）。隐式宏仅适合 demo 或文件名严格等于类名的存量代码。

### 3.3 各宏用法与示例

**① 页面路由** —— 注册一个可被打开的 `UIViewController`：

```objc
// TestViewController.m（显式宏，推荐）
@implementation TestViewController
MLRouterPageClass("TestViewController", "app://Test/index")
@end

// 隐式写法（要求文件名 == 类名，即 TestViewController.m 里 @interface TestViewController）
MLRouterPage("app://User/index")
```

**② 方法路由** —— 注册一个可被调用的方法（类方法或实例方法均可），`sel` 为目标类上要执行的选择器：

```objc
@implementation TestViewController
MLRouterMethodClass("TestViewController", "app://Test/service", "textService:block:")
+ (NSString *)textService:(NSDictionary *)params block:(void(^)(id result))block {
    if (block) block(@{@"result":@"异步返回"});
    return @"我的啊";
}
@end
```

**③ 视图路由** —— 注册一个可返回的视图组件（非全屏 VC，常用于组件化嵌入）：

```objc
MLRouterViewClass("BannerView", "app://Widget/banner")
```

**④ 重定向** —— 把一组旧 URL 透明转发到新 URL（文件级，无类依赖）：

```objc
MLRouterRedirect("app://old/profile", "app://User/index")
```

**⑤ 拦截器（AOP 切面）** —— **必须写在拦截器类的 `@implementation` 内**，`priority` 越小越先执行：

```objc
// 隐式（文件名须 == 类名）
@implementation TestAuthInterceptor
MLRouterInterceptor(20)
@end

// 显式（推荐）
@implementation TestAuthInterceptor
MLRouterInterceptorClass("TestAuthInterceptor", 20)
@end
```

拦截器类需遵循 `MLRouterInterceptor` 协议，实现 `intercept:request:completion:`（详见使用指南 §5）。

**⑥ Service 服务发现** —— 协议名映射到实现类，**写在实现类的 `@implementation` 内**：

```objc
// DemoService.m
@implementation DemoCartServiceImpl
MLRouterService(DemoCartService, DemoCartServiceImpl)
@end
// 调用方只依赖协议，不依赖实现类：
id<DemoCartService> cart = [MLRouterService serviceForProtocol:@protocol(DemoCartService)];
```

**⑦ Module 模块自举** —— 模块类自注册，**写在模块类的 `@implementation` 内**；运行时由 `MLRouterModuleManager` 按 `modulePriority` / `moduleDependencies` 拓扑排序后回调 `moduleSetup` 等生命周期：

```objc
// DemoModule.m
@implementation DemoModule
MLRouterModule(DemoModule)
+ (NSInteger)modulePriority { return 100; }
+ (NSArray<NSString *> *)moduleDependencies { return @[]; }
- (void)moduleSetup { /* 注册动态路由 / 服务 */ }
@end
```

### 3.4 ⚠️ 宏相关高频坑

1. **隐式宏 + 文件名 ≠ 类名 → 静默失效**：这是最隐蔽的坑。用显式宏（`MLRouter*Class`）从根上规避。
2. **拦截器宏写在 `@implementation` 外不生效**：`MLRouterInterceptor` / `MLRouterInterceptorClass` 必须置于拦截器类的 `@implementation ... @end` 内部（其类名为注册依据）。
3. **忘记 `-ObjC` 链接标志**：段数据在链接期被整体裁剪，`loadAllIsolatedRoutes` 扫不到任何注册项，表现为「全部路由 404、拦截器/Service/Module 一个都不生效」。宿主 Build Settings → Other Linker Flags 务必加 `-ObjC`（详见注意事项 §接入期）。
4. **跨 Pod 注册不生效**：确认组件 Pod 的 podspec 把 `MLRouterHeader.h` 等公开（public_header_files），且使用方 `#import <MLRouter/MLRouterHeader.h>`；段扫描覆盖所有非系统动态库，无需手动接线。

---

## 四、快速接入（5 分钟）

宿主需要做的全部事情只有 3 步：

### Step 1：Podfile 引入 + 链接标志

```ruby
# Podfile
pod 'MLRouter'            # 或本地私有仓: pod 'MLRouter', :path => 'LocalPods/MLRouter'

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['OTHER_LDFLAGS'] ||= ['$(inherited)']
      config.build_settings['OTHER_LDFLAGS'] << '-ObjC'   # ⚠️ 必须开启，否则段宏注册不生效
    end
  end
end
```

> 业务组件仓同样只写 `pod :path =>` 引用即可，组件内部用段宏自注册，**无需任何手动接线**。

### Step 2：组件内注册路由（写在 `@implementation` 内）

```objc
@implementation HomeViewController
MLRouterPageClass("HomeViewController", "app://home")   // ⭐ 推荐显式类名宏
@end

@implementation DemoService
MLRouterMethodClass("DemoService", "app://service/login", "loginWithParams:completion:")
@end

@implementation DemoInterceptor
MLRouterInterceptorClass("DemoInterceptor", 10)
@end
```

### Step 3：AppDelegate 启动时序

```objc
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [MLRouterModuleManager loadModules];                    // 模块自举（内部先确保段扫描完成，幂等）
    [MLRouterModuleManager applicationDidFinishLaunching:application];
    [MLRouter setFallbackViewControllerClass:ErrorViewController.class];   // 建议配置降级兜底
    return YES;
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
    [MLRouterModuleManager applicationDidEnterBackground:application];
}
// applicationWillEnterForeground: / openURL:options: 同理转发
```

### 调用方（任意组件，只依赖路由 URL）

```objc
MLRouterInstance()
    .build(@"app://home")
    .withParam(@"userId", @"12345")
    .withTransitionStyle(MLRouteTransitionStylePush)
    .open();
```

### ✅ 接入自查清单

- [ ] `-ObjC` 链接标志已开启（**不开 = 全部注册静默失效**）
- [ ] 推荐使用显式类名宏（`...Class` 系列），避免「文件名 ≠ 类名」导致的静默失效
- [ ] Module 类在 `@interface` 上声明了 `<MLRouterModule>`；拦截器声明了 `<MLRouterInterceptor>`（**段宏 ≠ 注册成功，协议遵循才是准入校验**）
- [ ] `modulePriority` / `moduleDependencies` 写成了**类方法**（`+`）
- [ ] `didFinishLaunching` 里调用了 `[MLRouterModuleManager loadModules]`
- [ ] 配置了降级兜底（`setFallbackHandler:` 或 `setFallbackViewControllerClass:`），404 不白屏
- [ ] （可选）接入 CI 路由冲突检测：`./scripts/mlrouter_validate.sh ./YourProject`

---

## 五、使用指南

### 1. 三种路由类型速览

**页面路由** —— 跳转 UIViewController：

```objc
// 注册（App 内多个通配符可并存）
MLRouterPageClass("HomeViewController", "app://home")
MLRouterPageClass("HomeViewController", "app://home/*")     // 单级通配
MLRouterPageClass("HomeViewController", "app://home/**")    // 多级通配

// 跳转
MLRouterInstance().build(@"app://home")
    .withParam(@"userId", @"12345")
    .withTransitionStyle(MLRouteTransitionStylePush)   // Push / Present
    .withAnimation(YES)
    .open();
```

**方法路由** —— 调用服务方法（同步返回 + 异步回调双支持）：

```objc
// 注册：选择器参数类型必须为 (NSDictionary *)params
MLRouterMethodClass("DemoService", "app://service/login", "loginWithParams:completion:")
- (void)loginWithParams:(NSDictionary *)params completion:(void(^)(id result))completion { }

// 调用
id result = MLRouterInstance()
    .build(@"app://service/login?username=test&password=123456")
    .withCompletion(^(id result) { NSLog(@"异步结果: %@", result); })
    .open();
```

**视图路由** —— 获取 UIView 组件实例：

```objc
MLRouterViewClass("PrimaryButton", "app://widget/primary_button")

UIView *button = MLRouterInstance()
    .build(@"app://widget/primary_button")
    .withParam(@"badgeCount", @5)
    .open();
[self.view addSubview:button];
```

**URL 重定向** —— 旧路径平滑迁移：

```objc
MLRouterRedirect("app://old/home", "app://home")
```

### 2. 核心 DSL

```objc
MLRouterInstance()
    .build(url)                      // 构建请求（必调）
    .withParam(key, value)           // 单个参数
    .withParams(dict)                // 批量参数（与 withParam 按「后写覆盖」）
    .withCompletion(block)           // 完成回调（页面路由拿 VC 实例的唯一通道）
    .withTransitionStyle(style)      // 转场方式（默认 Push）
    .withAnimation(animated)         // 是否动画（默认 YES）
    .open();                         // 执行（必调）
```

### 3. 通配符路由

```objc
MLRouterPage("app://home/*")        // 匹配 app://home/123 ✓；app://home/a/b ✗
MLRouterPage("app://product/**")    // 多级贪婪匹配：app://product/123/sku456/detail ✓
```

通配符匹配的路径段自动作为参数传递，命名 `wildcard_1`, `wildcard_2`...，**严格按 URL 从左到右编号**（`*` 与 `**` 交错也不串位）；通配符表按捕获段数降序确定性排序，更具体的路径优先，不依赖 dyld 加载顺序：

```objc
MLRouterPage("app://product/*/sku*/detail")
// 打开 app://product/123/sku456/detail 后：
self.ml_routerParams;   // @{@"wildcard_1": @"123", @"wildcard_2": @"456"}
```

### 4. 参数传递

```objc
// ① URL Query：app://service/userinfo?userId=12345 → params[@"userId"]
// ② 链式参数：.withParam(@"userId", @"12345").withParams(@{...})
// ③ 属性映射：参数自动 KVC 映射到目标对象同名属性
// ④ 全量留底：self.ml_routerParams 拿到全部参数（含通配符捕获）
```

**属性映射支持的类型码**（`property_getAttributes` 逐码匹配）：

| 属性声明 | 类型码 | 映射行为 |
|---|---|---|
| `NSString *` / 对象 / `id` | `T@` | 直接 `setValue:forKey:` |
| `long long` / `NSInteger`(64位) | `Tq` | `longLongValue`（**精确**不丢精度） |
| `unsigned long long` | `TQ` | `unsignedLongLongValue` |
| `int` / `unsigned int` | `Ti` / `TI` | 截断到对应类型 |
| `short` / `unsigned short` / `unsigned char` | `Ts` / `TS` / `TC` | 正确映射（旧路由框架常见静默漏掉这三码） |
| `BOOL` | `TB` | `boolValue`（`"0"`/`"false"` → NO） |
| `float` / `double` | `Tf` / `Td` | `doubleValue` |
| `CGRect` 等结构体 | `T{...}` | **安全跳过** |
| **block** | `T@?` | **安全跳过**（防字符串写进 block 存储位的类型混淆） |

### 5. 拦截器（AOP 切面）

```objc
@interface DemoInterceptor : NSObject <MLRouterInterceptor>   // ⚠️ 协议必须声明
@end

@implementation DemoInterceptor
MLRouterInterceptorClass("DemoInterceptor", 10)   // 数字越小优先级越高，链内升序执行

- (void)processRequest:(MLRouterRequest *)request
                  next:(MLInterceptorNextBlock)next
                reject:(MLInterceptorRejectBlock)reject {
    request.withParam(@"timestamp", @([[NSDate date] timeIntervalSince1970]));  // 公共参数注入
    if (self.shouldReject) {
        reject([NSError errorWithDomain:@"Demo" code:403
                    userInfo:@{NSLocalizedDescriptionKey: @"请求被拦截"}]);
        return;                       // reject 后走兜底（携带该 error）
    }
    next(request);                    // 放行
}
@end
```

**拦截器契约**：框架每次路由都会重新实例化拦截器（应**无状态**）；`next`/`reject` 应在**同步**路径内调用——异步放行时方法路由的同步返回值不可用，须改用 `withCompletion`。拦截器里写共享状态必须自行加锁（并发路由下无锁 = 堆损坏型 SIGABRT，崩在哪条用例完全随机）。

### 6. Service 服务层（协议驱动服务发现）

组件间不互相依赖实现类，只依赖协议头；编译期防断链：

```objc
// 协议头（公开头文件，调用方只 import 它）
@protocol CartService <NSObject>
- (NSInteger)cartItemCount;
@end

// 实现方：自注册
@implementation CartServiceImpl
MLRouterService(CartService, CartServiceImpl)
- (NSInteger)cartItemCount { return 0; }
@end

// 调用方：强类型获取
id<CartService> cart = [MLRouterService serviceForProtocol:@protocol(CartService)];
```

- 运行时注册 / mock：`registerService:implClass:`、`unregisterService:`；存在性判断 `hasServiceForProtocol:`
- **双表模型**：`+reset` 只清运行时表与 tombstone，**不动编译期段表**（否则段注册服务在 App 生命周期内永久无法恢复）

### 7. Module 模块层（模块自举 + 生命周期）

```objc
@interface OrderModule : NSObject <MLRouterModule>    // ⚠️ 协议必须声明在 @interface 上
@end

@implementation OrderModule
+ (NSInteger)modulePriority { return 100; }                        // 类方法！越大越先
+ (NSArray<NSString *> *)moduleDependencies { return @[@"CartModule"]; }  // 类方法！
- (void)moduleSetup { /* 注册本模块的 services / routes */ }
- (void)moduleInit { /* 初始化私有资源 */ }
MLRouterModule(OrderModule)
@end
```

- `loadModules`：按**依赖拓扑排序**（Kahn 入度 + 循环依赖检测）初始化，**依赖关系优先于优先级**；先全部 `moduleSetup` 再全部 `moduleInit`
- 生命周期转发见「快速接入 Step 3」；openURL 多模块聚合返回值
- `ensureRoutesLoaded` 幂等契约：`loadModules` 内部已先确保段扫描完成，调用方无需关心顺序；但任何依赖路由表就绪的自定义代码应显式调用 `[MLRouter ensureRoutesLoaded]`，不要依赖 `+initialize` 懒触发时机

### 8. 治理层（动态路由 / 白名单 / 兜底 / 导出）

```objc
// 动态路由（运行时 / 远程下发；优先级低于静态段，动态重复注册 last-wins）
[MLRouter registerRoute:@"app://promo/**" handler:^id(NSDictionary *params, MLRouterRequest *request) {
    return @"promo-result";   // 返回 UIViewController 会自动 present
}];
[MLRouter unregisterRoute:@"app://promo/**"];

// 安全白名单（防 H5 等外部来源任意调 native）
[MLRouter setAllowedSchemes:[NSSet setWithObject:@"app"]];
[MLRouter setAllowedURLPaths:[NSSet setWithObject:@"app://safe/"]];
[MLRouter setRouteValidator:^BOOL(NSURL *url) { return YES; }];   // 最高优先级，整体接管白名单

// 降级兜底（handler 优先于 VC class）
[MLRouter setFallbackViewControllerClass:ErrorViewController.class];
[MLRouter setFallbackHandler:^id(MLRouterRequest *request, NSError *error) {
    // error.code：404 = 未命中；403 = 拦截器/白名单拦截；兜底 VC 携带 ml_fallbackErrorCode / ml_fallbackURL
    return nil;
}];

// 路由表导出（CI / 调试）
NSDictionary *table = [MLRouter exportRouteTable];   // pages/methods/views/wildcards/redirects/dynamic/services/modules...

// 测试隔离（两种粒度）
[MLRouter resetGovernance];   // 只清白名单/校验器/兜底，保留动态路由
[MLRouter resetRouter];       // 清全部（⚠️ 连模块自举注册的动态路由一起清）
```

### 9. PII 日志脱敏

路由失败诊断日志默认对敏感参数脱敏（默认键集：`token` / `access_token` / `password` / `pwd` / `passwd` / `phone` / `mobile` / `idcard` / `secret`，大小写不敏感）：

```objc
[MLRouter setRedactedQueryKeys:[NSSet setWithArray:@[@"token", @"session"]]];  // 自定义整体替换
[MLRouter setRedactedQueryKeys:nil];                                           // nil 恢复默认
```

### 10. CI 路由冲突检测

```bash
./scripts/mlrouter_validate.sh ./YourProject
# 扫描源码检测重复路由、旧式文件名推导宏告警、统计服务/模块注册数；发现重复路由非零退出码，可接 CI 卡口
```

---

## 六、注意事项与关键契约

### 接入期（最容易踩的静默坑）

1. **`-ObjC` 链接标志必须开启**，否则段宏注册整体不生效。
2. **⭐ 推荐显式类名宏**：旧宏内部用 `__FILE__` 推导类名，依赖「文件名 == 类名」约定，不符则 `NSClassFromString` 返回 nil、路由**静默失效**。显式宏（`MLRouterPageClass` 等）直接写类名，彻底消除该脆弱性；两种宏可混用（读取侧自动识别）。
3. **段宏 ≠ 注册成功，协议遵循才是准入校验**。Module 类必须声明 `<MLRouterModule>`，拦截器必须声明 `<MLRouterInterceptor>`。漏写不崩溃不报错（仅控制台一行 `❌ ... 未遵循 ... 协议，跳过`），表现为「完全合法的 URL 走 404」。**「配了却不生效」的第一个检查项永远是协议遵循。**
4. **`modulePriority` / `moduleDependencies` 是类方法（`+`）**。写成实例方法会让拓扑排序退化（依赖边一条没建）。

### 运行期

5. **双通道契约（最重要）**：`open()` 同步返回值是「受理信号」——页面路由 `@(YES)`、方法路由回业务值、View 路由回 `UIView`；**`open()` 永不返回 `UIViewController`，一旦拿到 VC = 该 URL 未命中走了兜底**（排查返回类型异常的最快判据）。`withCompletion` 回调值是「结果对象」——页面路由回**被 present 的 VC 实例**（唯一能拿到 VC 本体的通道）。**一句话：`open()` 回答「成不成」，`completion` 回答「成了之后拿到什么」。二者刻意不同，别去"统一"它们。**
6. **主线程契约**：页面路由的「VC 实例化 + KVC 参数映射 + present」是整体主线程工作单元，框架已 dispatch——**任意线程调 `open()` 都安全**。但业务代码不要自己 `[[SomeVC alloc] init]` 后交给框架 present（仍是后台线程碰 UI API）。
7. **方法路由返回值所有权按 ARC 方法家族区分**：`alloc/new/copy/mutableCopy/init` 开头的选择器返回 +1（框架 `__bridge_transfer` 接管）；其余返回 +0（框架 `objc_retainAutoreleasedReturnValue` 认领）。选择器名起错家族会导致偶发 `EXC_BAD_ACCESS`（崩在 autorelease pool 排空，与路由代码无关联）。
8. **异常穿透是显式契约**：框架内部**零** `@try/@catch`，handler / VC init / 拦截器抛出的 `NSException` 原样同步穿透给调用方。吞异常会把「数组越界」变成「页面莫名白屏」——远程下发的 handler 务必自行兜底。
9. **重定向链上限 16 跳，超限静默截断**（停在最后一跳继续当普通路由查，通常变 404，无日志）。重定向解析保留原 query；尾斜杠等价（`a/b/` ≡ `a/b`），但路径**中间**连续 `//` 不等价。
10. **白名单校验时机**：在重定向解析**之后**校验最终 URL；优先级 validator（整体接管，不叠加）> scheme > path 前缀；三者均 nil = 不启用，空集 = 全部拦截。
11. **动态路由命中判定**：静态段优先于动态路由；动态 handler 只要**被调用过**就算命中——返回 `nil` 不走兜底（`nil` 是合法业务返回值）。
12. **拦截器 reject 也走兜底**：与 404 一样回调兜底，携带拦截器 error（`reject(nil)` 时框架补 403）；未配置兜底返回 `nil`。
13. **方法签名**：方法路由选择器至少接收 `(NSDictionary *)params`，否则被拒绝并诊断；选择器不存在同样拒绝。
14. **内存管理**：链式 DSL 中 `withCompletion` block 已自动 copy；调用方自己的 block 保留注意 weak/strong dance。

### 测试期

15. **`resetRouter` 会连模块自举的动态路由一起清掉**：只想回滚白名单/兜底用 `resetGovernance`；清动态路由后恢复需 `reset` + `loadModules` 配对（`[MLRouterModuleManager reset]` 不清动态路由 handler）。
16. **`[MLRouterService reset]` 不清编译期段注册服务**（双表模型）。
17. **断言「有没有进 UI」要从父容器取值**（`nav.topViewController` / `presentedViewController`），不要从子 VC 反向引用取值——`push` 同步、`present` 的反向引用在转场中才建立。

---

## 七、测试与质量保障

### 两套测试体系（互为印证，不可互相替代）

| | `MLRouterTestKit` | `MLRouterIntegrationTests` |
|---|---|---|
| 形态 | 普通 pod，代码链接进 App | `test_spec` pod，只存在于 XCTest bundle |
| 跑在哪 | App 进程，Dashboard 可点、可自动化 | `xcodebuild test` 注入宿主 App |
| 定位 | 真实运行时行为：每个公开能力一条真实 UI 场景 + 自带断言 | 跨仓集成 + 精确断言：端到端、崩溃容错、性能复杂度 |
| 触发 | Dashboard / `-RTKitRunAll` / `-RTKitSelfCheck` | `xcodebuild test -scheme MLRouterIntegrationTests-Unit-Tests` |

### 当前质量基线（2026-09-18 实测）

- **单元/集成测试**：`Executed 184 tests, with 0 failures`（Debug 与 **Release** 双 configuration；Release 跑通即段注册/符号在 strip 下可用）
- **真实运行时 runner**：68 场景（14 组）**216 断言全通过**（跑在真实 App 启动路径：`loadModules` → 段扫描 → 模块自举 → 段注册路由）
- **聚合自检冒烟**：17 断言 0 失败
- **构建健康**：`pod lib lint` 通过，零警告

**一条命令全量回归：`MLRouter/Scripts/verify_all.sh`**（lint → Debug/Release 单测 → 构建安装宿主 App → runner 全量 + 自检，五层全部自动判定并进退出码）。**iOS 新版本 GM / Xcode 大版本升级时跑一次**，即是平台演进年度回归。

### 免点击入口（CI / 自动化）

```bash
# 一键全量 68 场景（约 2.5 分钟，总报告顶部自带失败清单）：
xcrun simctl launch <sim_udid> com.cfh.router.demo.test.RouterDemo -RTKitRunAll
# 核心不变量快速冒烟：
xcrun simctl launch <sim_udid> com.cfh.router.demo.test.RouterDemo -RTKitSelfCheck
# 判定链负向自检（注入一条必败断言，验证失败判定路径；平时不触发）：
xcrun simctl launch <sim_udid> com.cfh.router.demo.test.RouterDemo -RTKitRunAll -RTKitFailInject
```

### 运行集成测试

```bash
cd RouterDemo && pod install && open RouterDemo.xcworkspace
xcodebuild test \
  -workspace RouterDemo.xcworkspace \
  -scheme MLRouterIntegrationTests-Unit-Tests \
  -destination 'platform=iOS Simulator,name=iPhone 8'
```

> ⚠️ scheme 必须是 `MLRouterIntegrationTests-Unit-Tests`（宿主 scheme 没配 test action）；destination 必须具名模拟器（`generic/platform=iOS Simulator` 在 Apple Silicon 上会误报缺 arm64 slice）。`test_spec` 已设 `requires_app_host = true`，pod 集成需显式 `:testspecs => ['Tests']`。

### 测试覆盖矩阵（集成测试 184 条）

| 场景 | 测试类 | 关键用例 |
|------|--------|----------|
| 页面/方法/重定向/拦截器/参数映射 | `MLRouterCoreTests` | 精确匹配、同步返回、`A→B→C` 防环、优先级、reject 阻断、返回值所有权 P0 |
| 链式 DSL / 转场 / 优先级 / 重定向语义 | `MLRouterDSLAndSemanticsTests` | DSL 全集、Block 参数 copy P1、Push/Present 分支、白名单时序、兜底契约 |
| 错误输入 / 并发 / 边界 | `MLRouterEdgeCaseTests` | 畸形 URL 全安全、24 路并发、重定向环、异步 next 契约 |
| 参数类型全覆盖 | `MLRouterParamTypeTests` | 13 类型码逐一断言、大整数精度、block 防类型混淆、畸形值 |
| 崩溃 / 容错 | `MLRouterRobustnessTests` | 异常穿透、锁不泄漏、重入不死锁、超长 URL / Emoji、1000 次重复注册、16 跳守卫边界 |
| 性能 / 复杂度 | `MLRouterPerformanceTests` | O(1) 查找（比值断言）、通配符线性、冷启动预算、导出预算 |
| Service / Module / 治理 | `MLRouterServiceTests` 等 | 双表模型、拓扑排序裁决、生命周期全集、动态路由/白名单/兜底 |
| 工程防线 | `MLRouterOpsReadinessTests` | 冷启动时序自愈、错误码可区分（404/403）、鉴权切面、契约快照（防文档腐烂）、fuzz 1000 URL、PII 脱敏、乱序不变量 |
| 扩展进程 / 无宿主 | `MLRouterHostlessTests` | 非 UI 路由零 UIApplication 依赖、无 keyWindow 页面路由 `completion(nil)` + 可归因诊断 |
| 组件化端到端 | `MLRouterComponentIntegrationTests` | 双本地私有仓段宏自注册、跨仓服务消费与拓扑、路由表导出 |

### 真实 UI 场景 Dashboard（68 场景 / 14 组）

宿主 App 启动后自动打开 `rtkit://test/dashboard`，每个公开能力对应一条可点击场景，点完即弹 PASS/FAIL 与实测值。另有 `mlcomp://cart/dashboard`（12 按钮）演示组件化场景。分组覆盖：段宏静态路由 / DSL / 重定向 / 动态路由 / 治理 / 拦截器 / 服务发现 / 模块化生命周期 / 错误路径 / 聚合自检 / 线程内存 / 健壮性性能 / 跨仓组件 / 工程防线。

---

## 八、示例项目

参考仓库根目录 `RouterDemo` 完整示例（页面/方法/视图路由、通配符、拦截器、重定向、ModuleA/ModuleB 多仓组件化）。`LocalPods/` 模拟真实多仓结构：

- `MLCartComponent` / `MLUserComponent` —— 业务组件样例（服务自注册、跨仓依赖拓扑）
- `MLRouterTestKit` —— 框架全能力测试 Dashboard（真实 UI 场景 + 自带断言）
- `MLRouterIntegrationTests` —— 集成测试（`test_spec`，自动化测试唯一所在地）

## License

MIT
