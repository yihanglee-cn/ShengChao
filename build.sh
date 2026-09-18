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

echo "==> 清理旧构建"
rm -rf build
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"

echo "==> 编译 C 桥接层"
mkdir -p build
clang -c Sources/ort_bridge.c -I vendor/include -o build/ort_bridge.o

echo "==> 编译 Swift (SDK: ${SDK})"
swiftc -parse-as-library \
  -sdk "${SDK}" \
  -target "${TARGET}" \
  -swift-version 5 \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework CoreImage \
  -import-objc-header Sources/bridge.h \
  build/ort_bridge.o \
  vendor/libonnxruntime.1.dylib \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -O \
  -o "${BUNDLE}/Contents/MacOS/${EXEC_NAME}" \
  Sources/LiquidGlassPlayerApp.swift \
  Sources/CueParser.swift \
  Sources/Lyrics.swift \
  Sources/AudioLibrary.swift \
  Sources/Scrollbar.swift \
  Sources/ContentView.swift \
  Sources/FloatingPlayerView.swift \
  Sources/SplashView.swift \
  Sources/DepthEngine.swift \
  Sources/ParallaxCoverView.swift

echo "==> 拷贝 ORT 运行时与模型"
mkdir -p "${BUNDLE}/Contents/Frameworks"
cp vendor/libonnxruntime.1.dylib "${BUNDLE}/Contents/Frameworks/"
cp vendor/cover3d_model.onnx "${BUNDLE}/Contents/Resources/cover3d_model.onnx"

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
cat > "${BUNDLE}/Contents/Info.plist" <<'PLIST'
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
    <string>1.2.2.0</string>
    <key>CFBundleVersion</key>
    <string>1.2.2.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Liquid Glass Player</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名（未签名 app 图标可能不显示）"
codesign --force --deep --sign - "${BUNDLE}" 2>&1 || echo "(签名跳过)"

echo "==> 同步到桌面 & Applications"
DEST_DESKTOP="$HOME/Desktop/${APP_NAME}.app"
DEST_APPS="/Applications/${APP_NAME}.app"

# 先停掉正在运行的旧实例，避免占用
pkill -f "${EXEC_NAME}" 2>/dev/null || true

rm -rf "${DEST_DESKTOP}"
ditto "${BUNDLE}" "${DEST_DESKTOP}"
codesign --force --deep --sign - "${DEST_DESKTOP}" 2>&1 || echo "(桌面签名跳过)"

if [ -w /Applications ]; then
  rm -rf "${DEST_APPS}"
  ditto "${BUNDLE}" "${DEST_APPS}"
  codesign --force --deep --sign - "${DEST_APPS}" 2>&1 || echo "(Applications 签名跳过)"
else
  echo "(Applications 无写权限，跳过)"
fi

echo "==> 完成"
echo "App: ${BUNDLE}"
du -sh "${BUNDLE}"
echo "已同步到: ${DEST_DESKTOP}"
