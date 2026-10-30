#!/bin/bash
# 一键发布：构建 Release → 打包 dmg/zip → 打 tag → 推送 → 创建 GitHub Release。
#
# 用法：
#   ./Scripts/release.sh            # 用 project.yml 里当前的 MARKETING_VERSION
#   ./Scripts/release.sh 1.0.2      # 先升版本，再发布
#
# 依赖：gh（brew install gh）且已登录（gh auth login）；本地有 Apple Development 证书，
# 否则产物是 ad-hoc 签名，用户每次重装都要重新授权 TCC。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*MARKETING_VERSION: *//' | tr -d '"')}"
TAG="v$VERSION"

# gh 只用于「本地上传产物」；没装也能发布——推 tag 交给 GitHub Actions。
HAS_GH=0
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  HAS_GH=1
elif command -v gh >/dev/null; then
  echo "⚠️  gh 未登录（gh auth login）；将只推 tag，由 GitHub Actions 发布"
else
  echo "⚠️  未安装 gh；将只推 tag，由 GitHub Actions 发布（brew install gh 可本地上传）"
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "tag $TAG 已存在；请先删除或换版本号（git tag -d $TAG）" >&2
  exit 1
fi

if [ -n "${1:-}" ]; then
  echo "== 升版本到 $VERSION =="
  python3 - "$VERSION" <<'PY'
import re, sys
version = sys.argv[1]
build = version.split(".")[-1]
path = "project.yml"
text = open(path).read()
text = re.sub(r"MARKETING_VERSION: [0-9.]+", f"MARKETING_VERSION: {version}", text, count=1)
text = re.sub(r"CURRENT_PROJECT_VERSION: [0-9]+", f"CURRENT_PROJECT_VERSION: {build}", text, count=1)
open(path, "w").write(text)
PY
  xcodegen generate >/dev/null
fi

echo "== 构建 Release =="
./Scripts/build.sh Release

APP=".build/xcode/Build/Products/Release/Chassis.app"
DMG="dist/Chassis-$VERSION.dmg"
ZIP="dist/Chassis-$VERSION.zip"
mkdir -p dist
rm -f "$DMG" "$ZIP"

echo "== 打包 =="
hdiutil create -volname "Chassis" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

if ! git diff --quiet -- project.yml; then
  git add project.yml
  git commit -q -m "release: v$VERSION"
fi

git push origin HEAD

git tag -a "$TAG" -m "Chassis $VERSION"
git push origin "$TAG"

if [ "$HAS_GH" = "1" ]; then
  echo "== 创建 GitHub Release（本地产物）=="
  gh release create "$TAG" "$DMG" "$ZIP" \
    --title "Chassis $VERSION" \
    --generate-notes
  echo
  echo "完成：$(gh release view "$TAG" --json url --jq .url)"
else
  echo
  echo "已推送 tag $TAG。GitHub Actions 会自动构建并创建 Release："
  echo "  https://github.com/gaelthas/Chassis/actions"
fi
