#!/bin/bash
# Regenerates Resources/AppIcon-1024.png and Resources/AppIcon.icns. Needs uv (https://docs.astral.sh/uv/).
set -euo pipefail
cd "$(dirname "$0")/../.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
curl -sSfL -o "$WORK/NotoSerif.ttf" "https://github.com/google/fonts/raw/main/ofl/notoserif/NotoSerif%5Bwdth%2Cwght%5D.ttf"
uv run --with pillow python3 scripts/icon/render.py "$WORK/NotoSerif.ttf" Resources/AppIcon-1024.png
mkdir "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
	sips -z $size $size Resources/AppIcon-1024.png --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
	sips -z $((size * 2)) $((size * 2)) Resources/AppIcon-1024.png --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns updated"
