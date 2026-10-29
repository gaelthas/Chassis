#!/bin/bash
# 构建并安装到 /Applications，然后启动。
# 固定安装位置 + 稳定签名 = TCC 授权不会因为重新构建而失效。
#
# 用法：./Scripts/install.sh [Debug|Release]
set -euo pipefail

cd "$(dirname "$0")/.."

# 配置名归一化：接受 debug/DEBUG/Release 等写法，未知值直接报错而不是生成一个不存在的路径。
case "$(printf '%s' "${1:-Debug}" | tr '[:upper:]' '[:lower:]')" in
  debug)   CONFIGURATION="Debug" ;;
  release) CONFIGURATION="Release" ;;
  *)
    echo "未知构建配置：${1}" >&2
    echo "用法：$0 [Debug|Release]" >&2
    exit 2
    ;;
esac

DEST="/Applications/Chassis.app"
SOURCE=".build/xcode/Build/Products/${CONFIGURATION}/Chassis.app"

if [ ! -d "${SOURCE}" ]; then
  ./Scripts/build.sh "${CONFIGURATION}"
fi

if [ ! -d "${SOURCE}" ]; then
  echo "构建产物未找到：${SOURCE}" >&2
  exit 1
fi

# 退出正在运行的旧实例，避免替换时文件占用
pkill -f 'Chassis.app/Contents/MacOS/Chassis' 2>/dev/null || true
sleep 1

rm -rf "${DEST}"
ditto "${SOURCE}" "${DEST}"
open "${DEST}"
# 相邻的非 ASCII 字符必须用 ${VAR} 界定变量名，否则在 set -u 下会被当成变量名的一部分。
echo "已安装并启动 ${DEST}（${CONFIGURATION}）"
codesign -d -r- "${DEST}" 2>&1 | sed -n 's/^designated => /签名要求：/p'
