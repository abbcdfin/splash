#!/bin/bash
#
# dump_display_regs.sh — Allwinner T113-S display pipeline register dump
#
# Output format matches the kernel's PRE-INIT FULL REGISTER DUMP
# (commit 51d35125e) and U-Boot's dispdump command for direct diff.
#
# Run on target as root. Requires devmem2 in PATH.
#

set -eo pipefail

# Read one 32-bit register, return as 8-char lowercase hex (no 0x prefix)
rr() {
    local RAW VAL
    RAW=$(devmem2 "$1" w 2>/dev/null) || { printf "DEADBEEF"; return; }
    VAL=$(echo "$RAW" | grep -o "0x[0-9A-Fa-f]*" | tail -n 1)
    if [ -n "$VAL" ]; then
        printf "%08x" "$VAL"
    else
        printf "DEADBEEF"
    fi
}

# Dump a block: dump_block BASE TAG SIZE_BYTES
# Prints TAG[off] val val val val  (4 words per line)
dump_block() {
    local BASE=$1 TAG=$2 SIZE=$3
    local OFF=0
    while [ "$OFF" -lt "$SIZE" ]; do
        printf "%s[%03x] %s %s %s %s\n" "$TAG" "$OFF" \
            "$(rr "$(printf '0x%x' $((BASE + OFF)))")" \
            "$(rr "$(printf '0x%x' $((BASE + OFF + 4)))")" \
            "$(rr "$(printf '0x%x' $((BASE + OFF + 8)))")" \
            "$(rr "$(printf '0x%x' $((BASE + OFF + 12)))")"
        OFF=$((OFF + 16))
    done
}

# Write one 32-bit register
wr() {
    devmem2 "$1" w "$2" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Enable bus clock gates so downstream registers are readable.
# Save originals for restore.
# ---------------------------------------------------------------------------
SAVED_B4C=$(rr 0x02001b4c)
SAVED_B7C=$(rr 0x02001b7c)
SAVED_ABC=$(rr 0x02001abc)
SAVED_60C=$(rr 0x0200160c)

wr 0x02001b4c "$(printf '0x%x' $((0x$SAVED_B4C | 0x10001)))"
wr 0x02001b7c "$(printf '0x%x' $((0x$SAVED_B7C | 0x10001)))"
wr 0x02001abc "$(printf '0x%x' $((0x$SAVED_ABC | 0x10001)))"
wr 0x0200160c "$(printf '0x%x' $((0x$SAVED_60C | 0x10001)))"
sleep 0.01

# ---------------------------------------------------------------------------
echo "=== PRE-INIT FULL REGISTER DUMP ==="

# CCU
printf "CCU: 0xb4c=%s 0xb7c=%s 0xabc=%s 0x60c=%s\n" \
    "$SAVED_B4C" "$SAVED_B7C" "$SAVED_ABC" "$SAVED_60C"
printf "CCU: PLL_VIDEO0(040)=%s MIPI_DSI(b24)=%s TCON_LCD0(b60)=%s\n" \
    "$(rr 0x02001040)" "$(rr 0x02001b24)" "$(rr 0x02001b60)"
printf "CCU: DE(600)=%s DE_BUS(60c)=%s\n" \
    "$(rr 0x02001600)" "$(rr 0x0200160c)"
printf "CCU: PLL_PERIPH0(020)=%s\n" \
    "$(rr 0x02001020)"

# DSI controller: 0x05450000, 512 bytes
dump_block 0x05450000 "DSI"  512

# D-PHY: 0x05451000, 288 bytes
dump_block 0x05451000 "DPHY" 288

# TCON LCD0: 0x05461000, 512 bytes
dump_block 0x05461000 "TCON" 512

# TCON TOP: 0x05460000, 48 bytes
dump_block 0x05460000 "TCON_TOP" 48

# DE2 Internal CCU: 0x05000000, 16 bytes
dump_block 0x05000000 "DE2_CCU" 16

# DE2 Global: 0x05100000, 0x010 bytes
printf "DE2_GLB[000] %s %s %s %s\n" \
    "$(rr 0x05100000)" "$(rr 0x05100004)" \
    "$(rr 0x05100008)" "$(rr 0x0510000c)"

# DE2 Blender: 0x05101000, 256 bytes
dump_block 0x05101000 "DE2_BLD" 256

# DE2 UI Channel 1: 0x05103000, 256 bytes
dump_block 0x05103000 "DE2_UI1" 256

# DE2 VI Channel 0: 0x05102000, 256 bytes
dump_block 0x05102000 "DE2_VI0" 256

# VEP sub-engines: FCE/BWS/LTI/PEAK/ASE
printf "VEP: FCE=%s BWS=%s LTI=%s PEAK=%s ASE=%s\n" \
    "$(rr 0x051A0000)" "$(rr 0x051A2000)" \
    "$(rr 0x051A4000)" "$(rr 0x051A6000)" \
    "$(rr 0x051A8000)"

# FCC enable + CCSC00
printf "FCC_EN=%s CCSC00[050]=%s %s %s %s\n" \
    "$(rr 0x051AA000)" \
    "$(rr 0x051AA050)" "$(rr 0x051AA054)" \
    "$(rr 0x051AA058)" "$(rr 0x051AA05c)"

# DCSC enable
printf "DCSC_EN=%s\n" "$(rr 0x051B0000)"

# CCSC01 (D1 layout): 0x051FA000, 256 bytes
dump_block 0x051FA000 "CCSC01" 256

# ---------------------------------------------------------------------------
# Restore original bus clock gate values
# ---------------------------------------------------------------------------
wr 0x02001b4c "0x$SAVED_B4C"
wr 0x02001b7c "0x$SAVED_B7C"
wr 0x02001abc "0x$SAVED_ABC"
wr 0x0200160c "0x$SAVED_60C"

echo "=== Done ==="
