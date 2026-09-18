// RTInterceptors.h
// 拦截器职责链的测试样本与观测日志。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 拦截器进链顺序观测日志
@interface RTInterceptorLog : NSObject
+ (void)append:(NSString *)entry;
+ (NSArray<NSString *> *)entries;
+ (void)reset;
+ (NSString *)reportText;
/// 首次出现某条目的下标（找不到返回 -1）
+ (NSInteger)indexOfEntryContaining:(NSString *)keyword;
@end

NS_ASSUME_NONNULL_END
