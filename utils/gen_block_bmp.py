#!/usr/bin/env python3

# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "Pillow",
# ]
# ///

"""Generate a 720x1280 BMP with a grid of blocks."""
from PIL import Image

# Resolution
WIDTH = 720
HEIGHT = 1280

# Grid configuration: 4 rows, 2 columns (Total 8 blocks)
ROWS = 4
COLS = 2

# RGB values for each block in a 2D array [row][col]
# Adjust these values as needed
blocks_rgb = [
    [(255, 0, 0),   (0, 255, 0)],   # Row 0: Red, Green
    [(0, 0, 255),   (255, 255, 0)], # Row 1: Blue, Yellow
    [(255, 0, 255), (0, 255, 255)], # Row 2: Magenta, Cyan
    [(255, 128, 0), (128, 0, 255)]  # Row 3: Orange, Purple
]

blocks_gray = [
    [(0, 0, 0),   (0x3F, 0x3F, 0x40)],   # Row 0: Red, Green
    [(0x40, 0x40, 0x40), (0x7F, 0x7F, 0x7F)], # Row 1: Blue, Yellow
    [(0x80, 0x80, 0x80), (0xBF, 0xBF, 0xBF)], # Row 2: Magenta, Cyan
    [(0xC0, 0xC0, 0xC0), (0xFF, 0xFF, 0xFF)]  # Row 3: Orange, Purple
]



def generate_block_bmp(filename="block_grid.bmp"):
    # Create a new image with the specified resolution
    img = Image.new("RGB", (WIDTH, HEIGHT))
    
    # Calculate block dimensions
    block_w = WIDTH // COLS
    block_h = HEIGHT // ROWS
    
    # Fill each block
    for r in range(ROWS):
        for c in range(COLS):
            color = blocks_gray[r][c]
            # Define block boundaries
            left = c * block_w
            top = r * block_h
            right = left + block_w if c < COLS - 1 else WIDTH
            bottom = top + block_h if r < ROWS - 1 else HEIGHT
            
            # Draw block
            img.paste(color, (left, top, right, bottom))
    
    # Save the image as BMP
    img.save(filename)
    print(f"Generated {filename}: {WIDTH}x{HEIGHT}, {ROWS}x{COLS} grid.")

if __name__ == "__main__":
    generate_block_bmp()
