// MLRouterRequest.m
#import "MLRouterRequest.h"
#import "MLRouter.h"

@interface MLRouterRequest ()
// 弱引用中枢执行调度器，完美掐死去单例频繁创建下的循环引用隐患
@property (nonatomic, weak) MLRouter *associatedRouter;
@property (nonatomic, strong) MLRouter *strongRouterKeepAlive;
@end

@implementation MLRouterRequest

- (instancetype)initWithURL:(NSString *)urlStr router:(MLRouter *)router {
    if (self = [super init]) {
        _urlStr = urlStr;
        _associatedRouter = router;
        _strongRouterKeepAlive = router;
        _params = [NSMutableDictionary dictionary];
        _transitionStyle = MLRouteTransitionStylePush;
        _animated = YES;
    }
    return self;
}

- (MLWithParamBlock)withParam {
    __weak typeof(self) weakSelf = self;
    return ^MLRouterRequest *(NSString *key, id value) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        if (!key || !value) return strongSelf;
        // NSBlock 不是公开类（真实类是 __NSMallocBlock__ 等），NSClassFromString(@"NSBlock") 恒为 nil。
        // 改为按类名字符串判断是否 Block 类型，命中则显式 copy，避免栈 block 逃逸。
        NSString *valueClassName = NSStringFromClass([value class]);
        if ([valueClassName containsString:@"Block"]) {
            strongSelf.params[key] = [value copy];
        } else if ([value respondsToSelector:@selector(copyWithZone:)]) {
            strongSelf.params[key] = [value copy];
        } else {
            strongSelf.params[key] = value;
        }
        return strongSelf;
    };
}

- (MLWithParamsBlock)withParams {
    __weak typeof(self) weakSelf = self;
    return ^MLRouterRequest *(NSDictionary *params) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !params || params.count == 0) return strongSelf;
        NSArray *allKeys = params.allKeys;
        for (NSString *key in allKeys) {
            strongSelf.withParam(key, params[key]);
        }
        return strongSelf;
    };
}

- (MLWithCompletionBlock)withCompletion {
    __weak typeof(self) weakSelf = self;
    return ^MLRouterRequest *(void (^completion)(id)) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        strongSelf.completionBlock = completion;
        return strongSelf;
    };
}

- (MLWithStyleBlock)withTransitionStyle {
    __weak typeof(self) weakSelf = self;
    return ^MLRouterRequest *(MLRouteTransitionStyle style) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        strongSelf.transitionStyle = style;
        return strongSelf;
    };
}

- (MLWithBoolBlock)withAnimation {
    __weak typeof(self) weakSelf = self;
    return ^MLRouterRequest *(BOOL animated) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        strongSelf.animated = animated;
        return strongSelf;
    };
}

- (MLOpenBlock)open {
    __weak typeof(self) weakSelf = self;
    return ^id _Nullable {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        id returnValue = [strongSelf.associatedRouter executeRequest:strongSelf];
        strongSelf.strongRouterKeepAlive = nil;
        return returnValue;
    };
}

// MLRouterRequest.m 内部最下方补齐此处的析构自愈逻辑
- (void)dealloc {
    NSLog(@"[MLRouterRequest] dealloc called");
    if (self.strongRouterKeepAlive != nil) {
        self.strongRouterKeepAlive = nil;
    }
    
    #if DEBUG
    if (self.completionBlock == nil) {
        // 说明确实是一次未正常执行 open 的异常出栈生命周期
    }
    #endif
}

@end
