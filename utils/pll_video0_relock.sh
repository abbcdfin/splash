#!/bin/bash
#
# pll_video0_relock.sh - Force PLL_VIDEO0 to re-lock by toggling enable bit
#
# Test: on a BAD boot (incorrect display), run this script to see if
# forcing a PLL re-lock fixes the display. If it does, the PLL's analog
# lock quality at power-on is the root cause.
#

PLL_REG=0x02001040

read_reg() {
    local RAW
    RAW=$(devmem2 "$1" w 2>/dev/null)
    echo "$RAW" | grep -o '0x[0-9A-Fa-f]*' | tail -n 1
}

echo "=== PLL_VIDEO0 Re-lock Test ==="

# Read current value
ORIG=$(read_reg $PLL_REG)
echo "Current PLL_VIDEO0_CTRL: $ORIG"

# Clear bit 31 (PLL enable) — keep all other bits
DISABLED=$(printf "0x%08X" $(( ORIG & ~0x80000000 )))
echo "Disabling PLL (clearing bit 31): $DISABLED"
devmem2 $PLL_REG w $DISABLED > /dev/null 2>&1

# Brief wait for PLL to fully stop
usleep 100000 2>/dev/null || sleep 0.1

# Re-enable bit 31 — forces fresh PLL lock
echo "Re-enabling PLL (setting bit 31): $ORIG"
devmem2 $PLL_REG w $ORIG > /dev/null 2>&1

# Wait for PLL to lock
usleep 100000 2>/dev/null || sleep 0.1

# Read back to confirm
READBACK=$(read_reg $PLL_REG)
echo "Readback PLL_VIDEO0_CTRL: $READBACK"

echo "Done. Check if the display changed."
