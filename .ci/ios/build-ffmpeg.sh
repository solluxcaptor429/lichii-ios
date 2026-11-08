#!/bin/bash
# Build FFmpeg for iOS with what the Switch 2 titles need and crueter-ci's iOS package lacks:
# the native AV1 decoder driven by the VideoToolbox hardware decoder (A17 Pro / M3 and newer).
# Output: $OUT (default ./ffmpeg-ios) with include/, lib/ and a CMakeLists.txt in the same
# layout as the crueter-ci packages, so externals/ffmpeg can add_subdirectory() it.
set -euo pipefail

TAG=9.0.2
COMMIT=946fcce07b6dcd0331c8cc609192aeff5e1924f8
OUT="${OUT:-$PWD/ffmpeg-ios}"
WORK="${WORK:-$PWD/.ffmpeg-work}"
IOS_MIN="${IOS_MIN:-17.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"

DAV1D_VERSION=1.5.1
DAV1D_SHA256=401813f1f89fa8fd4295805aa5284d9aed9bc7fc1fdbe554af4292f64cbabe21
DAV1D_PREFIX="$WORK/dav1d-install"

mkdir -p "$WORK"
cd "$WORK"
sysroot="$(xcrun --sdk iphoneos --show-sdk-path)"

# dav1d: the software AV1 decoder (NEON-optimised; 1080p60 is easy on A17+). The VideoToolbox
# AV1 hwaccel failed get_buffer() on every frame on iOS 27.
if [ ! -f "$DAV1D_PREFIX/lib/libdav1d.a" ]; then
    command -v meson >/dev/null || pip3 install --break-system-packages meson
    curl -sSfL -o dav1d.tar.xz "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz"
    echo "$DAV1D_SHA256  dav1d.tar.xz" | shasum -a 256 -c -
    rm -rf "dav1d-$DAV1D_VERSION" && tar xf dav1d.tar.xz
    cat > ios-cross.txt <<CROSS
[binaries]
c = '$(xcrun --sdk iphoneos --find clang)'
cpp = '$(xcrun --sdk iphoneos --find clang++)'
ar = '$(xcrun --sdk iphoneos --find ar)'
strip = '$(xcrun --sdk iphoneos --find strip)'

[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$sysroot', '-mios-version-min=$IOS_MIN']
c_link_args = ['-arch', 'arm64', '-isysroot', '$sysroot', '-mios-version-min=$IOS_MIN']

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
CROSS
    meson setup "dav1d-$DAV1D_VERSION/build" "dav1d-$DAV1D_VERSION" --cross-file ios-cross.txt \
        --prefix="$DAV1D_PREFIX" --libdir=lib --buildtype=release --default-library=static \
        -Denable_tools=false -Denable_tests=false -Denable_examples=false
    ninja -C "dav1d-$DAV1D_VERSION/build" install
fi
export PKG_CONFIG_PATH="$DAV1D_PREFIX/lib/pkgconfig"

if [ ! -d "FFmpeg-$COMMIT" ]; then
    curl -sSfL -o src.tar.gz "https://github.com/FFmpeg/FFmpeg/archive/$COMMIT.tar.gz"
    tar xf src.tar.gz
fi
cd "FFmpeg-$COMMIT"

CC="$(xcrun --sdk iphoneos --find clang) -isysroot $sysroot"
CXX="$(xcrun --sdk iphoneos --find clang++) -isysroot $sysroot"

./configure \
    --prefix="$OUT" \
    --enable-cross-compile --target-os=darwin --arch=arm64 \
    --cc="$CC" --cxx="$CXX" \
    --extra-cflags="-arch arm64 -mios-version-min=$IOS_MIN" \
    --extra-ldflags="-arch arm64 -mios-version-min=$IOS_MIN" \
    --disable-avdevice --disable-avformat --disable-doc --disable-everything \
    --disable-ffmpeg --disable-ffprobe --disable-network --disable-iconv \
    --enable-static --disable-shared --enable-pic --enable-small --enable-swresample \
    --enable-filter=yadif,scale \
    --enable-decoder=h264 --enable-decoder=vp8 --enable-decoder=vp9 \
    --enable-decoder=opus \
    --enable-libdav1d --enable-decoder=libdav1d --pkg-config-flags=--static \
    --enable-videotoolbox \
    --enable-hwaccel=h264_videotoolbox --enable-hwaccel=vp9_videotoolbox

make -j"$(sysctl -n hw.ncpu)"
rm -rf "$OUT"
make install
rm -rf "$OUT/share" "$OUT/lib/pkgconfig"
cp "$DAV1D_PREFIX/lib/libdav1d.a" "$OUT/lib/"
cp "$HERE/ffmpeg-CMakeLists.txt" "$OUT/CMakeLists.txt"
echo "$TAG-$COMMIT dav1d-$DAV1D_VERSION videotoolbox" > "$OUT/VERSION"
ls -la "$OUT" "$OUT/lib"
