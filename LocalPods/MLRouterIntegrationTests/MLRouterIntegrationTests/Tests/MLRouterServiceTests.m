// MLRouterServiceTests.m
// 服务层（协议驱动服务发现）测试。全部使用运行时 registerService: 注册，便于隔离与 reset 验证。
#import <XCTest/XCTest.h>
#import "MLRouterTestSupport.h"

@protocol CartSvcP <NSObject>
- (NSInteger)itemCount;
@end

@interface CartSvcImpl : NSObject <CartSvcP>
@end
@implementation CartSvcImpl
- (NSInteger)itemCount { return 5; }
@end

@protocol BadProtoP <NSObject>
- (void)foo;
@end

@interface NotConformingImpl : NSObject
@end
@implementation NotConformingImpl
- (void)foo {}
@end

// 专门用于「未注册协议」断言的协议：从不注册、也从不用 _registerServiceProtocolName: 模拟回填。
// 不能复用 CartSvcP —— 同一次运行里 testSegmentScanFillsServiceMap 会把它写进编译期段表，
// 而段表是「静态事实」不会被 reset 清除，导致后面的「未注册」断言假失败。
@protocol NeverRegisteredP <NSObject>
- (void)neverCalled;
@end

@interface MLRouterServiceTests : XCTestCase
@end

@implementation MLRouterServiceTests

- (void)setUp {
    [super setUp];
    [TestCapture reset];
    [MLRouter resetRouter];
    [MLRouterService reset]; // 只清运行时注册与 tombstone；编译期段注册的服务不受影响
}

- (void)testServiceForProtocolReturnsTypedImpl {
    [MLRouterService registerService:@protocol(CartSvcP) implClass:[CartSvcImpl class]];
    id svc = [MLRouterService serviceForProtocol:@protocol(CartSvcP)];
    XCTAssertNotNil(svc, @"应返回服务实现");
    XCTAssertTrue([svc conformsToProtocol:@protocol(CartSvcP)], @"应强类型遵循协议");
    XCTAssertEqual([svc itemCount], 5, @"应正确响应协议方法");
}

- (void)testHasServiceForProtocol {
    XCTAssertFalse([MLRouterService hasServiceForProtocol:@protocol(CartSvcP)]);
    [MLRouterService registerService:@protocol(CartSvcP) implClass:[CartSvcImpl class]];
    XCTAssertTrue([MLRouterService hasServiceForProtocol:@protocol(CartSvcP)]);
}

- (void)testUnregisteredProtocolReturnsNil {
    id svc = [MLRouterService serviceForProtocol:@protocol(NeverRegisteredP)];
    XCTAssertNil(svc, @"未注册协议应返回 nil");
}

- (void)testServiceRespondsToProtocolMethod {
    [MLRouterService registerService:@protocol(CartSvcP) implClass:[CartSvcImpl class]];
    id<CartSvcP> svc = [MLRouterService serviceForProtocol:@protocol(CartSvcP)];
    XCTAssertEqual([svc itemCount], 5);
}

- (void)testRegisterAndUnregister {
    [MLRouterService registerService:@protocol(CartSvcP) implClass:[CartSvcImpl class]];
    XCTAssertTrue([MLRouterService hasServiceForProtocol:@protocol(CartSvcP)]);
    [MLRouterService unregisterService:@protocol(CartSvcP)];
    XCTAssertFalse([MLRouterService hasServiceForProtocol:@protocol(CartSvcP)]);
    XCTAssertNil([MLRouterService serviceForProtocol:@protocol(CartSvcP)]);
}

- (void)testExportedServiceProtocolsContainsRegistered {
    [MLRouterService registerService:@protocol(CartSvcP) implClass:[CartSvcImpl class]];
    NSArray *exported = [MLRouterService exportedServiceProtocols];
    XCTAssertTrue([exported containsObject:NSStringFromProtocol(@protocol(CartSvcP))]);
}

- (void)testResetClearsRuntimeServices {
    [MLRouterService registerService:@protocol(CartSvcP) implClass:[CartSvcImpl class]];
    [MLRouterService reset];
    XCTAssertFalse([MLRouterService hasServiceForProtocol:@protocol(CartSvcP)], @"reset 后运行时注册应被清空");
}

- (void)testServiceNotConformingRejected {
    // 实现类未遵循协议，registerService 应拒绝（不写入）
    [MLRouterService registerService:@protocol(BadProtoP) implClass:[NotConformingImpl class]];
    XCTAssertFalse([MLRouterService hasServiceForProtocol:@protocol(BadProtoP)], @"未遵循协议的实现应被拒绝注册");
}

- (void)testSegmentScanFillsServiceMap {
    // 模拟编译期段扫描的回调，验证协议名->实现名回填后 serviceForProtocol 可解析。
    // ⚠️ _registerServiceProtocolName: 写入的是「编译期段表」，而段表刻意不会被 reset 清除
    // （段扫描幂等，清掉就再也回填不回来）—— 因此本用例结束后必须 unregister 打 tombstone
    // 还原，否则会污染同一次运行里后续的「未注册协议」断言。
    [MLRouterService _registerServiceProtocolName:@"CartSvcP" implClassName:@"CartSvcImpl"];
    XCTAssertTrue([MLRouterService hasServiceForProtocol:@protocol(CartSvcP)]);
    id svc = [MLRouterService serviceForProtocol:@protocol(CartSvcP)];
    XCTAssertNotNil(svc);
    [MLRouterService unregisterService:@protocol(CartSvcP)]; // 收尾：屏蔽段表条目
    XCTAssertNil([MLRouterService serviceForProtocol:@protocol(CartSvcP)], @"unregister 应屏蔽段表条目");
}

@end
