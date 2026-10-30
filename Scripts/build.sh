#!/bin/bash
# 构建应用，输出 .app 路径。
#
# 用法：
#   ./Scripts/build.sh            # Debug
#   ./Scripts/build.sh Release    # Release
#
# 签名：与父项目 Dock2Min 完全一致（project.yml 里已声明）
#   CODE_SIGN_STYLE = Automatic
#   DEVELOPMENT_TEAM = 4U5PHGQCK2
#   CODE_SIGN_IDENTITY[sdk=macosx*] = "Apple Development"
#
# 为什么必须是证书签名：TCC（辅助功能/输入监控/屏幕录制）按「代码签名要求」识别应用。
# ad-hoc 签名的要求是 cdhash，每次构建都变 → 系统当成新应用 → 每次编译都要重新授权。
# 开发证书签名的要求是 identifier + 证书 → 重新构建后授权继续有效。
set -euo pipefail

cd "$(dirname "$0")/.."

# 配置名归一化：接受 debug/DEBUG/Release 等写法。
case "$(printf '%s' "${1:-Debug}" | tr '[:upper:]' '[:lower:]')" in
  debug)   CONFIGURATION="Debug" ;;
  release) CONFIGURATION="Release" ;;
  *)
    echo "未知构建配置：${1}" >&2
    echo "用法：$0 [Debug|Release]" >&2
    exit 2
    ;;
esac

DERIVED=".build/xcode"

if [ ! -d "Chassis.xcodeproj" ]; then
  ./Scripts/bootstrap.sh
fi

# 正常情况下不传任何签名覆盖参数，让工程设置生效；
# 只有在显式指定 CHASSIS_CODE_SIGN_IDENTITY 时才覆盖（例如临时换证书）。
# CI 没有本地开发证书时用 CHASSIS_NO_SIGN=1：允许无签名构建（产物需要用户手动放行）。
SIGN_ARGS=()
if [ "${CHASSIS_NO_SIGN:-0}" = "1" ]; then
  SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="-")
else
  # CI：证书被导入临时钥匙串后，必须显式告诉 codesign 去哪个钥匙串找身份，
  # 否则会出现 "No signing certificate" 或静默产出未签名包。
  if [ -n "${CHASSIS_KEYCHAIN:-}" ]; then
    SIGN_ARGS+=("OTHER_CODE_SIGN_FLAGS=--keychain $CHASSIS_KEYCHAIN")
  fi
  if [ -n "${CHASSIS_SIGN_STYLE:-}" ]; then
    SIGN_ARGS+=("CODE_SIGN_STYLE=$CHASSIS_SIGN_STYLE")
  fi
fi

xcodebuild \
  -project Chassis.xcodeproj \
  -scheme Chassis \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" \
  ${CHASSIS_CODE_SIGN_IDENTITY:+CODE_SIGN_IDENTITY="$CHASSIS_CODE_SIGN_IDENTITY"} \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  build

APP="$DERIVED/Build/Products/$CONFIGURATION/Chassis.app"
if [ ! -d "$APP" ]; then
  echo "构建产物未找到：$APP" >&2
  exit 1
fi

echo "APP: $APP"

if [ "${CHASSIS_NO_SIGN:-0}" = "1" ]; then
  echo "签名：无（CHASSIS_NO_SIGN=1，CI 构建）"
  exit 0
fi

echo "签名：$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "Team：$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
DR=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
echo "DR  ：$DR"

# 回归保护：ad-hoc 签名（DR 为 cdhash）会让每次构建都使 TCC 授权失效。
if printf '%s' "$DR" | grep -q 'cdhash'; then
  echo "⚠️  当前为 ad-hoc 签名：每次重新构建后系统都会要求重新授权。" >&2
  echo "    检查工程设置 CODE_SIGN_IDENTITY[sdk=macosx*] 是否为 Apple Development。" >&2
fi
