#!/usr/bin/env bash
# Rebuild a Lichii AppImage with Qt6 bundled, then package it as a Nixport Port.
# Usage: build-port.sh <original.AppImage> <QT_DIR>   (run on an ARM64 Linux machine)
set -euo pipefail

SRC="$(readlink -f "$1")"
QT="$(readlink -f "$2")"
WORK="$(pwd)/work"; OUT="$(pwd)/out"
rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"
cd "$WORK"

echo "==> Extracting original AppImage"
cp "$SRC" orig.AppImage; chmod +x orig.AppImage
./orig.AppImage --appimage-extract >/dev/null
APPDIR="$WORK/squashfs-root"

echo "==> Bundling Qt6 libraries and plugins"
mkdir -p "$APPDIR/usr/lib" "$APPDIR/usr/plugins"
cp -an "$QT"/lib/libQt6*.so* "$APPDIR/usr/lib/"
cp -an "$QT"/lib/libicu*.so* "$APPDIR/usr/lib/" 2>/dev/null || true
for p in platforms platformthemes imageformats iconengines styles xcbglintegrations tls generic; do
  [ -d "$QT/plugins/$p" ] && cp -a "$QT/plugins/$p" "$APPDIR/usr/plugins/"
done

echo "==> Bundling extra shared libs (xcb, xkbcommon, ...)"
copy_deps() {
  local f="$1"
  LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/lib:${LD_LIBRARY_PATH:-}" ldd "$f" 2>/dev/null \
  | awk '/=> \//{print $3}' | while read -r lib; do
      b="$(basename "$lib")"
      case "$b" in
        libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libutil.so*|ld-linux*|libresolv.so*|\
        libGL.so*|libGLX.so*|libEGL.so*|libOpenGL.so*|libvulkan.so*|libgcc_s.so*|libstdc++.so*|\
        libX11.so*|libXext.so*|libxcb.so*|libdrm.so*|libwayland*) continue ;;
      esac
      [ -e "$APPDIR/usr/lib/$b" ] || cp -L "$lib" "$APPDIR/usr/lib/$b"
  done
}
for f in "$APPDIR"/usr/plugins/platforms/*.so "$APPDIR"/usr/plugins/xcbglintegrations/*.so \
         "$APPDIR"/usr/lib/libQt6XcbQpa.so* ; do
  [ -f "$f" ] && copy_deps "$f"
done
for n in libxcb-cursor libxcb-icccm libxcb-image libxcb-keysyms libxcb-render-util \
         libxcb-xinerama libxcb-xkb libxcb-shape libxcb-randr libxcb-sync libxcb-xfixes \
         libxcb-render libxcb-shm libxcb-util libxkbcommon libxkbcommon-x11 libXau libXdmcp; do
  for l in /usr/lib/aarch64-linux-gnu/${n}.so*; do
    [ -e "$l" ] && cp -aL "$l" "$APPDIR/usr/lib/" 2>/dev/null || true
  done
done

echo "==> Writing wrapper AppRun"
cd "$APPDIR"
if [ -L AppRun ]; then
  REAL="$(readlink AppRun)"; rm AppRun
else
  mv AppRun AppRun.real; REAL="AppRun.real"
fi
cat > AppRun <<WRAP
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\$0")")"
export LD_LIBRARY_PATH="\$HERE/usr/lib:\$HERE/lib:\${LD_LIBRARY_PATH:-}"
export QT_PLUGIN_PATH="\$HERE/usr/plugins"
export QT_QPA_PLATFORM="\${QT_QPA_PLATFORM:-xcb}"
export QT_XCB_GL_INTEGRATION="\${QT_XCB_GL_INTEGRATION:-none}"
cd "\$HERE"
exec "\$HERE/$REAL" "\$@"
WRAP
chmod +x AppRun
cd "$WORK"

echo "==> Checking for unresolved libs"
BIN="$APPDIR/$REAL"; [ -e "$BIN" ] || BIN="$APPDIR/usr/bin/lichii"
LD_LIBRARY_PATH="$APPDIR/usr/lib" ldd "$BIN" | grep "not found" || echo "none missing"

echo "==> Repacking AppImage"
if [ ! -x appimagetool ]; then
  curl -fsSL -o appimagetool \
   https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-aarch64.AppImage
  chmod +x appimagetool
fi
ARCH=aarch64 ./appimagetool --appimage-extract-and-run --comp zstd "$APPDIR" "$OUT/lichii.AppImage"

echo "==> Creating Nixport Port"
cat > "$OUT/port.json" <<'JSON'
{
  "schema": "nixport.port.v1",
  "id": "lichii",
  "name": "Lichii",
  "version": "1.0.0",
  "entries": [
    { "id": "launcher", "name": "Open Lichii", "kind": "launcher", "command": "AppRun", "display": "x11" }
  ],
  "storage": { "home": "home" },
  "logs": ["logs/last_run.log"]
}
JSON
cd "$OUT" && zip -1 lichii-port.zip port.json lichii.AppImage
echo "DONE: $OUT/lichii-port.zip"
