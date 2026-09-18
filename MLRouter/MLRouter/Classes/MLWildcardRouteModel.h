// MLWildcardRouteModel.h
#import <Foundation/Foundation.h>

@interface MLWildcardRouteModel : NSObject

@property (nonatomic, strong) NSRegularExpression * _Nonnull regex;
@property (nonatomic, strong) NSArray<NSString *> * _Nonnull paramKeys; // 序列化后的万能星号捕获标签组
@property (nonatomic, strong) id _Nonnull routeInfo;                   // 绑定具体的 Class 或方法字典

@end
