// DemoService.h
#import <Foundation/Foundation.h>

// 组件化服务协议示例：购物车模块对外暴露的接口。
// 调用方（如订单模块）只依赖此协议头，不依赖 DemoCartServiceImpl 实现，
// 从而实现模块解耦、可独立编译与单元测试。
@protocol DemoCartService <NSObject>
- (NSInteger)cartItemCount;
- (void)addToCart:(NSString *)sku;
@end
