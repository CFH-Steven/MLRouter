// MLRouterRequest.h
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class MLRouter;
@class MLRouterRequest;

// 转场转场式样枚举公开
typedef NS_ENUM(NSInteger, MLRouteTransitionStyle) {
    MLRouteTransitionStylePush = 0,    // 默认：导航栏 Push 推进
    MLRouteTransitionStylePresent,     // 模态：Present 弹出并自动包装顶层双导航栏
};

// 极致全链式点语法 Block 强类型
typedef MLRouterRequest * _Nonnull (^MLWithParamBlock)(NSString * _Nonnull key, id _Nonnull value);
typedef MLRouterRequest * _Nonnull (^MLWithCompletionBlock)(void (^ _Nonnull completion)(id _Nullable result));
typedef MLRouterRequest * _Nonnull (^MLWithStyleBlock)(MLRouteTransitionStyle style);
typedef MLRouterRequest * _Nonnull (^MLWithBoolBlock)(BOOL animated);
typedef MLRouterRequest * _Nonnull (^MLWithParamsBlock)(NSDictionary * _Nonnull params);
typedef id _Nullable (^MLOpenBlock)(void);

@interface MLRouterRequest : NSObject

@property (nonatomic, copy) NSString * _Nonnull urlStr;
@property (nonatomic, strong) NSMutableDictionary * _Nonnull params;
@property (nonatomic, copy) void (^ _Nullable completionBlock)(id _Nullable result);
@property (nonatomic, assign) MLRouteTransitionStyle transitionStyle;
@property (nonatomic, assign) BOOL animated;

- (instancetype _Nonnull)initWithURL:(NSString * _Nonnull)urlStr router:(MLRouter * _Nonnull)router;

// 🔒 外部可见的链式语法 DSL 物理节点
@property (nonatomic, readonly, copy) MLWithParamBlock _Nonnull withParam;
@property (nonatomic, readonly, copy) MLWithCompletionBlock _Nonnull withCompletion;
@property (nonatomic, readonly, copy) MLWithStyleBlock _Nonnull withTransitionStyle;
@property (nonatomic, readonly, copy) MLWithBoolBlock _Nonnull withAnimation;
@property (nonatomic, readonly, copy) MLOpenBlock _Nonnull open;
@property (nonatomic, readonly, copy) MLWithParamsBlock _Nonnull withParams;

@end
