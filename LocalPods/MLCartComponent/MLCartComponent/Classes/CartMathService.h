// CartMathService.h

#import <Foundation/Foundation.h>

@interface CartMathService : NSObject

/// 方法路由目标方法：参数签名约定 (NSDictionary *)params，可带 (void(^)(id))completion
- (NSNumber *)sumWithParams:(NSDictionary *)params;

/// 异步版方法路由：通过 completion 异步回传结果
- (void)asyncSumWithParams:(NSDictionary *)params completion:(void (^)(id _Nullable result))completion;

@end
