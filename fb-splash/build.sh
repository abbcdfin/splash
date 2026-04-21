#!/bin/bash
# Build fb-splash for ARM using the OE cross-toolchain.
# Usage: ./build.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source /home/jian/.scripts/setup-oe.sh

BUILD_DIR="$SCRIPT_DIR/build"
DIST_DIR="$SCRIPT_DIR/dist"

rm -rf "$BUILD_DIR" && mkdir "$BUILD_DIR"

cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_DIR/cmake/armv7-toolchain.cmake" \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DSTATIC_BUILD=ON

make -C "$BUILD_DIR" -j"$(nproc)"
make -C "$BUILD_DIR" DESTDIR="$DIST_DIR" install

echo ""
echo "Artifacts in $DIST_DIR/"
echo "  dist/usr/bin/fb-splash          — static ARM binary"
echo "  dist/usr/lib/systemd/system/fb-splash.service"
