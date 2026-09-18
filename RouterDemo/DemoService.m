// DemoService.m
#import "DemoService.h"
#import <MLRouter/MLRouterHeader.h>

@interface DemoCartServiceImpl : NSObject <DemoCartService>
@property (nonatomic, assign) NSInteger count;
@end

@implementation DemoCartServiceImpl

- (NSInteger)cartItemCount { return self.count; }

- (void)addToCart:(NSString *)sku {
    self.count += 1;
    NSLog(@"[DemoCart] addToCart: %@", sku);
}

// 协议驱动服务发现：编译期写入 Mach-O 段 MLServiceSect，运行时由 MLRouter 统一扫描回填。
MLRouterService(DemoCartService, DemoCartServiceImpl)

@end
