//
//  TestViewController.m
//  RouterDemo
//
//  Created by cfh on 2026/7/29.
//

#import "TestViewController.h"
#import <MLRouter/MLRouterHeader.h>
@interface TestViewController ()

@end

@implementation TestViewController
MLRouterPageClass("TestViewController", "app://Test/index")
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    // Do any additional setup after loading the view.
}

MLRouterMethodClass("TestViewController", "app://Test/service", "textService:block:")
+ (NSString *)textService:(NSDictionary *)params block:(void(^)(id result))block {
    if (block) {
        block(@{@"result":@"异步返回"});
    }
    return @"我的啊";
}

/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

@end
