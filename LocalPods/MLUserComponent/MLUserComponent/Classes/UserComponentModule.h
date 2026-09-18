// UserComponentModule.h
// 用户组件模块：声明跨仓依赖 CartComponentModule，验证拓扑排序
//
// ⚠️ 必须显式声明 <MLRouterModule> 协议遵循，理由同 CartComponentModule：
// 段宏只登记类名，真正的准入校验是 `conformsToProtocol:@protocol(MLRouterModule)`。

#import <Foundation/Foundation.h>
#import <MLRouter/MLRouterModule.h>

@interface UserComponentModule : NSObject <MLRouterModule>

/// 是否已执行 moduleInit
+ (BOOL)didInit;
/// moduleInit 执行时 CartComponentModule 是否已 init 完成（验证跨仓拓扑顺序）
+ (BOOL)cartModuleInitedFirst;

@end
