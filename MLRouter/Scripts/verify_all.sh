#!/bin/bash
# verify_all.sh —— MLRouter 平台演进年度回归 / 全量验证 runbook
#
# 用途：iOS 新版本 GM、Xcode 大版本升级、dyld 机制变化排查时，一条命令跑完全部验证。
# 也可用于发布前的例行全量检查。
#
# 用法：
#   ./verify_all.sh [模拟器名称]        # 默认 'platform=iOS Simulator,name=iPhone 8'
#
# 覆盖的验证层（对应《测试体系分层》讨论）：
#   1. pod lib lint                    —— 构建健康（podspec 可编译、头文件可导入）
#   2. xcodebuild test (Debug)         —— 184 条单元/集成精确断言
#   3. xcodebuild test (Release)       —— strip/混淆下段注册与符号可用性冒烟
#   4. 模拟器 -RTKitRunAll             —— 68 个真实运行时场景（216 断言，结果文件自动判定）
#   5. 模拟器 -RTKitSelfCheck          —— 核心不变量快速冒烟（17 条，结果文件自动判定）
#
# 退出码：五层全部进退出码。模拟器两层由 App 把 RTENV.summary 落盘到沙盒 tmp
# （rtkit_last_runall.txt / rtkit_last_selfcheck.txt），脚本用 simctl get_app_container
# 读取并 grep「0 失败」；文件不存在（run 未跑完/App 死亡）同样判失败。

set -uo pipefail

DEST="${1:-platform=iOS Simulator,name=iPhone 8}"
WS="/Users/chentongxue/Desktop/cfh/study/RouterDemo/RouterDemo.xcworkspace"
APP_ID="com.cfh.router.demo.test.RouterDemo"
SHOT_DIR="/tmp/verify_all_$(date +%H%M%S)"
mkdir -p "$SHOT_DIR"
FAILED=0

step() { echo -e "\n========== [$(date +%H:%M:%S)] $1 ========== "; }

step "1/5 pod lib lint（构建健康）"
if (cd "$(dirname "$WS")/MLRouter" && pod lib lint MLRouter.podspec --allow-warnings | tail -2); then
  echo "✅ lint 通过"
else
  echo "❌ lint 失败"; FAILED=1
fi

step "2/5 单元/集成测试（Debug）"
if xcodebuild -workspace "$WS" -scheme MLRouterIntegrationTests-Unit-Tests \
     -destination "$DEST" -configuration Debug test 2>&1 | grep -E "Executed .* tests|TEST (SUCCEEDED|FAILED)" | tail -2; then
  xcodebuild_output=$?
  echo "✅ Debug 测试完成"
else
  echo "❌ Debug 测试失败"; FAILED=1
fi

step "3/5 单元/集成测试（Release —— strip/混淆冒烟）"
if xcodebuild -workspace "$WS" -scheme MLRouterIntegrationTests-Unit-Tests \
     -destination "$DEST" -configuration Release test 2>&1 | grep -E "Executed .* tests|TEST (SUCCEEDED|FAILED)" | tail -2; then
  echo "✅ Release 测试完成"
else
  echo "❌ Release 测试失败"; FAILED=1
fi

step "4/5 构建安装宿主 App + 一键全量场景（-RTKitRunAll）"
xcodebuild -workspace "$WS" -scheme RouterDemo -destination "$DEST" -configuration Debug build 2>&1 | tail -1
APP="/Users/chentongxue/Library/Developer/Xcode/DerivedData"/RouterDemo-*/Build/Products/Debug-iphonesimulator/RouterDemo.app
APP=$(ls -d $APP 2>/dev/null | head -1)
if [ -z "$APP" ]; then echo "❌ 找不到 RouterDemo.app"; FAILED=1; else
  # CoreSimulator 偶发无诊断杀掉宿主 App（无崩溃报告、无 Jetsam 事件）——存活探测 + 自动重试一次
  for attempt in 1 2; do
    xcrun simctl terminate booted "$APP_ID" 2>/dev/null
    xcrun simctl install booted "$APP"
    xcrun simctl launch booted "$APP_ID" -RTKitRunAll
    echo "等待 runner 跑完（68 场景约 2 分钟）..."
    sleep 130
    ALIVE=$(xcrun simctl spawn booted launchctl list 2>/dev/null | grep -c "$APP_ID")
    xcrun simctl io booted screenshot "$SHOT_DIR/runall.png"
    if [ "$ALIVE" -ge 1 ]; then
      # 自动判定：读 App 沙盒 tmp 的结果文件，首行 summary grep「0 失败」
      CONTAINER=$(xcrun simctl get_app_container booted "$APP_ID" data 2>/dev/null)
      RESULT_FILE="$CONTAINER/tmp/rtkit_last_runall.txt"
      if [ -f "$RESULT_FILE" ] && head -1 "$RESULT_FILE" | grep -q "0 失败"; then
        echo "✅ runall 自动判定通过：$(head -1 "$RESULT_FILE")（截图：$SHOT_DIR/runall.png）"
        break
      fi
      if [ -f "$RESULT_FILE" ]; then
        echo "❌ runall 自动判定失败：$(head -1 "$RESULT_FILE")"
        grep "❌" "$RESULT_FILE" | head -10
        FAILED=1
        break
      fi
      echo "⚠️ App 存活但结果文件缺失（run 未完成或落盘失败），重试..."
    fi
    if [ "$attempt" -eq 1 ]; then
      echo "⚠️ 第 1 次 runall 期间 App 进程消失（无崩溃报告，模拟器层偶发行为），自动重试..."
    else
      echo "❌ 两次 runall 均未产出有效结果（App 消失/文件缺失），请人工排查"
      FAILED=1
    fi
  done
fi

step "5/5 聚合自检冒烟（-RTKitSelfCheck）"
xcrun simctl terminate booted "$APP_ID" 2>/dev/null
xcrun simctl launch booted "$APP_ID" -RTKitSelfCheck
sleep 35
xcrun simctl io booted screenshot "$SHOT_DIR/selfcheck.png"
CONTAINER=$(xcrun simctl get_app_container booted "$APP_ID" data 2>/dev/null)
SC_FILE="$CONTAINER/tmp/rtkit_last_selfcheck.txt"
if [ -f "$SC_FILE" ] && head -1 "$SC_FILE" | grep -q "0 失败"; then
  echo "✅ selfcheck 自动判定通过：$(head -1 "$SC_FILE")（截图：$SHOT_DIR/selfcheck.png）"
else
  echo "❌ selfcheck 自动判定失败"
  if [ -f "$SC_FILE" ]; then
    head -1 "$SC_FILE"
    grep "❌" "$SC_FILE" | head -10
  else
    echo "结果文件缺失（App 未跑完/死亡），截图：$SHOT_DIR/selfcheck.png"
  fi
  FAILED=1
fi

step "结果汇总"
if [ $FAILED -eq 0 ]; then
  echo "✅ 五层全部通过（lint / Debug / Release / runall / selfcheck），截图存于：$SHOT_DIR/"
else
  echo "❌ 存在失败层，先修再跑"; exit 1
fi
