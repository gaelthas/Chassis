#!/bin/bash
# 构建后启动应用，便于菜单栏实测。
set -euo pipefail

cd "$(dirname "$0")/.."

APP=".build/xcode/Build/Products/Debug/Chassis.app"
if [ ! -d "$APP" ]; then
  ./Scripts/build.sh Debug
fi

open "$APP"
echo "已启动 $APP（菜单栏图标应出现）"
