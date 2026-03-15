#!/bin/bash
#
# Build a combined initramfs:  openwrt.cpio.gz  +  drm-splash overlay
#
# The kernel's cpio extractor processes concatenated cpio archives in order.
# The overlay (appended last) overrides /init and adds /bin/drm-splash and
# /splash.bmp on top of the unmodified OpenWrt initramfs.
#
# Output: ../dist/initramfs-openwrt-splash.cpio.gz
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT="$SCRIPT_DIR/.."
DIST="$PARENT/dist"
OPENWRT_CPIO="$SCRIPT_DIR/../../linux/rootfs/openwrt.cpio.gz"
DRM_SPLASH="$PARENT/initramfs/build/bin/drm-splash"
SPLASH_BMP="$PARENT/initramfs/build/splash.bmp"
OUTPUT="$DIST/initramfs-openwrt-splash.cpio.gz"

for f in "$OPENWRT_CPIO" "$DRM_SPLASH" "$SPLASH_BMP"; do
    [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

mkdir -p "$TMPDIR/bin"
cp "$SCRIPT_DIR/init"  "$TMPDIR/init"     && chmod 755 "$TMPDIR/init"
cp "$DRM_SPLASH"       "$TMPDIR/bin/drm-splash" && chmod 755 "$TMPDIR/bin/drm-splash"
cp "$SPLASH_BMP"       "$TMPDIR/splash.bmp"

OVERLAY_CPIO=$(mktemp)
(cd "$TMPDIR" && find . | sort | cpio -o -H newc --quiet --owner=0:0) > "$OVERLAY_CPIO"

mkdir -p "$DIST"
(zcat "$OPENWRT_CPIO"; cat "$OVERLAY_CPIO") | gzip -9 > "$OUTPUT"

echo "Built: $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
echo ""
echo "Kernel config:"
echo "  CONFIG_INITRAMFS_SOURCE=\"$OUTPUT\""
