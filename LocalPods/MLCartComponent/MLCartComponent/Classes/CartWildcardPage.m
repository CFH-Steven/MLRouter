// CartWildcardPage.m
// 通配符捕获的参数以 wildcard_1、wildcard_2 … 命名，随 ml_routerParams 全量留底。

#import "CartWildcardPage.h"
#import <MLRouter/MLRouterHeader.h>

@implementation CartWildcardPage

MLRouterPageClass("CartWildcardPage", "mlcomp://cart/item/*")

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.title = @"通配符页面";

    NSString *w1 = self.ml_routerParams[@"wildcard_1"] ?: @"(未捕获)";
    UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
    label.numberOfLines = 0;
    label.text = [NSString stringWithFormat:@"通配符页面\n捕获参数 wildcard_1 = %@\n\n全量参数：%@", w1, self.ml_routerParams];
    label.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:label];
}

@end
