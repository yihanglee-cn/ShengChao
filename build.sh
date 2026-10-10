#!/bin/bash
set -euo pipefail

# 液态玻璃播放器 — 构建脚本
# 用 swiftc + macOS 26 SDK 编译，打成可双击运行的 .app

cd "$(dirname "$0")"

APP_NAME="声潮"
BUNDLE="build/${APP_NAME}.app"
EXEC_NAME="LiquidGlassPlayer"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="arm64-apple-macosx26.0"
# 版本号唯一来源：根目录 Info.plist 的 CFBundleShortVersionString。
# 这里不再另写版本号，make_dmg.sh 也从构建出的 app 里读同一份。
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)"
echo "==> 版本号 ${VERSION}（来自 Info.plist）"

echo "==> 清理旧构建"
rm -rf build
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"

echo "==> 编译 Swift (SDK: ${SDK})"
swiftc -parse-as-library \
  -sdk "${SDK}" \
  -target "${TARGET}" \
  -swift-version 5 \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework CoreImage -framework Network \
  -O \
  -o "${BUNDLE}/Contents/MacOS/${EXEC_NAME}" \
  Sources/LiquidGlassPlayerApp.swift \
  Sources/CueParser.swift \
  Sources/Lyrics.swift \
  Sources/AudioLibrary.swift \
  Sources/LanUploadServer.swift \
  Sources/LanUploadView.swift \
  Sources/Scrollbar.swift \
  Sources/UIScale.swift \
  Sources/MainWindowFrame.swift \
  Sources/ContentView.swift \
  Sources/FloatingPlayerView.swift \
  Sources/SplashView.swift

echo "==> 生成图标"
ICONSET="build/AppIcon.iconset"
mkdir -p "${ICONSET}"
swift assets/gen_icon.swift build/icon_1024.png
sips -z 16 16   build/icon_1024.png --out "${ICONSET}/icon_16x16.png" >/dev/null
sips -z 32 32   build/icon_1024.png --out "${ICONSET}/icon_16x16@2x.png" >/dev/null
sips -z 32 32   build/icon_1024.png --out "${ICONSET}/icon_32x32.png" >/dev/null
sips -z 64 64   build/icon_1024.png --out "${ICONSET}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 build/icon_1024.png --out "${ICONSET}/icon_128x128.png" >/dev/null
sips -z 256 256 build/icon_1024.png --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 build/icon_1024.png --out "${ICONSET}/icon_256x256.png" >/dev/null
sips -z 512 512 build/icon_1024.png --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 build/icon_1024.png --out "${ICONSET}/icon_512x512.png" >/dev/null
sips -z 1024 1024 build/icon_1024.png --out "${ICONSET}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "${ICONSET}" -o "${BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> 写入 Info.plist"
cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>声潮</string>
    <key>CFBundleDisplayName</key>
    <string>声潮</string>
    <key>CFBundleIdentifier</key>
    <string>com.dan.liquidglassplayer</string>
    <key>CFBundleExecutable</key>
    <string>LiquidGlassPlayer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrefersDisplaySafeAreaCompatibilityMode</key>
    <false/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Liquid Glass Player</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名（未签名 app 图标可能不显示）"
codesign --force --deep --sign "ShengChao Local Dev" "${BUNDLE}" 2>&1 || echo "(签名跳过)"

echo "==> 安装到用户 Applications"
# 只装到 ~/Applications：同一 bundle id 的包若同时存在于 /Applications 与 ~/Applications，
# Dock / LaunchServices 会把它们当成两个 app，出现两个「声潮」图标。
DEST_APPS="${HOME}/Applications/${APP_NAME}.app"

# 先停掉正在运行的旧实例，避免占用
pkill -f "${EXEC_NAME}" 2>/dev/null || true

mkdir -p "${HOME}/Applications"
rm -rf "${DEST_APPS}"
ditto "${BUNDLE}" "${DEST_APPS}"
codesign --force --deep --sign "ShengChao Local Dev" "${DEST_APPS}" 2>&1 || echo "(签名跳过)"

echo "==> 打包 DMG（复用 make_dmg.sh 的美化流程：背景图 + 拖入 Applications 布局）"
# 只保留最新的一份：先删掉 build 下已有的 dmg（开头已清空 build，这里是双保险）
rm -f build/*.dmg
./make_dmg.sh
# 清掉打包中间产物，build 目录里只留最新的 dmg 与 app
rm -rf build/dmg-staging build/rw.dmg build/dmg-background.png

echo "==> 完成"
echo "App: ${BUNDLE}"
du -sh "${BUNDLE}"
echo "已同步到: ${DEST_APPS}"
ls -1 build/*.dmg
