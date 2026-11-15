#!/bin/bash
# 构建 M0Probe 并打包成 .app(系统权限弹窗需要 app 包和 Info.plist)。
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/M0Probe"
APP="build/M0Probe.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/M0Probe"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.interviewcopilot.m0probe</string>
    <key>CFBundleName</key><string>M0Probe</string>
    <key>CFBundleExecutable</key><string>M0Probe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>M0 验证：采集系统声音以测试 Process Tap。</string>
</dict>
</plist>
PLIST

# 没有开发者证书时用临时签名。注意：每次重新构建后，系统可能要求重新授权。
codesign --force --sign - "$APP"
echo "已生成 $APP"
