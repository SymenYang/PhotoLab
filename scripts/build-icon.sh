#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p Resources/AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon-source.png --out "Resources/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Resources/AppIcon-source.png --out "Resources/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
