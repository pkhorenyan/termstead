#!/bin/bash
# Static universal LibVNCClient, isolated from Homebrew's runtime libraries.
set -euo pipefail
VERSION=0.9.15
SHA256=62352c7795e231dfce044beb96156065a05a05c974e5de9e023d688d8ff675d7
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=/tmp/termstead-vnc-deps
OUT="$ROOT/Vendor/vnc"
[[ -f "$ROOT/Vendor/rdp/.versions" ]] || {
    echo "error: Run scripts/build-rdp-deps.sh first (the VNC engine also uses its OpenSSL)." >&2
    exit 1
}
WANT="libvncclient-$VERSION macos-14 script-$(cat "$0" "$ROOT/scripts/vnc-patches/"*.patch | shasum -a 256 | cut -c1-12) openssl-$(cat "$ROOT/Vendor/rdp/.versions")"
if [[ -f "$OUT/.versions" && "$(cat "$OUT/.versions")" == "$WANT" ]]; then
    echo "Vendor/vnc is up to date."
    exit 0
fi
for tool in cmake ninja; do command -v "$tool" >/dev/null; done
mkdir -p "$WORK"
ARCHIVE="$WORK/libvncserver-$VERSION.tar.gz"
[[ -f "$ARCHIVE" ]] || curl -fL --retry 3 \
    "https://codeload.github.com/LibVNC/libvncserver/tar.gz/refs/tags/LibVNCServer-$VERSION" -o "$ARCHIVE"
[[ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" == "$SHA256" ]] || { echo "error: LibVNCClient checksum mismatch" >&2; exit 1; }
tar xzf "$ARCHIVE" -C "$WORK"
SOURCE="$WORK/libvncserver-LibVNCServer-$VERSION"
for change in "$ROOT/scripts/vnc-patches/"*.patch; do
    patch -s -p1 -d "$SOURCE" < "$change"
done
# JPEG/Tight and optional integrations are off: ZRLE, zlib, Hextile,
# CopyRect and Raw need only the system zlib. OpenSSL supplies ARD crypto.
cmake -S "$SOURCE" -B "$WORK/build" -G Ninja \
    -Wno-deprecated -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_C_FLAGS="-ffile-prefix-map=$WORK=/src" \
    -DBUILD_SHARED_LIBS=OFF -DOPENSSL_ROOT_DIR="$ROOT/Vendor/rdp" -DOPENSSL_USE_STATIC_LIBS=ON \
    -DWITH_OPENSSL=ON -DWITH_GNUTLS=OFF -DWITH_GCRYPT=OFF \
    -DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_LZO=OFF -DWITH_SASL=OFF \
    -DWITH_SDL=OFF -DWITH_GTK=OFF -DWITH_QT=OFF -DWITH_XCB=OFF \
    -DWITH_FFMPEG=OFF -DWITH_SYSTEMD=OFF -DWITH_LIBSSHTUNNEL=OFF \
    -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF > "$WORK/configure.log"
cmake --build "$WORK/build" --target vncclient -j "$(sysctl -n hw.ncpu)" > "$WORK/build.log"
mkdir -p "$OUT/lib" "$OUT/include/rfb"
cp "$WORK/build/libvncclient.a" "$OUT/lib/"
cp "$SOURCE/include/rfb/"*.h "$WORK/build/include/rfb/"*.h "$OUT/include/rfb/"
printf '%s\n' "$WANT" > "$OUT/.versions"
lipo -info "$OUT/lib/libvncclient.a"
