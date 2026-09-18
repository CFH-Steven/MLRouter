// CartBadgeView.h
// View 路由目标视图：URL mlcomp://cart/badge 返回视图实例

#import <UIKit/UIKit.h>

@interface CartBadgeView : UIView

/// 演示框架参数映射到视图属性
@property (nonatomic, copy) NSString *badgeText;

@end
