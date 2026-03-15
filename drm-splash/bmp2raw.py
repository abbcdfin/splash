#!/usr/bin/env python3
"""
bmp2raw.py - Convert a BMP file to SPLR raw pixel format for drm-splash.

SPLR format:
  bytes  0-3  : magic "SPLR"
  bytes  4-7  : uint32 width  (little-endian)
  bytes  8-11 : uint32 height (little-endian)
  bytes 12+   : width*height XRGB8888 pixels, row-major
               (memory layout: B G R X per pixel)

Supports 8bpp palette, 24bpp RGB, and 32bpp XRGB without Pillow.
Pillow is used automatically when available for other formats.

Usage:
  bmp2raw.py [OPTIONS] input.bmp output.splr

Options:
  --width  W      canvas width  (default: image width)
  --height H      canvas height (default: image height)
  --bg R,G,B      background colour for canvas padding (default: 0,0,0)
  --no-center     place image at top-left instead of centering
  -h, --help      show this help
"""

import argparse
import struct
import sys
import os


# ---------------------------------------------------------------------------
# Pure-Python BMP reader (8bpp palette, 24bpp, 32bpp, uncompressed)
# ---------------------------------------------------------------------------

def _read_le16(data, offset):
    return struct.unpack_from('<H', data, offset)[0]

def _read_le32(data, offset):
    return struct.unpack_from('<I', data, offset)[0]

def _read_les32(data, offset):
    return struct.unpack_from('<i', data, offset)[0]


def load_bmp_pure(path):
    """
    Returns (pixels, width, height) where pixels is a bytes object of
    width*height XRGB8888 pixels (B G R X per pixel, row-major, top-down).
    Raises ValueError on unsupported format.
    """
    with open(path, 'rb') as f:
        data = f.read()

    if len(data) < 54:
        raise ValueError("file too small to be a BMP")

    # BITMAPFILEHEADER
    if data[0:2] != b'BM':
        raise ValueError("not a BMP file (missing BM signature)")
    pixel_offset = _read_le32(data, 10)

    # BITMAPINFOHEADER (at offset 14)
    hdr_size   = _read_le32(data, 14)
    width      = _read_les32(data, 18)
    height     = _read_les32(data, 22)
    bit_count  = _read_le16(data, 28)
    compression= _read_le32(data, 30)

    if hdr_size < 40:
        raise ValueError(f"unsupported BMP header size {hdr_size}")
    if compression not in (0, 3):  # BI_RGB and BI_BITFIELDS
        raise ValueError(f"unsupported BMP compression {compression}")

    flip = height > 0   # positive height = bottom-up storage
    height = abs(height)

    palette = []
    if bit_count == 8:
        # palette starts at offset 14+hdr_size
        pal_offset = 14 + hdr_size
        n_colors = _read_le32(data, 46) or 256
        for i in range(n_colors):
            b, g, r, _ = data[pal_offset + i*4 : pal_offset + i*4 + 4]
            palette.append((r, g, b))
    elif bit_count not in (24, 32):
        raise ValueError(f"unsupported bit depth {bit_count} (need 8/24/32)")

    # row stride is padded to 4 bytes
    if bit_count == 8:
        row_bytes = (width + 3) & ~3
    elif bit_count == 24:
        row_bytes = (width * 3 + 3) & ~3
    else:  # 32
        row_bytes = width * 4

    rows = []
    for row_idx in range(height):
        src = pixel_offset + row_idx * row_bytes
        row_data = data[src : src + row_bytes]
        row_pixels = []
        for col in range(width):
            if bit_count == 8:
                idx = row_data[col]
                r, g, b = palette[idx]
            elif bit_count == 24:
                b = row_data[col*3]
                g = row_data[col*3 + 1]
                r = row_data[col*3 + 2]
            else:  # 32
                b = row_data[col*4]
                g = row_data[col*4 + 1]
                r = row_data[col*4 + 2]
                # row_data[col*4 + 3] is X/alpha — ignored
            row_pixels.append((r, g, b))
        rows.append(row_pixels)

    if flip:
        rows.reverse()

    # pack as XRGB8888 (B G R X in memory)
    out = bytearray(width * height * 4)
    for y, row in enumerate(rows):
        for x, (r, g, b) in enumerate(row):
            base = (y * width + x) * 4
            out[base]     = b
            out[base + 1] = g
            out[base + 2] = r
            out[base + 3] = 0  # X padding

    return bytes(out), width, height


def load_bmp_pillow(path):
    """
    Load any BMP (or other format Pillow supports) via Pillow.
    Returns (pixels, width, height) in XRGB8888 (BGRX memory order).
    """
    from PIL import Image
    img = Image.open(path).convert('RGB')
    width, height = img.size
    rgb = img.tobytes()  # R G B R G B ...
    out = bytearray(width * height * 4)
    for i in range(width * height):
        r = rgb[i*3]
        g = rgb[i*3 + 1]
        b = rgb[i*3 + 2]
        base = i * 4
        out[base]     = b
        out[base + 1] = g
        out[base + 2] = r
        out[base + 3] = 0
    return bytes(out), width, height


def load_image(path):
    """Try pure-Python loader first; fall back to Pillow."""
    try:
        return load_bmp_pure(path)
    except Exception as pure_err:
        try:
            return load_bmp_pillow(path)
        except ImportError:
            # Pillow not available; re-raise original error
            raise ValueError(f"pure BMP loader failed ({pure_err}) "
                             "and Pillow is not installed") from None


# ---------------------------------------------------------------------------
# Canvas composition
# ---------------------------------------------------------------------------

def compose(pixels, img_w, img_h, canvas_w, canvas_h, bg, center):
    """
    Place image on a canvas of (canvas_w x canvas_h) filled with bg.
    Returns XRGB8888 bytes for the canvas.
    """
    br, bg_r, bb = bg
    out = bytearray(canvas_w * canvas_h * 4)

    # fill background
    pixel = bytes([bb, bg_r, br, 0])
    for i in range(canvas_w * canvas_h):
        out[i*4 : i*4+4] = pixel

    if center:
        off_x = (canvas_w - img_w) // 2
        off_y = (canvas_h - img_h) // 2
    else:
        off_x, off_y = 0, 0

    src_x0 = max(0, -off_x)
    src_y0 = max(0, -off_y)
    dst_x0 = max(0, off_x)
    dst_y0 = max(0, off_y)
    copy_w = min(img_w - src_x0, canvas_w - dst_x0)
    copy_h = min(img_h - src_y0, canvas_h - dst_y0)

    for row in range(copy_h):
        src_off = ((src_y0 + row) * img_w + src_x0) * 4
        dst_off = ((dst_y0 + row) * canvas_w + dst_x0) * 4
        out[dst_off : dst_off + copy_w * 4] = \
            pixels[src_off : src_off + copy_w * 4]

    return bytes(out)


# ---------------------------------------------------------------------------
# SPLR writer
# ---------------------------------------------------------------------------

def write_splr(path, pixels, width, height):
    header = b'SPLR' + struct.pack('<II', width, height)
    with open(path, 'wb') as f:
        f.write(header)
        f.write(pixels)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_bg(s):
    parts = s.split(',')
    if len(parts) != 3:
        raise argparse.ArgumentTypeError("bg must be R,G,B (e.g. 0,0,0)")
    try:
        r, g, b = int(parts[0]), int(parts[1]), int(parts[2])
    except ValueError:
        raise argparse.ArgumentTypeError("bg values must be integers")
    if not all(0 <= v <= 255 for v in (r, g, b)):
        raise argparse.ArgumentTypeError("bg values must be 0-255")
    return (r, g, b)


def main():
    parser = argparse.ArgumentParser(
        description='Convert BMP to SPLR raw pixel format for drm-splash.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    parser.add_argument('input',  help='input BMP file')
    parser.add_argument('output', help='output .splr file')
    parser.add_argument('--width',  type=int, default=None,
                        help='canvas width (default: image width)')
    parser.add_argument('--height', type=int, default=None,
                        help='canvas height (default: image height)')
    parser.add_argument('--bg', type=parse_bg, default=(0, 0, 0),
                        metavar='R,G,B',
                        help='background colour (default: 0,0,0)')
    parser.add_argument('--no-center', action='store_true',
                        help='place image at top-left instead of centering')
    args = parser.parse_args()

    print(f"Loading {args.input} ...")
    try:
        pixels, img_w, img_h = load_image(args.input)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"  image: {img_w}x{img_h}")

    canvas_w = args.width  if args.width  else img_w
    canvas_h = args.height if args.height else img_h

    if canvas_w != img_w or canvas_h != img_h:
        print(f"  canvas: {canvas_w}x{canvas_h}, bg={args.bg}, "
              f"center={not args.no_center}")
        pixels = compose(pixels, img_w, img_h, canvas_w, canvas_h,
                         args.bg, not args.no_center)
    else:
        canvas_w, canvas_h = img_w, img_h

    out_size = 12 + canvas_w * canvas_h * 4
    print(f"  output: {canvas_w}x{canvas_h}, {out_size} bytes -> {args.output}")
    write_splr(args.output, pixels, canvas_w, canvas_h)
    print("Done.")


if __name__ == '__main__':
    main()
