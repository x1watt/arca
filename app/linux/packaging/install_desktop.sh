#!/usr/bin/env bash
# Adds Arca to the desktop's application list for the current user: the
# desktop entry (org.arca.arca.desktop, matching the window's application
# id so docks show the right icon) and the icon in every size.
#
#   install_desktop.sh [bundle dir]     default: the release bundle
#   install_desktop.sh --remove
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
apps="$data/applications"
icons="$data/icons/hicolor"

refresh() {
  command -v update-desktop-database >/dev/null && update-desktop-database -q "$apps" || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$icons" || true
}

if [ "${1:-}" = "--remove" ]; then
  rm -f "$apps/org.arca.arca.desktop" "$icons"/*/apps/org.arca.arca.png "$icons/scalable/apps/org.arca.arca.svg"
  refresh
  echo "Arca removed from the application list"
  exit 0
fi

bundle="$(cd "${1:-$here/../../build/linux/x64/release/bundle}" && pwd)"
[ -x "$bundle/arca" ] || { echo "no arca binary in $bundle" >&2; exit 1; }

for s in 16 24 32 48 64 128 256 512; do
  install -Dm644 "$here/icons/arca-$s.png" "$icons/${s}x${s}/apps/org.arca.arca.png"
done
install -Dm644 "$here/icons/arca.svg" "$icons/scalable/apps/org.arca.arca.svg"
mkdir -p "$apps"
sed "s|@BUNDLE@|$bundle|g" "$here/org.arca.arca.desktop" > "$apps/org.arca.arca.desktop"
refresh
echo "Arca added to the application list ($bundle)"
