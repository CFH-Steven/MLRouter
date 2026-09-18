// RTPages.h
// 测试用页面/视图/方法路由宿主。全部走编译期段宏自注册，宿主零手动接线。
// 命名前缀统一 RT（RouterTest），URL scheme 统一 rtkit://，与业务组件（mlcomp/mluser）隔离。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 参数留底 + 类型映射验证页（rtkit://page/echo）
/// 用 query 或 withParam 传入 sourceTag / count / flag / ratio，页面会回显映射结果，
/// 同时把框架留底的 ml_routerParams 全量字典打印出来。
@interface RTParamsEchoViewController : UIViewController
@property (nonatomic, copy) NSString *sourceTag;
@property (nonatomic, assign) NSInteger count;
@property (nonatomic, assign) BOOL flag;
@property (nonatomic, assign) double ratio;
/// 以下 4 个是「参数映射类型回归」锚点（对应框架 _safelyMapParameters: 的类型码分支）：
/// 旧框架实现漏了 short(Ts) / unsigned short(TS) / unsigned char(TC) —— 静默跳过、属性恒 0；
/// block(T@?) 则会被误当对象属性写入 URL 字符串（类型混淆，调用必崩）。J1 聚合自检依赖它们。
@property (nonatomic, assign) short shortVal;
@property (nonatomic, assign) unsigned short uShortVal;
@property (nonatomic, assign) unsigned char uCharVal;
@property (nonatomic, copy) void (^callback)(void);
/// J1 聚合自检的同步取值点：setMl_routerParams: hook 里记录最近一次被映射的实例
/// （页面路由的参数映射在 open() 内同步完成，无需等异步 completion）。
+ (instancetype)lastMappedEchoVC;
@end

/// 兜底页（不注册任何路由，只用于 setFallbackViewControllerClass:）
@interface RTFallbackViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
