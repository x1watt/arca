#!/usr/bin/env bash
# Copies libmpv (video playback) and ffmpeg/ffprobe (video previews) into a
# Linux bundle together with the shared libraries they need, so Arca runs
# on systems that do not have them installed.
#
# Usage: bundle_media.sh <bundle dir>
#
# Libraries the desktop always provides, or that must match the local
# drivers and sound server, are left out: glibc, the C++ runtime, GTK and
# everything the Flutter engine already loads, X11/Wayland, OpenGL/Vulkan
# and the GPU buffer libraries, ALSA and PipeWire.
#
# The bundle needs a glibc at least as new as the build machine's, so build
# releases on the oldest distribution Arca supports.
set -euo pipefail

bundle="$1"
lib="$bundle/lib"
bin="$bundle/bin"
multiarch="$(gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)"
libmpv="/usr/lib/$multiarch/libmpv.so.2"
ffmpeg="$(command -v ffmpeg || true)"
ffprobe="$(command -v ffprobe || true)"

for need in "$libmpv" "$ffmpeg" "$ffprobe" "$(command -v patchelf || true)"; do
  if [ -z "$need" ] || [ ! -e "$need" ]; then
    echo "bundle_media: missing ${need:-a tool}. On Ubuntu: sudo apt install libmpv2 ffmpeg patchelf" >&2
    exit 1
  fi
done

deps() { ldd "$@" | awk '/=> \//{print $3}' | sort -u; }

# What the engine and GTK already bring in stays with the system.
declare -A skip
for l in $(deps "$lib/libflutter_linux_gtk.so"); do
  skip["$(basename "$l")"]=1
done

excluded='^(ld-linux|libc|libm|libdl|libpthread|librt|libresolv|libutil|libstdc\+\+|libgcc_s|libGL|libGLX|libGLdispatch|libEGL|libGLES|libOpenGL|libgbm|libdrm|libvulkan|libxkbcommon|libwayland-[a-z]+|libasound|libpipewire|libudev|libsystemd|libdbus|libz|libexpat|libfontconfig|libfreetype|libharfbuzz|libglib|libgio|libgobject|libgmodule|libffi|libselinux|libmount|libblkid|libpcre2)[-.]|^(libX|libxcb)'
# Small X extensions a minimal desktop may lack; safe to carry along.
kept='^(libXpresent|libXss|libXv)[.]'

mkdir -p "$lib" "$bin"
count=0
for l in $(deps "$libmpv" "$ffmpeg" "$ffprobe"); do
  name="$(basename "$l")"
  [ -n "${skip[$name]:-}" ] && continue
  [[ "$name" =~ $excluded && ! "$name" =~ $kept ]] && continue
  cp -L "$l" "$lib/$name"
  chmod 644 "$lib/$name"
  patchelf --set-rpath '$ORIGIN' "$lib/$name"
  count=$((count + 1))
done
cp -L "$libmpv" "$lib/libmpv.so.2"
chmod 644 "$lib/libmpv.so.2"
patchelf --set-rpath '$ORIGIN' "$lib/libmpv.so.2"

for tool in "$ffmpeg" "$ffprobe"; do
  cp -L "$tool" "$bin/"
  chmod 755 "$bin/$(basename "$tool")"
  patchelf --set-rpath '$ORIGIN/../lib' "$bin/$(basename "$tool")"
done

# The video plugin links libmpv directly; point it at the bundled copy.
if [ -e "$lib/libmedia_kit_video_plugin.so" ]; then
  patchelf --set-rpath '$ORIGIN' "$lib/libmedia_kit_video_plugin.so"
fi

echo "bundle_media: libmpv, ffmpeg, ffprobe and $count libraries copied"
