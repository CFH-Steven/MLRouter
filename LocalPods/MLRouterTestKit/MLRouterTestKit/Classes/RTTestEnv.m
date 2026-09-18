// RTTestEnv.m
#import "RTTestEnv.h"

@implementation RTTestEnv {
    NSMutableArray<NSString *> *_lines;
    NSInteger _pass;
    NSInteger _fail;
}

+ (instancetype)shared {
    static RTTestEnv *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[RTTestEnv alloc] init]; });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _lines = [NSMutableArray array];
        _pass = 0;
        _fail = 0;
    }
    return self;
}

- (void)beginSuite:(NSString *)suiteName {
    [_lines addObject:[NSString stringWithFormat:@"\n──────── %@ ────────", suiteName ?: @"(未命名)"]];
}

- (void)check:(BOOL)condition name:(NSString *)name detail:(NSString *)detail {
    if (condition) _pass++; else _fail++;
    NSString *tail = detail.length > 0 ? [NSString stringWithFormat:@"  ·  %@", detail] : @"";
    [_lines addObject:[NSString stringWithFormat:@"%@ %@%@", condition ? @"✅" : @"❌", name ?: @"", tail]];
}

- (void)info:(NSString *)message {
    [_lines addObject:[NSString stringWithFormat:@"ℹ️ %@", message ?: @""]];
}

- (void)reset {
    [_lines removeAllObjects];
    _pass = 0;
    _fail = 0;
}

- (NSInteger)passCount { return _pass; }
- (NSInteger)failCount { return _fail; }

- (NSString *)report {
    if (_lines.count == 0) return @"(尚无记录 —— 请先点任意场景按钮)";
    return [_lines componentsJoinedByString:@"\n"];
}

- (NSString *)summary {
    return [NSString stringWithFormat:@"%@ %ld 通过 · %@ %ld 失败",
            _fail == 0 ? @"✅" : @"⚠️", (long)_pass,
            _fail == 0 ? @"✅" : @"❌", (long)_fail];
}

- (NSInteger)totalLineCount {
    return (NSInteger)_lines.count;
}

- (NSString *)reportFromLine:(NSInteger)startIndex {
    if (startIndex < 0) startIndex = 0;
    if (startIndex >= (NSInteger)_lines.count) return @"(本次场景没有产生任何断言记录)";
    NSArray *slice = [_lines subarrayWithRange:NSMakeRange((NSUInteger)startIndex,
                                                           _lines.count - (NSUInteger)startIndex)];
    return [slice componentsJoinedByString:@"\n"];
}

@end
