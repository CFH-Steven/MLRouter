// CartViewController.h
// 组件页面：段宏自注册的真实 UI 测试页面（演示组件页面路由 + 参数映射 + 站内互跳）

#import <UIKit/UIKit.h>

@interface CartViewController : UIViewController

/// 演示框架参数映射：withParam 传 @[@"sourceTag": ...] 会自动赋值同名属性
@property (nonatomic, copy) NSString *sourceTag;

@end
