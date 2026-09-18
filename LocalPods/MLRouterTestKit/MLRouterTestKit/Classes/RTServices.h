// RTServices.h
// 协议驱动服务发现的测试样本。调用方只 import 本协议头，实现由段宏自注册。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 测试用服务协议：验证「只依赖协议、不依赖实现」能否跨模块拿到实例
@protocol RTGreetingService <NSObject>
- (NSString *)greetingForUser:(NSString *)user;
- (NSInteger)callCount;
@end

/// 一个永远不会有实现类的协议，用于验证「未注册协议返回 nil」
@protocol RTMissingService <NSObject>
- (void)neverCalled;
@end

@interface RTServices : NSObject
/// 导出当前全部已注册服务协议名（人读文本，Dashboard 展示）
+ (NSString *)describeRegisteredServices;
@end

NS_ASSUME_NONNULL_END
