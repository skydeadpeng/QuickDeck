#!/bin/bash
# 一键构建 QuickDeck.app：编译 Release 版本 → 组装 .app 包 → ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")"

echo "🔨 正在编译 Release 版本…"
swift build -c release

APP="build/QuickDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/QuickDeck "$APP/Contents/MacOS/QuickDeck"
chmod +x "$APP/Contents/MacOS/QuickDeck"
cp Support/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" >/dev/null 2>&1

echo "✅ 构建完成：$(cd build && pwd)/QuickDeck.app"
echo "   双击即可运行；建议拖入「应用程序」文件夹后再开启开机自启"
