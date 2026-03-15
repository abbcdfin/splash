#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE=drm-splash-builder

docker build -t "$IMAGE" "$SCRIPT_DIR/docker"

docker run --rm \
    -v "$SCRIPT_DIR:/src" \
    -w /src \
    --user "$(id -u):$(id -g)" \
    "$IMAGE" \
    bash -c "
        rm -rf build && mkdir build && cd build &&
        cmake .. \
            -DCMAKE_TOOLCHAIN_FILE=../cmake/armv7-toolchain.cmake \
            -DCMAKE_INSTALL_PREFIX=/usr \
            -DSTATIC_BUILD=ON &&
        make -j\$(nproc) &&
        make DESTDIR=/src/dist install &&
        cp /opt/busybox-arm /src/dist/busybox
    "

echo "Artifacts in $SCRIPT_DIR/dist/"
echo "  dist/usr/bin/drm-splash  — static ARM binary"
echo "  dist/busybox             — static ARM busybox"
echo ""
echo "Next: run initramfs/build.sh to assemble the cpio image."
