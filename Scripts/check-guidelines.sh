#!/bin/bash
# 规范兜底检查（只拦得住疏忽，拦不住刻意）：
# 1. Plugins/* 不得依赖 PluginKit
# 2. 插件源码不得出现自建 Event Tap / 权限 prompt / 直接投递通知
# 3. manifest.minHostVersion 与基座 MARKETING_VERSION 比对
set -uo pipefail

cd "$(dirname "$0")/.."
FAILED=0

fail() { echo "FAIL: $*"; FAILED=1; }
ok() { echo "ok  : $*"; }

# 1. 插件不得依赖 PluginKit
if grep -q 'PluginKit' Package.swift; then
  if awk '/name: "Harness"/,/\),/' Package.swift | grep -q 'PluginKit'; then
    fail "Harness 依赖了 PluginKit"
  else
    ok "插件 target 未依赖 PluginKit"
  fi
else
  ok "Package.swift 中不存在 PluginKit（异常）"
fi

# 2. 禁止字面调用
FORBIDDEN='CGEvent\.tapCreate|RegisterEventHotKey|AXIsProcessTrustedWithOptions|CGRequestScreenCaptureAccess|UNUserNotificationCenter'
if grep -RInE "$FORBIDDEN" Packages/Plugins --include='*.swift' >/dev/null 2>&1; then
  fail "插件源码出现禁止的全局资源调用："
  grep -RInE "$FORBIDDEN" Packages/Plugins --include='*.swift' || true
else
  ok "插件未自建 Event Tap / 快捷键 / 权限弹框 / 通知投递"
fi

# 3. minHostVersion 与 MARKETING_VERSION 比对
HOST_VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*MARKETING_VERSION: *//' | tr -d '"')
for file in $(grep -Rl 'minHostVersion' Packages/Plugins --include='*.swift'); do
  PLUGIN_VERSION=$(grep -o 'minHostVersion: "[0-9.]*"' "$file" | head -1 | sed 's/minHostVersion: "//; s/"//')
  if [ -z "$PLUGIN_VERSION" ]; then
    fail "$file 未声明 minHostVersion"
  elif [ "$PLUGIN_VERSION" != "$HOST_VERSION" ]; then
    fail "$file 的 minHostVersion=$PLUGIN_VERSION 与基座 $HOST_VERSION 不一致"
  else
    ok "$(basename "$file") minHostVersion=$PLUGIN_VERSION"
  fi
done

# 4. 插件必须实现 makeSettingsView
for file in $(grep -Rl 'FeaturePlugin' Packages/Plugins --include='*.swift'); do
  if grep -q 'func makeSettingsView' "$file"; then
    ok "$(basename "$file") 实现了 makeSettingsView"
  else
    fail "$file 缺少 makeSettingsView"
  fi
done

exit $FAILED
