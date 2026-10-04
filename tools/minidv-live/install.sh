#!/bin/bash
#
#  install.sh — собирает ярлык «MiniDV Live.app» и ставит его в /Applications.
#
#  Сам ярлык — обычный bash-скрипт плюс помощник на node (obs-sources.js).
#  Иконка рисуется здесь же, внешних зависимостей нет (python3, sips, iconutil
#  есть в системе).
#
#  Запуск:  ./install.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/Applications/MiniDV Live.app"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

APP="$STAGE/MiniDV Live.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>MiniDV Live</string>
	<key>CFBundleDisplayName</key><string>MiniDV Live</string>
	<key>CFBundleIdentifier</key><string>local.minidv.live</string>
	<key>CFBundleExecutable</key><string>MiniDVLive</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSHumanReadableCopyright</key><string>Локальный ярлык для ASFW + OBS</string>
</dict>
</plist>
PLIST

install -m 755 "$HERE/MiniDVLive" "$APP/Contents/MacOS/MiniDVLive"
install -m 644 "$HERE/obs-sources.js" "$APP/Contents/Resources/obs-sources.js"

# --- иконка: камера с объективом и зелёной точкой записи ---
python3 - "$STAGE/icon1024.png" <<'PY'
import struct, sys, zlib

W = H = 1024
BG, BODY, RING, LENS, REC = (21, 26, 34), (43, 52, 68), (106, 168, 255), (14, 18, 24), (78, 201, 138)
img = bytearray(BG * (W * H))

def put(x, y, c):
    if 0 <= x < W and 0 <= y < H:
        i = (y * W + x) * 3
        img[i:i + 3] = bytes(c)

def disc(cx, cy, r, c):
    for y in range(cy - r, cy + r + 1):
        dx = int((r * r - (y - cy) ** 2) ** 0.5)
        for x in range(cx - dx, cx + dx + 1):
            put(x, y, c)

x0, y0, x1, y1, rad = 112, 322, 912, 702, 56
for y in range(y0, y1):
    for x in range(x0, x1):
        dx = max(x0 + rad - x, x - (x1 - rad), 0)
        dy = max(y0 + rad - y, y - (y1 - rad), 0)
        if dx * dx + dy * dy <= rad * rad:
            put(x, y, BODY)
disc(512, 512, 300, RING)
disc(512, 512, 284, BODY)
disc(512, 512, 150, LENS)
disc(790, 250, 46, REC)

raw = b''.join(b'\x00' + bytes(img[y * W * 3:(y + 1) * W * 3]) for y in range(H))

def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)

png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(raw, 9))
png += chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
PY

ICONSET="$STAGE/icon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$STAGE/icon1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$STAGE/icon1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

rm -rf "$TARGET"
cp -R "$APP" "$TARGET"
chmod -R u+rwX,go+rX "$TARGET"

echo "Установлено: $TARGET"
echo "Запуск: двойной клик в Finder, из Launchpad или: open -a 'MiniDV Live'"
