import struct

def generate_grayscale_gradient_bmp(filename, width, height):
    # BMP row size must be a multiple of 4 bytes
    row_size = (width * 3 + 3) & ~3
    image_size = row_size * height
    file_size = 54 + image_size
    
    # File Header: Signature, File Size, Reserved, Reserved, Data Offset
    header = struct.pack('<2sIHHI', b'BM', file_size, 0, 0, 54)
    # DIB Header: Size, Width, Height, Planes, BitsPerPixel, Compression, ImageSize, Xppm, Yppm, Colors, ImportantColors
    dib_header = struct.pack('<IiiHHIIIIII', 40, width, height, 1, 24, 0, image_size, 2835, 2835, 0, 0)
    
    with open(filename, 'wb') as f:
        f.write(header)
        f.write(dib_header)
        
        # Pixel data (bottom-up)
        for y in range(height):
            # Calculate grayscale value: 0 at top (y=height-1), 255 at bottom (y=0)
            # Since BMP is stored bottom-up, y=0 is the bottom of the image.
            val = int(y * 255 / (height - 1))
            
            row = bytearray()
            for x in range(width):
                #row.extend([val, val, val]) # B, G, R
                row.extend([int(val/4), 0, 0]) # B, G, R
            # Add padding to reach row_size
            row.extend([0] * (row_size - len(row)))
            f.write(row)

if __name__ == "__main__":
    print("Generating 720x1280 grayscale gradient BMP...")
    generate_grayscale_gradient_bmp('gradient_debug.bmp', 720, 1280)
    print("Done: gradient.bmp")
