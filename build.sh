#!/bin/bash
# 构建千人千面(InterviewCopilot)并打包成 .app(系统权限弹窗需要 app 包和 Info.plist)。
set -euo pipefail
cd "$(dirname "$0")"

# 通用二进制：同时包含 Apple 芯片(arm64)和 Intel(x86_64)，两种 Mac 都能直接运行
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/InterviewCopilot"
APP="build/InterviewCopilot.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/InterviewCopilot"

# 界面语言文件：每种语言一个 JSON，加语言只需要往 Localizations 目录放一个文件
mkdir -p "$APP/Contents/Resources/Localizations"
cp Localizations/*.json "$APP/Contents/Resources/Localizations/"
# 系统权限弹窗里的说明文字也给一份英文
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/zh-Hans.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "InterviewCopilot";
"CFBundleDisplayName" = "InterviewCopilot";
"NSAudioCaptureUsageDescription" = "Captures the other side's audio in a meeting for live transcription and translation.";
"NSMicrophoneUsageDescription" = "Records your own voice for the post-interview review and mock interviews.";
"NSSpeechRecognitionUsageDescription" = "Transcribes speech to text on this Mac.";
STRINGS
touch "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.interviewcopilot.app</string>
    <key>CFBundleName</key><string>千人千面</string>
    <key>CFBundleDisplayName</key><string>千人千面</string>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleExecutable</key><string>InterviewCopilot</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
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
