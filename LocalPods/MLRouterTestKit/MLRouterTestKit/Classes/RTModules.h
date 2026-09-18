// RTModules.h
// 模块化能力的测试样本与观测日志。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 模块生命周期 / 拓扑顺序观测日志。三个测试模块与 AppDelegate 生命周期转发都会写它，
/// Dashboard 直接读出来做「生命周期到底有没有生效」的现场取证。
@interface RTModuleLog : NSObject
+ (void)append:(NSString *)entry;
+ (NSArray<NSString *> *)entries;
+ (void)reset;
/// 首次出现某条目的下标（找不到返回 -1），用于断言先后顺序
+ (NSInteger)indexOfEntryContaining:(NSString *)keyword;
+ (NSString *)reportText;
@end

NS_ASSUME_NONNULL_END
