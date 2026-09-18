// CartBadgeView.m
// View 路由自注册：MLRouterViewClass(类名, url)。open() 直接返回视图实例（不发生转场）。

#import "CartBadgeView.h"
#import <MLRouter/MLRouterHeader.h>

@implementation CartBadgeView

MLRouterViewClass("CartBadgeView", "mlcomp://cart/badge")

- (instancetype)initWithFrame:(CGRect)frame {
    CGRect f = CGRectIsEmpty(frame) ? CGRectMake(0, 0, 160, 44) : frame;
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.85];
        self.layer.cornerRadius = 22;

        UILabel *label = [[UILabel alloc] initWithFrame:self.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont boldSystemFontOfSize:14];
        label.text = @"🛒 购物车 3";
        label.tag = 1001;
        [self addSubview:label];
    }
    return self;
}

- (void)setBadgeText:(NSString *)badgeText {
    _badgeText = [badgeText copy];
    UILabel *label = [self viewWithTag:1001];
    label.text = badgeText ?: @"🛒";
}

@end
