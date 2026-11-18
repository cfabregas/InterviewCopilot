#!/bin/bash
# 打发布用的安装包：构建 app，装进 dist/InterviewCopilot.dmg。
# 打开 DMG 后窗口里有应用和「应用程序」文件夹的快捷方式，拖过去就装好了。
# 发布用临时签名，不绑定开发者本机的证书。
set -euo pipefail
cd "$(dirname "$0")"

CODESIGN_IDENTITY=- ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/InterviewCopilot.app/Contents/Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/InterviewCopilot.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f dist/InterviewCopilot.dmg
hdiutil create -quiet -volname "千人千面 $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO dist/InterviewCopilot.dmg
echo "已生成 dist/InterviewCopilot.dmg($VERSION)"
