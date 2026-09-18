// CartServiceImpl.m
// 服务层自注册：MLRouterService(协议名, 实现类名) —— 传标识符，宏内部自动转字符串。
// 编译期写入 __DATA,MLServiceSect，运行时被 MLRouter 的 dyld 扫描自动回填到服务表。

#import "CartServiceImpl.h"
#import <MLRouter/MLRouterHeader.h>

@implementation CartServiceImpl

// 段宏必须写在 @implementation 内部
MLRouterService(CartServiceProtocol, CartServiceImpl)

- (NSInteger)itemCount {
    return 3;
}

- (NSString *)componentName {
    return @"CartComponent";
}

@end
