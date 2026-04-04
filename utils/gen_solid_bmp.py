#!/usr/bin/env python3

# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "Pillow",
# ]
# ///

"""Generate a solid-colour 720x1280 BMP. Usage: gen_solid_bmp.py R G B [output.bmp]"""
import sys
from PIL import Image

r, g, b = (int(x, 0) for x in sys.argv[1:4])
out = sys.argv[4] if len(sys.argv) > 4 else f"solid_{r:02x}{g:02x}{b:02x}.bmp"
Image.new("RGB", (720, 1280), (r, g, b)).save(out)
print(f"{out}: 720x1280 RGB=({r:#04x},{g:#04x},{b:#04x})")
