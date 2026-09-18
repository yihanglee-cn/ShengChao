#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="声潮"
VERSION="1.2.2.0"
DMG_BASE="ShengChao-${VERSION}"
VOL_NAME="${APP_NAME}"
STAGING="build/dmg-staging"
RW_DMG="build/rw.dmg"
FINAL_DMG="build/${DMG_BASE}.dmg"
BG_IMG="build/dmg-background.png"

echo "==> 确保 app 已构建"
[ -d "build/${APP_NAME}.app" ] || ./build.sh

echo "==> 生成 DMG 背景图"
python3 - "${BG_IMG}" "${VERSION}" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont

out, version = sys.argv[1], sys.argv[2]
W, H = 660, 400
img = Image.new("RGB", (W, H))
draw = ImageDraw.Draw(img)

# 深色渐变（呼应夜晚模式）
for y in range(H):
    t = y / H
    r = int(28 + (12 - 28) * t)
    g = int(30 + (18 - 30) * t)
    b = int(40 + (28 - 40) * t)
    draw.line([(0, y), (W, y)], fill=(r, g, b))

# 顶部声潮 标题
def font(size, bold=False):
    p = "/System/Library/Fonts/STHeiti Medium.ttc" if bold else "/System/Library/Fonts/STHeiti Light.ttc"
    try:
        return ImageFont.truetype(p, size, index=0)
    except Exception:
        return ImageFont.load_default()

title = "声潮"
tf = font(64, bold=True)
tb = draw.textbbox((0, 0), title, font=tf)
tw, th = tb[2] - tb[0], tb[3] - tb[1]
draw.text(((W - tw) / 2, 46), title, font=tf, fill=(255, 255, 255, 255))

sub = f"液态玻璃播放器 · v{version}"
sf = font(20)
sb = draw.textbbox((0, 0), sub, font=sf)
sw = sb[2] - sb[0]
draw.text(((W - sw) / 2, 120), sub, font=sf, fill=(170, 178, 190, 255))

# 底部提示
hint = "拖入 Applications 文件夹即可安装"
hf = font(16)
hb = draw.textbbox((0, 0), hint, font=hf)
hw = hb[2] - hb[0]
draw.text(((W - hw) / 2, H - 40), hint, font=hf, fill=(140, 148, 160, 255))

img.save(out)
print("background:", out)
PY

echo "==> 准备 staging（app + Applications 软链）"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"
cp -R "build/${APP_NAME}.app" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

echo "==> 创建读写 DMG"
rm -f "${RW_DMG}" "${FINAL_DMG}"
hdiutil create -volname "${VOL_NAME}" -srcfolder "${STAGING}" -ov -format UDRW -size 200m "${RW_DMG}" >/dev/null

echo "==> 挂载并布置图标"
MOUNT_DIR=$(hdiutil attach "${RW_DMG}" -nobrowse -readwrite -noverify -noautoopen | grep -o '/Volumes/.*' | tail -1)
echo "    mounted at ${MOUNT_DIR}"

mkdir -p "${MOUNT_DIR}/.background"
cp "${BG_IMG}" "${MOUNT_DIR}/.background/background.png"

osascript <<EOF || echo "    (AppleScript 布局失败，保留默认布局)"
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 760, 500}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {160, 190}
        set position of item "Applications" of container window to {410, 190}
        update without registering applications
        close
    end tell
end tell
EOF

echo "==> 卸载并转换为压缩 DMG"
hdiutil detach "${MOUNT_DIR}" -force >/dev/null
hdiutil convert "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -o "${FINAL_DMG}" >/dev/null
rm -f "${RW_DMG}"

echo "==> 完成"
echo "DMG: ${FINAL_DMG}"
du -sh "${FINAL_DMG}"
