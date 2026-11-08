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

mkdir -p "$WORK"
cd "$WORK"
if [ ! -d "FFmpeg-$COMMIT" ]; then
    curl -sSfL -o src.tar.gz "https://github.com/FFmpeg/FFmpeg/archive/$COMMIT.tar.gz"
    tar xf src.tar.gz
fi
cd "FFmpeg-$COMMIT"

sysroot="$(xcrun --sdk iphoneos --show-sdk-path)"
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
    --enable-decoder=h264 --enable-decoder=vp8 --enable-decoder=vp9 --enable-decoder=av1 \
    --enable-decoder=opus \
    --enable-videotoolbox \
    --enable-hwaccel=h264_videotoolbox --enable-hwaccel=vp9_videotoolbox \
    --enable-hwaccel=av1_videotoolbox

make -j"$(sysctl -n hw.ncpu)"
rm -rf "$OUT"
make install
rm -rf "$OUT/share" "$OUT/lib/pkgconfig"
cp "$HERE/ffmpeg-CMakeLists.txt" "$OUT/CMakeLists.txt"
echo "$TAG-$COMMIT av1+videotoolbox" > "$OUT/VERSION"
ls -la "$OUT" "$OUT/lib"
