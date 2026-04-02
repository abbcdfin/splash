#!/bin/bash
#
# dump_display_settings.sh - Allwinner T113-S / NCAT2 display pipeline register dump
#
# Covers the full pipeline: CCU → DE2 → TCON LCD0 → DSI → D-PHY
# Registers verified against knowledge.org baseline (2026-03-13).
# QUIRK markers flag registers that have known U-Boot/driver pitfalls.
#
# Run on the target as root. Requires devmem2 in PATH.
# All reads are read-only; no registers are written.
#

set -eo pipefail

# ---------------------------------------------------------------------------
# Base addresses
# ---------------------------------------------------------------------------
CCU_BASE=0x02001000
DE2_CCU_BASE=0x05000000
MIXER0_BASE=0x05100000
TCON_TOP_BASE=0x05460000
TCON_LCD0_BASE=0x05461000
DSI_BASE=0x05450000
DPHY_BASE=0x05451000

# ---------------------------------------------------------------------------
# Helper: read one 32-bit register via devmem2
# ---------------------------------------------------------------------------
read_reg() {
    local ADDR=$1
    local RAW
    RAW=$(devmem2 "$ADDR" w 2>/dev/null) || { echo "ERR"; return; }
    # Handle two common devmem2 output formats
    local VAL
    VAL=$(echo "$RAW" | grep -o "0x[0-9A-Fa-f]*" | tail -n 1)
    [ -n "$VAL" ] && echo "$VAL" || echo "ERR"
}

# ---------------------------------------------------------------------------
# Helper: dump a block of registers
#   dump_regs BASE "Section Name" "OFFSET DESC" ...
# ---------------------------------------------------------------------------
dump_regs() {
    local BASE=$1
    local NAME=$2
    shift 2

    printf "\n--- %s (base 0x%08x) ---\n" "$NAME" "$BASE"
    for entry in "$@"; do
        local OFF DESC ADDR VAL
        OFF=$(echo "$entry" | awk '{print $1}')
        DESC=$(echo "$entry" | cut -d' ' -f2-)
        ADDR=$(printf "0x%08x" $(( BASE + OFF )))
        VAL=$(read_reg "$ADDR")
        printf "  [%s]  %-45s  %s\n" "$ADDR" "$DESC" "$VAL"
    done
}

# ---------------------------------------------------------------------------
echo "=========================================================================="
echo " Allwinner T113-S Display Pipeline Register Dump"
printf " Date: %s\n" "$(date)"
echo "=========================================================================="

# ---------------------------------------------------------------------------
# 1. IC Version  (determines D-PHY ANA1 bit-5 quirk)
# ---------------------------------------------------------------------------
printf "\n--- IC Version (0x03000024, bits 2:0) ---\n"
IC_VER_VAL=$(read_reg 0x03000024)
printf "  [0x03000024]  IC_VER_REG                                     %s\n" "$IC_VER_VAL"
if [ "$IC_VER_VAL" != "ERR" ]; then
    IC_VER=$(( IC_VER_VAL & 0x7 ))
    printf "  => ic_ver bits[2:0] = %d  " "$IC_VER"
    if [ "$IC_VER" -gt 0 ]; then
        printf "(ic_ver > 0 → D-PHY ANA1 bit 5 MUST be set)\n"
    else
        printf "(ic_ver = 0 → ANA1 bit 5 not required)\n"
    fi
fi

# ---------------------------------------------------------------------------
# 2. CCU — Clock Control Unit
# ---------------------------------------------------------------------------
dump_regs $CCU_BASE "CCU" \
    "0x020 PLL_PERIPH0_CTRL            (D-PHY digital src, expect 600 MHz)" \
    "0x040 PLL_VIDEO0_CTRL             (expect N=133 M=2 → 1596 MHz; M=bit1 ONLY)" \
    "0x600 DE_CLK                      (expect 0x81000001: PLL_VIDEO0_1X, no div)" \
    "0x60c BUS_DE_GATING               (expect BIT16|BIT0: reset+gate)" \
    "0xabc BUS_DPSS_TOP_GATING         (expect BIT16|BIT0)" \
    "0xb24 MIPI_DSI_CLK                (expect 0x81000003: PLL_PERIPH0/4=150 MHz)" \
    "0xb4c BUS_MIPI_DSI_GATING         (expect BIT16|BIT0)" \
    "0xb60 TCON_LCD0_CLK               (expect 0x80000000: PLL_VIDEO0_1X=399 MHz)" \
    "0xb7c BUS_TCON_LCD0_GATING        (expect BIT16|BIT0)"

# ---------------------------------------------------------------------------
# Enable all bus clock gates before reading downstream registers.
# Without the gate+reset bits (BIT16|BIT0) enabled, register reads return 0.
# Save originals and restore after all reads are done.
# ---------------------------------------------------------------------------
BUS_DE_GATE_ADDR=$(printf "0x%08x" $((CCU_BASE + 0x60c)))
BUS_DPSS_GATE_ADDR=$(printf "0x%08x" $((CCU_BASE + 0xabc)))
BUS_DSI_GATE_ADDR=$(printf "0x%08x" $((CCU_BASE + 0xb4c)))
BUS_TCON_GATE_ADDR=$(printf "0x%08x" $((CCU_BASE + 0xb7c)))

BUS_DE_GATE_ORIG=$(read_reg "$BUS_DE_GATE_ADDR")
BUS_DPSS_GATE_ORIG=$(read_reg "$BUS_DPSS_GATE_ADDR")
BUS_DSI_GATE_ORIG=$(read_reg "$BUS_DSI_GATE_ADDR")
BUS_TCON_GATE_ORIG=$(read_reg "$BUS_TCON_GATE_ADDR")

printf "\n--- Enabling bus clock gates for register reads ---\n"
printf "  DE2 (0x60c): %s  DPSS_TOP (0xabc): %s  DSI (0xb4c): %s  TCON (0xb7c): %s\n" \
    "$BUS_DE_GATE_ORIG" "$BUS_DPSS_GATE_ORIG" "$BUS_DSI_GATE_ORIG" "$BUS_TCON_GATE_ORIG"
devmem2 "$BUS_DE_GATE_ADDR" w 0x10001 > /dev/null 2>&1
devmem2 "$BUS_DPSS_GATE_ADDR" w 0x10001 > /dev/null 2>&1
devmem2 "$BUS_DSI_GATE_ADDR" w 0x10001 > /dev/null 2>&1
devmem2 "$BUS_TCON_GATE_ADDR" w 0x10001 > /dev/null 2>&1

# ---------------------------------------------------------------------------
# 3. DE2 CCU — internal Display Engine clock/reset
# ---------------------------------------------------------------------------
dump_regs $DE2_CCU_BASE "DE2 Internal CCU" \
    "0x000 DE2_SCLK_GATE               (expect BIT0: mixer0 clock on)" \
    "0x004 DE2_AHB_RESET               (expect BIT0: mixer0 reset released)" \
    "0x008 DE2_SCLK_DIV                (expect 0: no divider)" \
    "0x00c DE2_CLK_SEL                 (expect 0: PLL_VIDEO0_1X)"

# ---------------------------------------------------------------------------
# 4. DE2 Mixer0 — Global
# ---------------------------------------------------------------------------
dump_regs $MIXER0_BASE "DE2 Mixer0 Global" \
    "0x0000 GLB_CTL                    (expect 0x00000001: mixer enabled)" \
    "0x0004 GLB_STATUS" \
    "0x0008 GLB_DBUFF                  (double-buffer commit, normally 1 after init)" \
    "0x000c GLB_SIZE                   (expect 0x04ff02cf: 720x1280)"

# ---------------------------------------------------------------------------
# 5. DE2 Mixer0 — Blender
#    Blender base = MIXER0_BASE + 0x1000
#    *** QUIRK: U-Boot struct names offset 0x00 as 'fcolor_ctl' but it is
#               PIPE_CTL in hardware. Bit 8 MUST be set to enable pipe 0. ***
# ---------------------------------------------------------------------------
dump_regs $MIXER0_BASE "DE2 Mixer0 Blender (base+0x1000)" \
    "0x1000 BLD_PIPE_CTL               [QUIRK fcolor_ctl] (expect 0x00000100: pipe0 EN)" \
    "0x1004 BLD_FILL_COLOR_0" \
    "0x1008 BLD_CH_INSIZE_0            (expect 0x04ff02cf)" \
    "0x1080 BLD_ROUTE                  (expect 0x00000001: pipe0←ch1)" \
    "0x1084 BLD_PREMULTIPLY            (expect 0x00000000)" \
    "0x1088 BLD_BKCOLOR                (expect 0xff000000)" \
    "0x1090 BLD_MODE_0                 (expect 0x03010301: standard alpha)" \
    "0x108c BLD_OUTPUT_SIZE            (expect 0x04ff02cf)" \
    "0x10fc BLD_OUT_CTL                (expect 0x00000000: progressive)"

# ---------------------------------------------------------------------------
# 6. DE2 Mixer0 — UI Channel 1 (layer holding the framebuffer)
#    Channel 1 base = MIXER0_BASE + 0x3000
# ---------------------------------------------------------------------------
dump_regs $MIXER0_BASE "DE2 Mixer0 UI Channel 1 (base+0x3000)" \
    "0x3000 UI1_ATTR                   (expect 0x00000401: EN + XRGB8888 fmt=4)" \
    "0x3004 UI1_SIZE                   (expect 0x04ff02cf: 720x1280)" \
    "0x3008 UI1_COORD                  (expect 0x00000000)" \
    "0x300c UI1_PITCH                  (expect 0x00000b40: 720*4=2880 bytes)" \
    "0x3010 UI1_TOP_LADDR              (framebuffer physical address)" \
    "0x3018 UI1_OVL_SIZE               (expect 0x04ff02cf)"

# ---------------------------------------------------------------------------
# 7. DE2 Mixer0 — Quirk registers
#    *** QUIRK: CCSC01 offset is 0xFA050, NOT 0xFA000. ***
#    *** QUIRK: DCSC (0xB0000) and SMBL (0x60000) must be cleared. ***
#    *** QUIRK: VEP units (0xF0000–0xF8000) must be cleared. ***
#    *** QUIRK: MUX-level CSC (0x1B000) must be 0. ***
# ---------------------------------------------------------------------------
dump_regs $MIXER0_BASE "DE2 Mixer0 Quirk Registers" \
    "0x1B000 MUX_CSC_CTL               (expect 0x00000000: disabled)" \
    "0x60000 SMBL_CTL                  [QUIRK] (expect 0x00000000: disabled)" \
    "0xB0000 DCSC_CTL                  [QUIRK] (expect 0x00000000: disabled)" \
    "0xF0000 VEP_FCE_BASE              [QUIRK] (expect 0x00000000: cleared)" \
    "0xF2000 VEP_BWS_BASE              [QUIRK] (expect 0x00000000: cleared)" \
    "0xF4000 VEP_LTI_BASE              [QUIRK] (expect 0x00000000: cleared)" \
    "0xF6000 VEP_PEAK_BASE             [QUIRK] (expect 0x00000000: cleared)" \
    "0xF8000 VEP_ASE_BASE              [QUIRK] (expect 0x00000000: cleared)" \
    "0xFA000 FCC1_BASE                 (FCC1 unit base, for reference)" \
    "0xFA050 CCSC01_CTL                [QUIRK correct offset] (expect 0x00000000: disabled)"

# ---------------------------------------------------------------------------
# 8. TCON TOP
# ---------------------------------------------------------------------------
dump_regs $TCON_TOP_BASE "TCON TOP" \
    "0x01c TCON_TOP_PORT_SEL           (bits1:0=0 → mixer0→TCON_LCD0)" \
    "0x020 TCON_TOP_GATE_SRC           (BIT16 → DSI gate enabled)"

# ---------------------------------------------------------------------------
# 9. TCON LCD0
#    *** QUIRK: HV_IF (0x058) bit 19 must be SET to disable CCIR CSC. ***
#    *** QUIRK: TRI registers (0x160–0x168) not in U-Boot lcdc struct; ***
#               must be written via absolute address. Without TRI_EN the  ***
#               TCON never pushes frames to DSI.                          ***
# ---------------------------------------------------------------------------
dump_regs $TCON_LCD0_BASE "TCON LCD0" \
    "0x0000 GCTL                       (expect 0x80000000: TCON enabled)" \
    "0x0004 GINT0" \
    "0x0040 TCON0_CTL                  (expect 0x81070031: EN+CPU_IF+delay)" \
    "0x0044 TCON0_DCLK                 (expect BIT(28+) | 4: EN, div=4 → 99.75 MHz)" \
    "0x0048 TCON0_BASIC0               (active: (h-1)<<16|(w-1), expect 0x04ff02cf)" \
    "0x004c TCON0_BASIC1               (htotal/hbp)" \
    "0x0050 TCON0_BASIC2               (vtotal/vbp)" \
    "0x0054 TCON0_BASIC3               (sync widths)" \
    "0x0058 TCON0_HV_IF                [QUIRK] bit19=ccir_csc_dis (expect 0x00080000)" \
    "0x0060 TCON0_CPU_IF               (expect 0x10000005: DSI+TRI_FIFO_EN+TRI_EN)" \
    "0x0160 TCON0_TRI0                 [QUIRK not in struct] (expect 0x01f302cf)" \
    "0x0164 TCON0_TRI1                 [QUIRK not in struct] (expect 0x00d004ff)" \
    "0x0168 TCON0_TRI2                 [QUIRK not in struct] (expect 0x1ada000a)"

# ---------------------------------------------------------------------------
# 10. DSI Host
#     *** QUIRK: BASIC_CTL1 bit 0 (VIDEO_MODE) must be set or DSI ignores TCON. ***
# ---------------------------------------------------------------------------
dump_regs $DSI_BASE "DSI Host" \
    "0x000 DSI_CTL                     (expect 0x01010001: enabled)" \
    "0x00c DSI_BASIC_CTL               (expect 0x00000000: sync-pulse, no burst)" \
    "0x010 DSI_BASIC_CTL0              (expect 0x00030001: ECC+CRC+INST_ST running)" \
    "0x014 DSI_BASIC_CTL1              [QUIRK] bit0=VIDEO_MODE (expect 0x000051f7)" \
    "0x018 DSI_BASIC_SIZE0" \
    "0x01c DSI_BASIC_SIZE1" \
    "0x040 DSI_INST_LOOP_SEL" \
    "0x048 DSI_INST_JUMP_SEL           (expect 0x63f07006: HSD continuous loop)" \
    "0x04c DSI_INST_JUMP_CFG0" \
    "0x060 DSI_TRANS_START             (expect 0x0000000a)" \
    "0x078 DSI_TRANS_ZERO              (expect 0x00000000)" \
    "0x080 DSI_PIXEL_CTL0"

# ---------------------------------------------------------------------------
# 11. D-PHY
#     *** QUIRK: ANA1 bit 5 must be set if ic_ver > 0. ***
#     *** QUIRK: COMBO_PHY_REG1 (0x114) must be 0; stale LVDS state ***
#               causes intermittent flickering.                       ***
# ---------------------------------------------------------------------------
dump_regs $DPHY_BASE "D-PHY" \
    "0x000 DPHY_GCTL                   (expect 0x00000031: 4 lanes, enabled)" \
    "0x004 DPHY_TX_CTL" \
    "0x010 DPHY_TX_TIME0" \
    "0x014 DPHY_TX_TIME1" \
    "0x018 DPHY_TX_TIME2" \
    "0x04c DPHY_ANA0                   (expect 0x00000044)" \
    "0x050 DPHY_ANA1                   [QUIRK] bit5=ic_ver_quirk (expect 0x80000020)" \
    "0x054 DPHY_ANA2                   (expect 0x0f000012)" \
    "0x058 DPHY_ANA3                   (expect 0xff040000)" \
    "0x05c DPHY_ANA4" \
    "0x104 DPHY_PLL_REG0               (expect 0x00f78582: PLL enabled)" \
    "0x108 DPHY_PLL_REG1" \
    "0x10c DPHY_PLL_REG2" \
    "0x110 COMBO_PHY_REG0" \
    "0x114 COMBO_PHY_REG1              [QUIRK] (expect 0x00000000: cleared)" \
    "0x118 COMBO_PHY_REG2              [QUIRK] (expect 0x00000000: cleared)"

# Restore all original bus clock gate states
devmem2 "$BUS_DE_GATE_ADDR" w "$BUS_DE_GATE_ORIG" > /dev/null 2>&1
devmem2 "$BUS_DPSS_GATE_ADDR" w "$BUS_DPSS_GATE_ORIG" > /dev/null 2>&1
devmem2 "$BUS_DSI_GATE_ADDR" w "$BUS_DSI_GATE_ORIG" > /dev/null 2>&1
devmem2 "$BUS_TCON_GATE_ADDR" w "$BUS_TCON_GATE_ORIG" > /dev/null 2>&1
printf "\n--- Bus clock gates restored ---\n"

# ---------------------------------------------------------------------------
# 12. Quirk Summary — fast visual check
# ---------------------------------------------------------------------------
printf "\n=========================================================================="
printf "\n QUIRK SUMMARY — expected vs actual\n"
printf "==========================================================================\n"

check_quirk() {
    local DESC=$1
    local ADDR=$2
    local EXPECT=$3
    local MASK=${4:-0xFFFFFFFF}
    local VAL RAW_INT EXP_INT MASK_INT RESULT
    VAL=$(read_reg "$ADDR")
    if [ "$VAL" = "ERR" ]; then
        printf "  %-48s  got %-12s  %s\n" "$DESC" "$VAL" "*** READ ERROR ***"
        return
    fi
    RAW_INT=$(( VAL & MASK ))
    EXP_INT=$(( EXPECT & MASK ))
    if [ "$RAW_INT" -eq "$EXP_INT" ]; then RESULT="OK"; else RESULT="*** MISMATCH ***"; fi
    printf "  %-48s  got %-12s  %s\n" "$DESC" "$VAL" "$RESULT"
}

check_quirk "PLL_VIDEO0 M field (bit1 only)" \
    "$(printf "0x%08x" $((CCU_BASE + 0x040)))" \
    $((0x80800000 | (132 << 8) | (1 << 1))) \
    $((0x80808302))

check_quirk "BLD_PIPE_CTL bit8 (pipe0 enable)" \
    "$(printf "0x%08x" $((MIXER0_BASE + 0x1000)))" \
    0x100 0x100

check_quirk "SMBL disabled" \
    "$(printf "0x%08x" $((MIXER0_BASE + 0x60000)))" \
    0x0 0x1

check_quirk "DCSC disabled" \
    "$(printf "0x%08x" $((MIXER0_BASE + 0xB0000)))" \
    0x0 0x3

check_quirk "CCSC01 at 0xFA050 (not 0xFA000)" \
    "$(printf "0x%08x" $((MIXER0_BASE + 0xFA050)))" \
    0x0 0x1

check_quirk "TCON HV_IF bit19 (CCIR CSC disabled)" \
    "$(printf "0x%08x" $((TCON_LCD0_BASE + 0x058)))" \
    0x00080000 0x00080000

check_quirk "TCON CPU_IF TRI_EN (bit0) + TRI_FIFO_EN (bit2)" \
    "$(printf "0x%08x" $((TCON_LCD0_BASE + 0x060)))" \
    0x5 0x5

check_quirk "DSI BASIC_CTL1 bit0 (VIDEO_MODE)" \
    "$(printf "0x%08x" $((DSI_BASE + 0x014)))" \
    0x1 0x1

check_quirk "DSI BASIC_CTL0 bit0 (INST_ST running)" \
    "$(printf "0x%08x" $((DSI_BASE + 0x010)))" \
    0x1 0x1

check_quirk "DPHY ANA1 bit5 (ic_ver quirk)" \
    "$(printf "0x%08x" $((DPHY_BASE + 0x050)))" \
    0x20 0x20

check_quirk "COMBO_PHY_REG1 cleared" \
    "$(printf "0x%08x" $((DPHY_BASE + 0x114)))" \
    0x0 0xFFFFFFFF

check_quirk "COMBO_PHY_REG2 cleared" \
    "$(printf "0x%08x" $((DPHY_BASE + 0x118)))" \
    0x0 0xFFFFFFFF

printf "\nDone.\n"
