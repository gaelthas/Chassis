#!/bin/bash
# 生成 Xcode 工程：检查 xcodegen 与插件仓库、补齐图标、生成 .xcodeproj。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "未找到 xcodegen，正在通过 Homebrew 安装…"
  brew install xcodegen
fi

# 插件源码在独立仓库；根包会引用 Chassis-Plugins/Packages/Harness。
if [ ! -d "Chassis-Plugins/Packages" ]; then
  echo "⚠️  未找到插件仓库 Chassis-Plugins/。" >&2
  echo "    工程仍可生成，但构建会失败。请先在当前目录执行：" >&2
  echo "    git clone <插件仓库地址> Chassis-Plugins" >&2
fi

if [ ! -f "HostApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" ]; then
  echo "生成占位图标…"
  swift Scripts/GenerateIcons/main.swift
fi

xcodegen generate
echo "已生成 Chassis.xcodeproj"
