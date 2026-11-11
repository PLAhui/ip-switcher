#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> 生成默认 IP 预设（若 profiles.json 已存在则跳过）"
if [ ! -f "$ROOT/profiles.json" ]; then
  swift build --disable-sandbox -c debug >/dev/null
  .build/debug/ipswctl init-config "$ROOT/profiles.json"
fi

echo "==> Release 编译"
swift build --disable-sandbox -c release

APP="$ROOT/IPSwitcher.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f .build/release/IPSwitcher "$APP/Contents/MacOS/IPSwitcher"
cp -f .build/release/ipswctl "$APP/Contents/MacOS/ipswctl"
cp -f Resources/Info.plist "$APP/Contents/Info.plist"
cp -f profiles.json "$APP/Contents/Resources/profiles.json"
mkdir -p "$APP/Contents/Resources/web"
cp -f Resources/web/index.html "$APP/Contents/Resources/web/index.html"

echo "==> Ad-hoc 签名"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "警告：签名失败，仍可直接运行"

echo "==> 完成"
echo "    应用：$APP"
echo "    命令行工具：$ROOT/.build/release/ipswctl"
echo "    启动：open \"$APP\""
