// MLRouterAnnotation.h (终极物理防链接裁剪、无分号自闭合、0延迟完全体版)
#ifndef MLRouterAnnotation_h
#define MLRouterAnnotation_h

#import <Foundation/Foundation.h>

// 全网 5 大物理隔离段共享同一套内存对齐步长结构体
typedef struct MLRouterSectionData {
    const char * _Nonnull urlPath;
    const char * _Nonnull className;     // 存储 __FILE__ 路径用于推导类名
    const char * _Nullable selectorName; // 方法名选择器 / 或存储拦截器优先级
} MLRouterSectionData;

typedef struct MLRouterSectionData MLPageSectionData;
typedef struct MLRouterSectionData MLMethodSectionData;
typedef struct MLRouterSectionData MLViewSectionData;
typedef struct MLRouterSectionData MLRedirectSectionData;
typedef struct MLRouterSectionData MLInterceptorSectionData;

// 二级宏延时展开转换引擎（无条件保证变量名后缀数字绝对唯一，防 redefinition 冲突）
#define ML_CONCAT_HIDDEN(prefix, counter) prefix##_##counter
#define ML_CONCAT(prefix, counter) ML_CONCAT_HIDDEN(prefix, counter)


// ============================================================================
// 🔒 原子级常规自注册宏（外部免手写分号自闭合、100% 防段类型基因冲突）
// ============================================================================

#define _MLRegisterPage(url_path) \
__attribute__((used, section("__DATA,MLPageSect"))) \
static const MLRouterSectionData ML_CONCAT(__MLPAGE__, __COUNTER__) = { url_path, __FILE__, nil };

#define _MLRegisterMethod(url_path, selector_name) \
__attribute__((used, section("__DATA,MLMethodSect"))) \
static const MLRouterSectionData ML_CONCAT(__MLMETHOD__, __COUNTER__) = { url_path, __FILE__, selector_name };

#define _MLRegisterView(url_path) \
__attribute__((used, section("__DATA,MLViewSect"))) \
static const MLRouterSectionData ML_CONCAT(__MLVIEW__, __COUNTER__) = { url_path, __FILE__, nil }; 

#define _MLRegisterRedirect(from_url_path, to_url_path) \
__attribute__((used, section("__DATA,MLRedirectSect"))) \
static const MLRedirectSectionData ML_CONCAT(__MLREDIRECT__, __COUNTER__) = { from_url_path, "", to_url_path };

/**
 5. 📌【全自动拦截器自注册宏 - 物理段无损对齐版】
 规范：无分号自闭合，数据完美躺入专属物理段 __DATA,MLInterceptSect。
 ⚠️ 必须写在拦截器类 @implementation 内部！末尾严禁手动写分号！
 */
#define _MLRegisterInterceptor(priority) \
__attribute__((used, section("__DATA,MLInterceptSect"))) \
static const MLInterceptorSectionData ML_CONCAT(__MLINTERCEPTOR__, __COUNTER__) = { "", __FILE__, #priority };

// 服务发现段与模块段复用同一套 3 字段结构体：
// Service 用 urlPath=协议名、className=实现类名；Module 用 className=模块类名。
typedef struct MLRouterSectionData MLServiceSectionData;
typedef struct MLRouterSectionData MLModuleSectionData;

// 协议驱动服务发现：MLRouterService(ProtocolName, ImplClassName)
// 编译期写入 __DATA,MLServiceSect，运行时由 MLRouter 统一扫描回填到服务表。
#define _MLRegisterService(protocol_name, impl_class) \
__attribute__((used, section("__DATA,MLServiceSect"))) \
static const MLRouterSectionData ML_CONCAT(__MLSERVICE__, __COUNTER__) = { #protocol_name, #impl_class, nil };

// 模块自注册：MLRouterModule(ModuleClassName)
// 编译期写入 __DATA,MLModuleSect，运行时由 MLRouterModuleManager 扫描并按依赖拓扑排序初始化。
#define _MLRegisterModule(cls) \
__attribute__((used, section("__DATA,MLModuleSect"))) \
static const MLRouterSectionData ML_CONCAT(__MLMODULE__, __COUNTER__) = { "", #cls, nil };


// ============================================================================
#define MLRouterPage(url_path)                       _MLRegisterPage(url_path);
#define MLRouterMethod(url_path, selector_name)     _MLRegisterMethod(url_path, selector_name);
#define MLRouterView(url_path)                       _MLRegisterView(url_path);
#define MLRouterRedirect(from_url_path, to_url_path) _MLRegisterRedirect(from_url_path, to_url_path);
#define MLRouterInterceptor(priority)                _MLRegisterInterceptor(priority);

// 组件化：协议驱动服务发现 + 模块自注册
#define MLRouterService(protocol_name, impl_class)   _MLRegisterService(protocol_name, impl_class);
#define MLRouterModule(cls)                           _MLRegisterModule(cls);


// ============================================================================
// 🔒【根治方案】显式类名自注册宏（推荐）
// 旧宏依赖"文件名 == 类名"隐含约定（__FILE__ 推导），一旦文件名与类名不符，
// NSClassFromString 将返回 nil，路由静默失效。新宏直接写入真实类名字符串，
// 运行时读取侧会智能识别：含 "/" 或 ".m/.h/.mm" 后缀走文件路径推导，
// 否则直接当类名使用，彻底消除该脆弱性。
// ============================================================================

#define _MLRegisterPageClass(class_name, url_path) \
__attribute__((used, section("__DATA,MLPageSect"))) \
static const MLRouterSectionData ML_CONCAT(__MLPAGE__, __COUNTER__) = { url_path, class_name, nil };

#define _MLRegisterMethodClass(class_name, url_path, selector_name) \
__attribute__((used, section("__DATA,MLMethodSect"))) \
static const MLRouterSectionData ML_CONCAT(__MLMETHOD__, __COUNTER__) = { url_path, class_name, selector_name };

#define _MLRegisterViewClass(class_name, url_path) \
__attribute__((used, section("__DATA,MLViewSect"))) \
static const MLRouterSectionData ML_CONCAT(__MLVIEW__, __COUNTER__) = { url_path, class_name, nil };

#define _MLRegisterInterceptorClass(class_name, priority) \
__attribute__((used, section("__DATA,MLInterceptSect"))) \
static const MLInterceptorSectionData ML_CONCAT(__MLINTERCEPTOR__, __COUNTER__) = { "", class_name, #priority };

#define MLRouterPageClass(class_name, url_path)                       _MLRegisterPageClass(class_name, url_path);
#define MLRouterMethodClass(class_name, url_path, selector_name)     _MLRegisterMethodClass(class_name, url_path, selector_name);
#define MLRouterViewClass(class_name, url_path)                       _MLRegisterViewClass(class_name, url_path);
#define MLRouterInterceptorClass(class_name, priority)                _MLRegisterInterceptorClass(class_name, priority);

#endif
