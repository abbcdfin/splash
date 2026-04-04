#!/usr/bin/env python3

# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "numpy",
#     "Pillow",
#     "matplotlib",
#     "PySide6",
# ]
# ///

import argparse
import numpy as np
from PIL import Image
import matplotlib
try:
    matplotlib.use('QtAgg')
except:
    pass
import matplotlib.pyplot as plt

def simulate_mipi_lane_error(input_path, bit_shift=1, num_lanes=4):
    # 1. Load Image
    img = Image.open(input_path).convert('RGB')
    width, height = img.size
    data = np.array(img).flatten() # Continuous byte stream [R, G, B, R, G, B...]

    # 2. De-interleave bytes into Lanes
    # MIPI sends Byte 0 to Lane 0, Byte 1 to Lane 1, etc.
    lanes = [data[i::num_lanes] for i in range(num_lanes)]
    
    # 3. Apply Bit-Shift ONLY to Lane 0 (The 'Glitchy' Lane)
    lane0_bits = np.unpackbits(lanes[0])
    shifted_lane0_bits = np.roll(lane0_bits, -bit_shift)
    lanes[0] = np.packbits(shifted_lane0_bits)

    # 4. Re-interleave Lanes back into a single byte stream
    min_len = min(len(l) for l in lanes)
    reconstructed = np.zeros(min_len * num_lanes, dtype=np.uint8)
    for i in range(num_lanes):
        reconstructed[i::num_lanes] = lanes[i][:min_len]

    # 5. Reshape and Display
    # Ensure we have enough data for a full image
    total_pixels = (width * height * 3)
    final_data = reconstructed[:total_pixels].reshape((height, width, 3))
    shifted_img = Image.fromarray(final_data, 'RGB')

    fig, axes = plt.subplots(1, 2, figsize=(14, 7))
    axes[0].imshow(img)
    axes[0].set_title("Original (All Lanes Synced)")
    axes[1].imshow(shifted_img)
    axes[1].set_title(f"Lane 0 Shifted by {bit_shift} bits ({num_lanes} Lanes)")
    
    for ax in axes: ax.axis('off')
    plt.suptitle("MIPI DSI Multi-Lane Skew Simulation")
    plt.tight_layout()
    plt.show()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("input", help="Path to your gradient.bmp")
    parser.add_argument("--shift", type=int, default=1)
    parser.add_argument("--lanes", type=int, default=4)
    args = parser.parse_args()
    simulate_mipi_lane_error(args.input, args.shift, args.lanes)
