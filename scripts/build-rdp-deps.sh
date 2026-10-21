#!/bin/bash
# Builds the RDP engine's C libraries — OpenSSL and FreeRDP — as static,
# universal (arm64 + x86_64) archives in Vendor/rdp: include/ and lib/.
#
#   scripts/build-rdp-deps.sh          build what is missing
#   scripts/build-rdp-deps.sh --clean  build from scratch
#
# Needs cmake and ninja (brew install cmake ninja). Sources are downloaded
# into ~/Library/Caches/Termstead-rdp-deps and checked against pinned sha256
# sums; they are built in /tmp/termstead-rdp-deps. Not under the repository:
# OpenSSL's build breaks on a path with a space in it, and the checkout's has
# one. Not in the home folder either: build paths end up in the libraries.
# Vendor/rdp is not committed; a release builds it on the Mac that releases.
set -euo pipefail

OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
FREERDP_VERSION=3.32.2
FREERDP_SHA256=e95a505c0057e4d06a3b120477c421028769deba4db9c639ef3465d050f0955c
MACOS_MIN=14.0
ARCHS=(arm64 x86_64)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOADS="$HOME/Library/Caches/Termstead-rdp-deps"
WORK=/tmp/termstead-rdp-deps
OUT="$ROOT/Vendor/rdp"
STAMP="$OUT/.versions"
# Patches to FreeRDP, applied in name order; each says why at its top.
PATCHES="$ROOT/scripts/rdp-patches"
# The script's and the patches' hashes too: a changed flag or patch means
# another build.
WANT="openssl-$OPENSSL_VERSION freerdp-$FREERDP_VERSION macos-$MACOS_MIN script-$(cat "$0" "$PATCHES"/*.patch | shasum -a 256 | cut -c1-12)"
JOBS="$(sysctl -n hw.ncpu)"

if [[ "${1:-}" == "--clean" ]]; then
    rm -rf "$WORK" "$OUT"   # the downloads stay
elif [[ -f "$STAMP" && "$(cat "$STAMP")" == "$WANT" ]]; then
    echo "Vendor/rdp is up to date ($WANT)."
    exit 0
fi

for tool in cmake ninja; do
    command -v "$tool" >/dev/null || { echo "error: $tool is missing — brew install cmake ninja" >&2; exit 1; }
done

mkdir -p "$WORK/src" "$DOWNLOADS"

# fetch <url> <sha256>: downloads once, and refuses a file whose sum is wrong.
fetch() {
    local url="$1" sum="$2" file="$DOWNLOADS/$(basename "$1")"
    [[ -f "$file" ]] || curl -fL --retry 3 -o "$file" "$url"
    if [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sum" ]]; then
        echo "error: $(basename "$file") does not match its pinned sha256" >&2
        rm -f "$file"
        exit 1
    fi
    tar xzf "$file" -C "$WORK/src"
}

fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256"
fetch "https://github.com/FreeRDP/FreeRDP/releases/download/$FREERDP_VERSION/freerdp-$FREERDP_VERSION.tar.gz" "$FREERDP_SHA256"
for patch in "$PATCHES"/freerdp-*.patch; do
    patch -s -p1 -d "$WORK/src/freerdp-$FREERDP_VERSION" <"$patch"
done

export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"

# Neither library may carry this Mac's paths into the app: file names from
# __FILE__ are mapped to /src (the flag itself is compiled in too, so the
# work folder is a neutral one), and both install under a neutral prefix —
# compiled in as their data and config paths — inside DESTDIR.
PREFIX=/opt/termstead-rdp
MAP="-ffile-prefix-map=$WORK=/src"

build_openssl() {
    local arch="$1" root="$WORK/$1/openssl-root"
    [[ -f "$root$PREFIX/lib/libcrypto.a" ]] && return
    local tree="$WORK/$arch/openssl-src"
    rm -rf "$tree"
    mkdir -p "$WORK/$arch"
    cp -R "$WORK/src/openssl-$OPENSSL_VERSION" "$tree"
    (
        cd "$tree"
        ./Configure "darwin64-$arch-cc" no-shared no-tests no-docs no-apps no-module \
            no-engine no-dso --prefix="$PREFIX" --openssldir="$PREFIX/ssl" --libdir=lib \
            -mmacosx-version-min="$MACOS_MIN" "$MAP"
        make -j"$JOBS" build_libs >/dev/null
        rm -rf "$root"
        make install_dev DESTDIR="$root" >/dev/null
    )
}

build_freerdp() {
    local arch="$1" root="$WORK/$1/freerdp-root"
    # Its flags live in this script, so a changed script builds it again.
    [[ -f "$root/.versions" && "$(cat "$root/.versions")" == "$WANT" ]] && return
    local tree="$WORK/$arch/freerdp-build"
    rm -rf "$tree"
    # Only the library a client needs, and the channels Termstead uses
    # left at their defaults. rdpdr stays, with no devices behind it: sound,
    # the heartbeat and network autodetection need it registered. Everything that pulls in another library
    # (X11, SDL, ffmpeg, cups, pcsc, libusb, krb5, json) is off.
    cmake -S "$WORK/src/freerdp-$FREERDP_VERSION" -B "$tree" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
        -DCMAKE_C_FLAGS="$MAP" \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
        -DOPENSSL_ROOT_DIR="$WORK/$arch/openssl-root$PREFIX" \
        -DOPENSSL_USE_STATIC_LIBS=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_MAC=OFF \
        -DWITH_CHANNELS=ON -DWITH_CLIENT_CHANNELS=ON \
        -DWITH_SERVER=OFF -DWITH_SERVER_CHANNELS=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF \
        -DWITH_SAMPLE=OFF -DWITH_MANPAGES=OFF -DWITH_WINPR_TOOLS=OFF -DWITH_RDTK=OFF \
        -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF \
        -DWITH_DSP_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF -DWITH_OPENH264=OFF -DWITH_CAIRO=OFF \
        -DWITH_FUSE=OFF -DWITH_PCSC=OFF -DWITH_SMARTCARD_PCSC=OFF -DWITH_PKCS11=OFF \
        -DWITH_KRB5=OFF -DWITH_CUPS=OFF -DWITH_AAD=OFF -DWITH_JSON_DISABLED=ON -DWITH_CJSON=OFF \
        -DWITH_URIPARSER=OFF -DWITH_OPUS=OFF -DWITH_FDK_AAC=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF \
        -DWITH_OSS=OFF -DWITH_SNDIO=OFF -DWITH_WEBP=OFF -DWITH_JPEG=OFF -DWITH_PNG=OFF \
        -DWITH_LODEPNG=OFF -DWITH_TIMEZONE_ICU=OFF -DWITH_CCACHE=OFF -DWITH_CLANG_FORMAT=OFF \
        -DWITH_MACAUDIO=ON \
        -DCHANNEL_URBDRC=OFF -DCHANNEL_TSMF=OFF -DCHANNEL_PRINTER=OFF -DCHANNEL_SMARTCARD=OFF \
        -DCHANNEL_SERIAL=OFF -DCHANNEL_PARALLEL=OFF -DCHANNEL_RDPECAM=OFF -DCHANNEL_AUDIN=OFF \
        -DCHANNEL_DRIVE=OFF -DCHANNEL_SSHAGENT=OFF -DCHANNEL_RDP2TCP=OFF \
        -DCHANNEL_REMDESK=OFF \
        >"$WORK/$arch-freerdp-cmake.log"
    cmake --build "$tree" -j "$JOBS" >"$WORK/$arch-freerdp-build.log"
    rm -rf "$root"
    DESTDIR="$root" cmake --install "$tree" >/dev/null
    # A channel's shared code is a static library of its own that the
    # install step leaves out, though the client library needs it.
    cp "$tree"/channels/*/common/*.a "$root$PREFIX/lib/" 2>/dev/null || true
    echo "$WANT" >"$root/.versions"
}

for arch in "${ARCHS[@]}"; do
    mkdir -p "$WORK/$arch"
    echo "OpenSSL $OPENSSL_VERSION, $arch"
    build_openssl "$arch"
    echo "FreeRDP $FREERDP_VERSION, $arch"
    build_freerdp "$arch"
done

# One universal archive per library, under the name the first arch gives it.
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
first="${ARCHS[0]}"
openssl="openssl-root$PREFIX"
freerdp="freerdp-root$PREFIX"
for library in "$WORK/$first/$openssl"/lib/*.a "$WORK/$first/$freerdp"/lib/*.a; do
    relative="${library#"$WORK/$first/"}"
    inputs=()
    for arch in "${ARCHS[@]}"; do inputs+=("$WORK/$arch/$relative"); done
    lipo -create "${inputs[@]}" -output "$OUT/lib/$(basename "$library")"
done
# Headers are the same for both architectures.
cp -R "$WORK/$first/$openssl/include/." "$OUT/include/"
cp -R "$WORK/$first/$freerdp/include/." "$OUT/include/"
echo "$WANT" >"$STAMP"
du -sh "$OUT/lib"
