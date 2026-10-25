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

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>快捷台</string>
    <key>CFBundleDisplayName</key>       <string>快捷台</string>
    <key>CFBundleIdentifier</key>        <string>com.local.quickdeck</string>
    <key>CFBundleVersion</key>           <string>9</string>
    <key>CFBundleShortVersionString</key><string>1.6.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>QuickDeck</string>
    <key>CFBundleDevelopmentRegion</key> <string>zh_CN</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>「快捷台」使用自动化权限来切换深色/浅色模式等系统设置。</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>「快捷台」使用蓝牙权限来开关蓝牙、显示已连接的设备名称。</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>「快捷台」的截图功能需要屏幕录制权限来保存屏幕截图。</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1

echo "✅ 构建完成：$(cd build && pwd)/QuickDeck.app"
echo "   双击即可运行；建议拖入「应用程序」文件夹后再开启开机自启"
