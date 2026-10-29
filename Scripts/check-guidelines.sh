#!/bin/bash
# 规范兜底检查（只拦得住疏忽，拦不住刻意）：
# 1. 插件不得依赖 PluginKit
# 2. 插件源码不得出现自建 Event Tap / 权限 prompt / 直接投递通知
# 3. manifest.minHostVersion 与基座 MARKETING_VERSION 比对
#
# 插件源码在独立仓库 Chassis-Plugins（本仓库已忽略该目录）。
set -uo pipefail

cd "$(dirname "$0")/.."
PLUGINS_DIR="Chassis-Plugins"
FAILED=0

fail() { echo "FAIL: $*"; FAILED=1; }
ok() { echo "ok  : $*"; }

if [ ! -d "$PLUGINS_DIR" ]; then
  echo "跳过：未找到插件仓库 $PLUGINS_DIR/（git clone <插件仓库> $PLUGINS_DIR）" >&2
  exit 0
fi

# 1. 插件包不得依赖 PluginKit
PLUGIN_MANIFEST="$PLUGINS_DIR/Package.swift"
if [ -f "$PLUGIN_MANIFEST" ] && grep -q 'PluginKit' "$PLUGIN_MANIFEST"; then
  fail "插件仓库 Package.swift 依赖了 PluginKit"
  grep -n 'PluginKit' "$PLUGIN_MANIFEST" || true
else
  ok "插件包未依赖 PluginKit"
fi

# 2. 禁止字面调用
FORBIDDEN='CGEvent\.tapCreate|RegisterEventHotKey|AXIsProcessTrustedWithOptions|CGRequestScreenCaptureAccess|UNUserNotificationCenter'
if grep -RInE "$FORBIDDEN" "$PLUGINS_DIR" --include='*.swift' >/dev/null 2>&1; then
  fail "插件源码出现禁止的全局资源调用："
  grep -RInE "$FORBIDDEN" "$PLUGINS_DIR" --include='*.swift' || true
else
  ok "插件未自建 Event Tap / 快捷键 / 权限弹框 / 通知投递"
fi

# 3. minHostVersion 与 MARKETING_VERSION 比对
HOST_VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*MARKETING_VERSION: *//' | tr -d '"')
for file in $(grep -Rl 'minHostVersion' "$PLUGINS_DIR" --include='*.swift'); do
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
for file in $(grep -Rl 'FeaturePlugin' "$PLUGINS_DIR" --include='*.swift'); do
  if grep -q 'func makeSettingsView' "$file"; then
    ok "$(basename "$file") 实现了 makeSettingsView"
  else
    fail "$file 缺少 makeSettingsView"
  fi
done

# 5. 每个插件目录都必须被插件仓库的 Package.swift 声明（否则不会被链接）
for dir in "$PLUGINS_DIR"/Packages/*/; do
  name=$(basename "${dir%/}")
  if grep -q "path: \"Packages/${name}\"" "$PLUGIN_MANIFEST"; then
    ok "插件 $name 已在插件包中声明"
  else
    fail "插件目录 $name 未在 $PLUGIN_MANIFEST 中声明"
  fi
done

exit $FAILED
