#!/bin/bash
# 把已构建的 Chassis.app 打成 dmg。
#
# dmg 里除应用本体外还放一个指向 /Applications 的快捷方式：
# 用户打开 dmg 后直接把 Chassis.app 拖到 Applications 图标上即可安装，
# 不需要自己再开一次 Finder 窗口找 Applications。
#
# 用法：./Scripts/package.sh <Chassis.app> <输出.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-.build/xcode/Build/Products/Release/Chassis.app}"
DMG="${2:-}"

if [ ! -d "$APP" ]; then
  echo "构建产物未找到：$APP" >&2
  exit 1
fi
if [ -z "$DMG" ]; then
  echo "用法：$0 <Chassis.app> <输出.dmg>" >&2
  exit 2
fi

# 用临时目录做 dmg 根目录，避免把 .app 同级目录里的其他东西带进镜像。
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/chassis-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

/usr/bin/ditto "$APP" "$STAGE/$(basename "$APP")"
# 快捷方式指向系统 Applications，拖动即完成安装。
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create -volname "Chassis" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "DMG: $DMG"
