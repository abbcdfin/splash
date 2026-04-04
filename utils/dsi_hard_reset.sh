#!/bin/bash
#
# dsi_hard_reset.sh - Force hardware reset of DSI + D-PHY via CCU
#
# Bypasses the shared reset_control reference counting by writing
# directly to CCU BUS_MIPI_DSI_GATING (0x02001b4c).
# Bit 16 = reset (0=assert, 1=deassert), Bit 0 = bus gate
#
# Run on a BAD boot after stopping the display app.
# If the display becomes correct after restart, the shared reset
# was preventing proper hardware reset.
#

DSI_GATE_REG=0x02001b4c

read_reg() {
    local RAW
    RAW=$(devmem2 "$1" w 2>/dev/null)
    echo "$RAW" | grep -o '0x[0-9A-Fa-f]*' | tail -n 1
}

echo "=== DSI + D-PHY Hard Reset Test ==="

ORIG=$(read_reg $DSI_GATE_REG)
echo "Current BUS_MIPI_DSI_GATING: $ORIG"

# Step 1: Assert reset AND gate off clock (clear bit 16 and bit 0)
echo "Asserting reset + gating clock (writing 0x00000000)..."
devmem2 $DSI_GATE_REG w 0x00000000 > /dev/null 2>&1
usleep 100000 2>/dev/null || sleep 0.1

# Step 2: Deassert reset + enable clock (set bit 16 and bit 0)
echo "Deasserting reset + enabling clock (writing 0x00010001)..."
devmem2 $DSI_GATE_REG w 0x00010001 > /dev/null 2>&1
usleep 100000 2>/dev/null || sleep 0.1

READBACK=$(read_reg $DSI_GATE_REG)
echo "Readback BUS_MIPI_DSI_GATING: $READBACK"

echo ""
echo "DSI + D-PHY have been hard reset."
echo "Now rebind the DSI driver and start the display app to test."
