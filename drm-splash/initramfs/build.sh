#!/bin/bash
#
# Build a minimal initramfs cpio image containing drm-splash.
#
# Prerequisites (produced by ../build.sh):
#   ../dist/usr/bin/drm-splash  — statically linked ARM binary
#   ../dist/busybox             — statically linked ARM busybox
#
# The splash image is taken from ../../gradient.bmp (repo root).
# Override with: SPLASH=/path/to/image.bmp ./build.sh
#
# Output:
#   ../dist/initramfs.cpio
#   ../dist/initramfs.cpio.gz
#
# Kernel config:
#   CONFIG_INITRAMFS_SOURCE="/path/to/initramfs.cpio.gz"
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT="$SCRIPT_DIR/.."
DIST="$PARENT/dist"
BDIR="$SCRIPT_DIR/build"
SPLASH="${SPLASH:-$PARENT/../gradient.bmp}"

# ---------- sanity checks ----------

for f in "$DIST/usr/bin/drm-splash" "$DIST/busybox"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found."
        echo "       Run ../build.sh first to build drm-splash and busybox."
        exit 1
    fi
done

if [ ! -f "$SPLASH" ]; then
    echo "ERROR: splash image not found: $SPLASH"
    echo "       Set SPLASH=/path/to/image.bmp to override."
    exit 1
fi

# ---------- assemble initramfs tree ----------

rm -rf "$BDIR"
mkdir -p "$BDIR"/{bin,proc,sys,dev,newroot}

# busybox + required applets
cp "$DIST/busybox" "$BDIR/bin/busybox"
chmod +x "$BDIR/bin/busybox"
for applet in sh mount sleep cat switch_root; do
    ln -sf busybox "$BDIR/bin/$applet"
done

# drm-splash binary
cp "$DIST/usr/bin/drm-splash" "$BDIR/bin/drm-splash"
chmod +x "$BDIR/bin/drm-splash"

# splash image (always named splash.bmp inside initramfs)
cp "$SPLASH" "$BDIR/splash.bmp"

# init script
cp "$SCRIPT_DIR/init" "$BDIR/init"
chmod +x "$BDIR/init"

# ---------- create cpio ----------

CPIO="$DIST/initramfs.cpio"
(cd "$BDIR" && find . | sort | cpio -o -H newc --quiet) > "$CPIO"
gzip -k -f "$CPIO"

SIZE_PLAIN=$(du -sh "$CPIO"    | cut -f1)
SIZE_GZ=$(   du -sh "$CPIO.gz" | cut -f1)

echo ""
echo "initramfs built successfully:"
echo "  $CPIO      ($SIZE_PLAIN)"
echo "  $CPIO.gz   ($SIZE_GZ)"
echo ""
echo "Add to kernel config:"
echo "  CONFIG_INITRAMFS_SOURCE=\"$CPIO.gz\""
echo "  CONFIG_INITRAMFS_COMPRESSION_GZIP=y"
