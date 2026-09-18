// RTServices.m
// 服务发现测试样本：实现类在编译期写入 __DATA,MLServiceSect，运行时由段扫描回填。

#import "RTServices.h"
#import <MLRouter/MLRouterHeader.h>
#import <MLRouter/MLRouterService.h>

@interface RTGreetingServiceImpl : NSObject <RTGreetingService>
@end

@implementation RTGreetingServiceImpl

// 段宏：协议名 + 实现类名（裸名，宏内部会 # 转字符串）
MLRouterService(RTGreetingService, RTGreetingServiceImpl)

- (NSString *)greetingForUser:(NSString *)user {
    return [NSString stringWithFormat:@"Hi %@, from RTGreetingServiceImpl", user.length > 0 ? user : @"(匿名)"];
}

- (NSInteger)callCount { return 42; }

@end

@implementation RTServices

+ (NSString *)describeRegisteredServices {
    NSArray<NSString *> *protocols = [MLRouterService exportedServiceProtocols];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"已注册服务协议共 %lu 个：", (unsigned long)protocols.count]];
    for (NSString *name in protocols) {
        [lines addObject:[NSString stringWithFormat:@"  · %@", name]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

@end
