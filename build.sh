#!/bin/bash
# 构建面试助手并打包成 .app(系统权限弹窗需要 app 包和 Info.plist)。
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/InterviewCopilot"
APP="build/InterviewCopilot.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/InterviewCopilot"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.interviewcopilot.app</string>
    <key>CFBundleName</key><string>面试助手</string>
    <key>CFBundleExecutable</key><string>InterviewCopilot</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>采集会议中对方的声音，用于实时转写和翻译。</string>
    <key>NSMicrophoneUsageDescription</key><string>录制你自己的发言，用于会后复盘。</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>在本机把语音转写成文字。</string>
</dict>
</plist>
PLIST

# 签名：钥匙串里有代码签名证书就用它，系统权限授权在重新构建后仍然有效。
# 没有证书时退回临时签名，此时每次重新构建后系统都会重新询问系统音频录制等权限。
# 可用环境变量 CODESIGN_IDENTITY 指定证书名。
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/"/{print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "已生成 $APP(使用证书签名)"
else
    codesign --force --sign - "$APP"
    echo "已生成 $APP(临时签名：重新构建后需要重新授权)"
fi
