// MLRouterParamTypeTests.m
// 多类型参数映射全覆盖。
//
// 背景：`_safelyMapParameters:` 走 `property_getAttributes` 拿到类型码后逐个匹配。
// 旧实现只覆盖了 Ti / Tq / TI / TQ + TB / Tc + Tf / Td，
// **漏掉 short(`Ts`) / unsigned short(`TS`) / unsigned char(`TC`)** —— 三种属性彻底静默跳过：
// 路由能命中、页面能打开、参数就是不生效，排查时毫无线索。
// 另有一处更危险的：block 属性编码是 `T@?`，同样以 `T@` 开头，会被当成普通对象属性
// 直接 `setValue:` 一个字符串进去 —— 不报错、不崩溃，但之后任何一次调用该 block
// 都是拿字符串当函数指针，必崩（且崩溃栈完全看不出是路由干的）。
//
// 本文件把这些全部钉住：每一个类型码分支都有对应用例，两个「必须安全跳过」的类型也有。

#import <XCTest/XCTest.h>
#import "MLRouterTestSupport.h"

@interface MLRouterParamTypeTests : XCTestCase
@end

@implementation MLRouterParamTypeTests

- (void)setUp {
    [super setUp];
    [TestCapture reset];
    [MLRouter resetRouter]; // 清动态路由 / 白名单 / 兜底；段注册常驻
}

#pragma mark - 辅助

/// 从 URL query 打开全类型页面。
/// 走 query 是有意为之：**真实场景里 URL 参数永远是字符串**，必须验证字符串 → 标量的转换。
- (TestAllTypesViewController *)openWithQuery:(NSString *)query {
    NSString *url = [@"mltest://page/alltypes" stringByAppendingString:(query ?: @"")];
    id ret = MLRouter.create.build(url).open();
    XCTAssertEqualObjects(ret, @(YES), @"页面路由 open() 应同步返回受理信号 @(YES)");
    XCTAssertFalse([ret isKindOfClass:[UIViewController class]], @"open() 永不返回 UIViewController");
    return [self capturedVC];
}

/// 用 withParams 传原生对象（NSNumber / NSNull 等），验证非字符串来源的映射。
- (TestAllTypesViewController *)openWithNativeParams:(NSDictionary *)params {
    MLRouterRequest *req = MLRouter.create.build(@"mltest://page/alltypes");
    if (params.count > 0) {
        req = req.withParams(params); // 链式 DSL 返回同一请求对象
    }
    req.open();
    return [self capturedVC];
}

/// TestAllTypesViewController 重写了 ml_routerParams 的 setter，把实例透给 TestCapture。
- (TestAllTypesViewController *)capturedVC {
    id last = [TestCapture lastVC];
    XCTAssertTrue([last isKindOfClass:[TestAllTypesViewController class]],
                  @"应通过 ml_routerParams setter 抓到 TestAllTypesViewController 实例");
    return (TestAllTypesViewController *)last;
}

#pragma mark - 全部类型码分支

/// 一条用例覆盖全部 13 个标量类型码 + 对象类型。任何一个分支被改坏都会在这里红。
- (void)testEveryScalarTypeCodeIsMapped {
    TestAllTypesViewController *vc = [self openWithQuery:
        @"?objVal=hello"
         "&integerVal=99"
         "&longLongVal=9007199254740993"
         "&intVal=7"
         "&uIntVal=4000000000"
         "&shortVal=1234"
         "&uShortVal=54321"
         "&charVal=65"
         "&uCharVal=250"
         "&boolVal=1"
         "&floatVal=1.5"
         "&doubleVal=3.25"];

    XCTAssertEqualObjects(vc.objVal, @"hello", @"T@ 对象分支应直接赋值");
    XCTAssertEqual(vc.integerVal, 99, @"Tq（NSInteger）分支");
    XCTAssertEqual(vc.longLongVal, 9007199254740993LL, @"Tq（long long）分支，且不得被 double 中转截断");
    XCTAssertEqual(vc.intVal, 7, @"Ti（int）分支");
    XCTAssertEqual(vc.uIntVal, 4000000000U, @"TI（unsigned int）分支");
    XCTAssertEqual(vc.shortVal, 1234, @"Ts（short）分支 —— 旧实现完全没有这个分支");
    XCTAssertEqual(vc.uShortVal, 54321, @"TS（unsigned short）分支 —— 旧实现完全没有这个分支");
    XCTAssertEqual(vc.charVal, 65, @"Tc（char）分支");
    XCTAssertEqual(vc.uCharVal, 250, @"TC（unsigned char）分支 —— 旧实现完全没有这个分支");
    XCTAssertTrue(vc.boolVal, @"TB（BOOL）分支");
    XCTAssertEqualWithAccuracy(vc.floatVal, 1.5f, 0.0001f, @"Tf（float）分支");
    XCTAssertEqualWithAccuracy(vc.doubleVal, 3.25, 0.0000001, @"Td（double）分支");
}

/// 【回归】旧实现静默跳过的三个类型。
/// 单独成条，是为了让「为什么单独测这三个」在测试报告里一眼可见。
- (void)testShortUnsignedShortUnsignedChar_RegressionForSilentSkip {
    TestAllTypesViewController *vc = [self openWithQuery:@"?shortVal=-1234&uShortVal=65000&uCharVal=255"];
    XCTAssertEqual(vc.shortVal, (short)-1234, @"short 必须可映射（旧实现无 Ts 分支 ⇒ 恒为 0）");
    XCTAssertEqual(vc.uShortVal, (unsigned short)65000, @"unsigned short 必须可映射（旧实现恒为 0）");
    XCTAssertEqual(vc.uCharVal, (unsigned char)255, @"unsigned char 必须可映射（旧实现恒为 0）");
}

/// 【安全回归 · 防类型混淆】block 属性必须被完全跳过。
///
/// 旧实现下 `callback=malicious` 会把 @"malicious" 直接写进 block 的存储位。
/// 本用例除了断言 `nil`，还显式检查该位未被污染 ——
/// 若被污染，真实调用就是拿字符串当函数指针执行，进程必崩。
- (void)testBlockPropertyIsNeverTypeConfused {
    TestAllTypesViewController *vc = [self openWithQuery:@"?callback=malicious&objVal=ok&intVal=5"];

    XCTAssertNil(vc.callback, @"T@?（block）属性绝不能被字符串污染，必须保持 nil");
    XCTAssertEqualObjects(vc.objVal, @"ok", @"同一批参数里的对象属性仍应正常映射");
    XCTAssertEqual(vc.intVal, 5, @"同一批参数里的标量属性仍应正常映射");

    if (vc.callback) {
        XCTFail(@"callback 被污染了 —— 真实调用会直接崩溃");
    }
}

/// 结构体属性（编码 `T{CGRect=...}`）既不是对象也不是数字，必须安全跳过。
- (void)testStructPropertyIsSafelySkipped {
    TestAllTypesViewController *vc = [self openWithQuery:@"?rectVal=1,2,3,4&intVal=8"];
    XCTAssertTrue(CGRectEqualToRect(vc.rectVal, CGRectZero),
                  @"结构体属性应保持原值（不参与 URL 参数映射），且不得崩溃");
    XCTAssertEqual(vc.intVal, 8, @"同批其余参数不受影响");
}

#pragma mark - 数值来源与精度

/// 字符串 → 标量：URL 参数的真实形态，必须是稳定的。
- (void)testNumericStringCoercionIsStable {
    TestAllTypesViewController *vc = [self openWithQuery:@"?integerVal=42&doubleVal=2.718&boolVal=0&shortVal=100"];
    XCTAssertEqual(vc.integerVal, 42, @"数字字符串应被转换成整数");
    XCTAssertEqualWithAccuracy(vc.doubleVal, 2.718, 0.0000001, @"数字字符串应被转换成浮点");
    XCTAssertFalse(vc.boolVal, @"\"0\" 应映射为 NO");
    XCTAssertEqual(vc.shortVal, 100, @"数字字符串应能落到 short");
}

/// 传原生 NSNumber 对象（非字符串），验证类型直通。
- (void)testNativeNumberObjectIsMapped {
    TestAllTypesViewController *vc = [self openWithNativeParams:
        @{@"integerVal": @123, @"doubleVal": @0.5, @"boolVal": @YES, @"shortVal": @77}];
    XCTAssertEqual(vc.integerVal, 123, @"NSNumber 直通 Tq");
    XCTAssertEqualWithAccuracy(vc.doubleVal, 0.5, 0.0000001, @"NSNumber 直通 Td");
    XCTAssertTrue(vc.boolVal, @"NSNumber 直通 TB");
    XCTAssertEqual(vc.shortVal, 77, @"NSNumber 直通 Ts");
}

/// 【精度】大整数不得被 double 中转截断。
///
/// 真实场景：订单号 / 雪花 ID / 纳秒时间戳都超过 2^53。
/// 若实现走 `(long long)[obj doubleValue]`，`9007199254740993` 会变成 `...992`。
- (void)testLargeIntegerKeepsPrecisionBeyondDoubleMantissa {
    long long big = 9007199254740993LL; // 2^53 + 1：double 无法精确表示

    TestAllTypesViewController *vc = [self openWithNativeParams:
        @{@"longLongVal": @(big), @"integerVal": @(big)}];
    XCTAssertEqual(vc.longLongVal, big, @"NSNumber 来源：long long 不得因 double 中转丢精度");
    XCTAssertEqual(vc.integerVal, big, @"NSNumber 来源：NSInteger 不得因 double 中转丢精度");

    // 字符串来源同样要精确：NSString 实现了 longLongValue，不该绕 double
    TestAllTypesViewController *vc2 = [self openWithQuery:
        [NSString stringWithFormat:@"?longLongVal=%lld", big]];
    XCTAssertEqual(vc2.longLongVal, big, @"字符串来源：long long 也不得丢精度");
}

/// unsigned long long 全量程：验证 TQ 分支走的是 unsignedLongLongValue 而非 double。
- (void)testUnsignedLongLongFullRange {
    unsigned long long huge = 18446744073709551615ULL; // ULLONG_MAX
    TestAllTypesViewController *vc = [self openWithNativeParams:@{@"uLongLongVal": @(huge)}];
    XCTAssertEqual(vc.uLongLongVal, huge, @"TQ 分支应走 unsignedLongLongValue，可承载 ULLONG_MAX");
}

/// 负数与零：符号必须保留。
- (void)testNegativeAndZeroValues {
    TestAllTypesViewController *vc = [self openWithQuery:@"?integerVal=-1&intVal=-2000000000&doubleVal=-0.5&boolVal=0"];
    XCTAssertEqual(vc.integerVal, -1L, @"负整数应保留符号");
    XCTAssertEqual(vc.intVal, -2000000000, @"大负整数应可表达");
    XCTAssertEqualWithAccuracy(vc.doubleVal, -0.5, 0.0000001, @"负浮点应保留符号");
    XCTAssertFalse(vc.boolVal, @"0 应为 NO");
}

/// 超出目标类型范围时的行为：按 C 强制转换截断（与直接赋值一致），不得崩溃。
- (void)testOutOfRangeValueTruncatesLikeCIntegerCast {
    TestAllTypesViewController *vc = [self openWithQuery:@"?shortVal=70000&uCharVal=300"];
    XCTAssertEqual(vc.shortVal, (short)70000, @"超范围值应按 C 截断语义处理，且不崩溃");
    XCTAssertEqual(vc.uCharVal, (unsigned char)300, @"超范围值应按 C 截断语义处理，且不崩溃");
}

/// float 与 double 必须各自走自己的分支，不能串。
- (void)testFloatAndDoubleAreIndependent {
    TestAllTypesViewController *vc = [self openWithQuery:@"?floatVal=0.1&doubleVal=0.1"];
    XCTAssertEqualWithAccuracy(vc.floatVal, 0.1f, 0.0000001f, @"Tf 应落 float");
    XCTAssertEqualWithAccuracy(vc.doubleVal, 0.1, 0.0000000001, @"Td 应落 double（精度高于 float）");
}

#pragma mark - 畸形输入

/// NSNull：HTTP / JSON 反序列化后很常见，必须安全跳过而不是崩。
- (void)testNSNullValueDoesNotCrashAndIsSkipped {
    TestAllTypesViewController *vc = [self openWithNativeParams:
        @{@"integerVal": [NSNull null], @"objVal": [NSNull null], @"intVal": @9}];
    XCTAssertEqual(vc.intVal, 9, @"NSNull 应被安全跳过，同批其余参数照常映射");
    XCTAssertEqual(vc.integerVal, 0, @"NSNull 不应改变标量属性（保持默认 0）");
}

/// 非数字字符串塞给数字属性：不崩，落 0（与 `[NSString doubleValue]` 语义一致）。
- (void)testNonNumericStringForNumericPropertyDoesNotCrash {
    TestAllTypesViewController *vc = [self openWithQuery:@"?integerVal=abc&shortVal=xyz"];
    XCTAssertEqual(vc.integerVal, 0, @"非数字字符串应落 0 而非崩溃");
    XCTAssertEqual(vc.shortVal, 0, @"非数字字符串应落 0 而非崩溃");
}

/// 未知 key 与继承属性：未知 key 跳过（但仍在 ml_routerParams 留底），继承属性可映射。
- (void)testUnknownKeySkippedAndInheritedPropertyMapped {
    TestAllTypesViewController *vc = [self openWithQuery:@"?noSuchProperty=1&title=InheritedTitle"];
    XCTAssertEqualObjects(vc.title, @"InheritedTitle", @"继承自 UIViewController 的对象属性应可映射");
    XCTAssertEqualObjects([TestCapture lastParams][@"noSuchProperty"], @"1",
                          @"未知 key 仍应留底在 ml_routerParams（供排查）");
}

@end
