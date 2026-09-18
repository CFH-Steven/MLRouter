// RTTestEnv.h
// 场景断言收集器：每个测试页面把「预期 vs 实际」写进来，Dashboard 统一渲染人读报告。
// 这是给「真实 UI 场景」用的，不是 XCTest —— 目的是让工程里任何人打开 App 点一遍，
// 就能看到框架每一项能力当下是否真的可用。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RTTestEnv : NSObject

+ (instancetype)shared;

/// 开启一个新的断言分组（会写一行分组标题）
- (void)beginSuite:(NSString *)suiteName;
/// 记录一条断言结果
- (void)check:(BOOL)condition name:(NSString *)name detail:(NSString * _Nullable)detail;
/// 记录一条纯信息（不参与通过率统计）
- (void)info:(NSString *)message;
/// 清空全部记录
- (void)reset;

@property (nonatomic, readonly) NSInteger passCount;
@property (nonatomic, readonly) NSInteger failCount;
/// 人读报告文本（Dashboard 直接展示）
@property (nonatomic, readonly, copy) NSString *report;
/// 一行摘要，如 "✅ 18 通过 · ❌ 2 失败"
@property (nonatomic, readonly, copy) NSString *summary;
/// 当前已累积的行数（用于「只取本次场景新增的记录」）
@property (nonatomic, readonly) NSInteger totalLineCount;
/// 取 [startIndex, 末尾) 区间的报告文本
- (NSString *)reportFromLine:(NSInteger)startIndex;

@end

NS_ASSUME_NONNULL_END
