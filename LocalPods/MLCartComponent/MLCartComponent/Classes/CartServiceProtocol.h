// CartServiceProtocol.h
// 组件对外协议（组件化的关键）：调用方只依赖协议头，零硬编码 URL，编译期防断链。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol CartServiceProtocol <NSObject>

/// 购物车商品数量
- (NSInteger)itemCount;
/// 组件标识
- (NSString *)componentName;

@end

NS_ASSUME_NONNULL_END
