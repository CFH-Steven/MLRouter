#!/usr/bin/env bash
#
# mlrouter_validate.sh — MLRouter 路由表静态校验
# 用途：CI 冲突检测 / 死链风格检查（重复路由、旧式文件名推导宏告警、服务/模块统计）
# 依赖：仅使用 find / grep / sed / awk，无需 ripgrep，任意 macOS/Linux CI 可用。
#
# 用法：./mlrouter_validate.sh [源码目录]   （默认：当前目录）
#
set -uo pipefail

ROOT="${1:-.}"
FAIL=0

echo "🔍 MLRouter 路由静态校验: $ROOT"

# 提取某宏的 URL 参数（兼容 MACRO("url") 与 MACRO(Class, "url") 两种写法）
collect_quoted() {
  find "$ROOT" -type f \( -name '*.m' -o -name '*.mm' \) -print0 2>/dev/null \
    | xargs -0 grep -oEh "$1\([A-Za-z0-9_]+,[[:space:]]*)?\"[^\"]*\"" 2>/dev/null \
    | sed -E 's/.*"([^"]*)".*/\1/' | sort || true
}

# 1. 检测重复路由（编译期重复段会导致后者静默覆盖前者）
for MACRO in MLRouterPage MLRouterPageClass MLRouterMethod MLRouterMethodClass MLRouterView MLRouterViewClass MLRouterRedirect; do
  paths=$(collect_quoted "$MACRO")
  dups=$(printf '%s\n' "$paths" | grep -v '^$' | uniq -d || true)
  if [ -n "$dups" ]; then
    echo "❌ [$MACRO] 发现重复注册:"
    printf '%s\n' "$dups" | sed 's/^/   - /'
    FAIL=1
  fi
done

# 2. 旧式“文件名推导”宏使用告警（建议迁移到 *Class 版本）
for OLD in MLRouterPage MLRouterMethod MLRouterView MLRouterInterceptor; do
  hits=$(find "$ROOT" -type f \( -name '*.m' -o -name '*.mm' \) -print0 2>/dev/null \
    | xargs -0 grep -cE "$OLD\(" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}' || true)
  if [ "${hits:-0}" -gt 0 ]; then
    echo "⚠️  检测到旧式宏 $OLD( （依赖“文件名==类名”，建议迁移到 ${OLD}Class( 显式宏）"
  fi
done

# 3. 服务 / 模块注册统计
svc=$(find "$ROOT" -type f \( -name '*.m' -o -name '*.mm' \) -print0 2>/dev/null \
  | xargs -0 grep -cE 'MLRouterService\(' 2>/dev/null | awk -F: '{s+=$2} END{print s+0}' || true)
mod=$(find "$ROOT" -type f \( -name '*.m' -o -name '*.mm' \) -print0 2>/dev/null \
  | xargs -0 grep -cE 'MLRouterModule\(' 2>/dev/null | awk -F: '{s+=$2} END{print s+0}' || true)
echo "📊 服务注册: ${svc:-0} · 模块注册: ${mod:-0}"

if [ "$FAIL" -ne 0 ]; then
  echo "✅ 校验失败，请修复重复路由后重试"
  exit 1
fi
echo "✅ 校验通过"
