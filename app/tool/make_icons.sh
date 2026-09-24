#!/usr/bin/env bash
# Renders Arca's icons from the SVGs in assets/icon for Android (launcher,
# adaptive layers) and Linux (hicolor sizes). Needs ImageMagick.
# Run from app/: tool/make_icons.sh
set -euo pipefail
cd "$(dirname "$0")/.."
icon=assets/icon

render() { # svg size out
  convert -background none -density 1200 "$1" -resize "$2x$2" -depth 8 "PNG32:$3"
}

# Android: legacy launcher icon (48 dp) and adaptive layers (108 dp).
res=android/app/src/main/res
# density:launcher px:layer px (48 dp and 108 dp at 1, 1.5, 2, 3, 4x)
for row in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
  IFS=: read -r d launcher layer <<< "$row"
  mkdir -p "$res/mipmap-$d"
  render "$icon/arca.svg" "$launcher" "$res/mipmap-$d/ic_launcher.png"
  render "$icon/arca-foreground.svg" "$layer" "$res/mipmap-$d/ic_launcher_foreground.png"
  render "$icon/arca-monochrome.svg" "$layer" "$res/mipmap-$d/ic_launcher_monochrome.png"
done

# Linux: hicolor sizes, installed by linux/packaging/install_desktop.sh.
out=linux/packaging/icons
mkdir -p "$out"
for s in 16 24 32 48 64 128 256 512; do
  render "$icon/arca.svg" "$s" "$out/arca-$s.png"
done
render "$icon/arca.svg" 512 "$icon/arca.png"
echo "icons written"
