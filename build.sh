#!/bin/bash
set -euo pipefail

# ip-switcher 构建脚本
#
# 用法：
#   ./build.sh                    本机架构 Release 构建 + ad-hoc 签名
#   UNIVERSAL=1 ./build.sh        同时包含 arm64 与 x86_64（便于分发）
#   VERSION=1.2.0 ./build.sh      指定应用版本号
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
#                                 用开发者证书签名（用于公证 / 正式分发）
#
# 产物：
#   IPSwitcher.app               主应用
#   .build/*/ipswctl             命令行工具

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP="$ROOT/IPSwitcher.app"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> 生成默认 IP 预设（若 profiles.json 已存在则跳过）"
if [ ! -f "$ROOT/profiles.json" ]; then
  swift build --disable-sandbox -c debug >/dev/null
  .build/debug/ipswctl init-config "$ROOT/profiles.json"
fi

if [ "${UNIVERSAL:-0}" = "1" ]; then
  echo "==> Release 编译（arm64 + x86_64）"
  swift build --disable-sandbox -c release --arch arm64 --arch x86_64
  BIN_DIR=".build/apple/Products/Release"
else
  echo "==> Release 编译（本机架构）"
  swift build --disable-sandbox -c release
  BIN_DIR=".build/release"
fi

echo "==> 组装 App"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp -f "$BIN_DIR/IPSwitcher" "$APP/Contents/MacOS/IPSwitcher"
cp -f "$BIN_DIR/ipswctl" "$APP/Contents/MacOS/ipswctl"
cp -f Resources/Info.plist "$APP/Contents/Info.plist"
cp -f Resources/web/index.html "$APP/Contents/Resources/web/index.html"
if [ -f profiles.json ]; then
  cp -f profiles.json "$APP/Contents/Resources/profiles.json"
fi

# 版本号写入 Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
  "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
  "$APP/Contents/Info.plist" >/dev/null

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "==> Ad-hoc 签名"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
    || echo "警告：签名失败，仍可直接运行"
else
  echo "==> 开发者证书签名：$SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP"
fi

echo "==> 完成（版本 ${VERSION} / build ${BUILD_NUMBER}）"
echo "    应用：$APP"
echo "    命令行工具：$ROOT/$BIN_DIR/ipswctl"
echo "    架构：$(lipo -archs "$APP/Contents/MacOS/IPSwitcher")"
echo "    启动：open \"$APP\""
