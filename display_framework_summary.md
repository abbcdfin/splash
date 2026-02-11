# Allwinner T113 Linux Display Framework Summary

## Overview
The Allwinner T113 SoC uses the Display Engine 2.0 (DE2) architecture for its display pipeline, which follows the Linux DRM (Direct Rendering Manager) framework with a component-based design.

## Master Component Architecture
### Primary Master Component
- **Driver**: `sun4i_drv.c` 
- **Compatible String**: `"allwinner,sun20i-d1-display-engine"`
- **Function**: Coordinates the entire display pipeline

### Component Framework Flow
1. **Device Tree Parsing**: The master component walks the device tree graph to discover connected display components
2. **Slave Components**: Includes mixer, TCON, DSI controller, etc.
3. **Binding Process**: 
   - Master calls `component_master_add_with_match()` to register master ops
   - Waits for all slave components to be probed and ready
   - Calls master bind function (`sun4i_drv_bind()`) 
   - Master bind calls `component_bind_all()` to bind all slave components

## Display Pipeline Structure
```
Master DRM Device (sun4i_drv.c)
├── CRTC (Integrated in Mixer for DE2)
├── Mixer/Backend (sun8i_mixer.c) - DEBE units
├── TCON Top/Bottom (sun8i_tcon_top.c, sun8i_tcon.c)
└── Slave Components (DSI, HDMI, etc.)
    └── Panel/Bridge Connector
```

## MIPI DSI Controller
### Driver: `sun6i_mipi_dsi.c`
- **Operation Mode**: Register-based programming without interrupts
- **Connection**: Connected to TCON via device tree graph endpoints
- **Implementation**: Uses the standard MIPI DSI stack without interrupt handling

### Endpoint Connection
- **DSI Output**: Connected to TCON through device tree endpoints
- **Device Tree Reference**: 
  ```
  dsi_in_tcon_lcd0: endpoint {
      remote-endpoint = <&tcon_lcd0_out_dsi>;
  }
  ```

## Plane Management
### Video Input (VI) Layers
- **Functions**: `sun8i_vi_layer_atomic_update()`, `sun8i_vi_layer_atomic_check()`
- **Register**: `drm_plane_helper_add()` with `sun8i_vi_layer_helper_funcs`

### User Interface (UI) Layers
- **Functions**: `sun8i_ui_layer_atomic_update()`, `sun8i_ui_layer_atomic_check()`
- **Register**: `drm_plane_helper_add()` with `sun8i_ui_layer_helper_funcs`

## Panel Support
### ILI9881C Panel Driver
- **Compatible String**: `"huadichuangxian,hd50004c30", "ilitek,ili9881c"`
- **Mode Flags**: `MIPI_DSI_MODE_VIDEO | MIPI_DSI_MODE_LPM` (supports both video and command modes)
- **Initialization**: Uses sequences defined in `hd50004c30_init[]` array

## Clock Infrastructure
### System Clocks (from `sunxi-d1s-t113.dtsi`)
- **Main CCU**: Contains clocks `CLK_BUS_DSI`, `CLK_MIPI_DSI`
- **Display CCU**: Separate clock controller for display components

### Display Chain Clocks
- **DSI Controller**: Gets clocks from main CCU (`CLK_BUS_MIPI_DSI`, `CLK_MIPI_DSI`)
- **TCON**: Gets TCON-specific clocks
- **Mixer**: Gets from display clock controller

## Interrupt Hierarchy
### Root Interrupt Controller
- **GIC**: Defined in ARM T113S DTSI with `interrupt-parent = <&gic>`
- **Function**: All peripherals inherit interrupt parent from root

### Device Tree Inheritance
- **No Direct DSI Interrupts**: The MIPI DSI controller implementation does not use interrupt handling
- **Interrupt Cells**: Defined as 3-cell format in GIC
- **Usage**: Other display components may use interrupts, but DSI controller does not

## Component Interaction
### Master-Slave Relationship
- **Master**: Controls overall DRM device creation and component orchestration
- **Slaves**: Individual display components (mixer, TCON, DSI, etc.)
- **Communication**: Through component framework messaging

### Pipeline Assembly
1. **Discovery**: Master component traverses device tree to find all display components
2. **Probing**: All components are probed individually 
3. **Binding**: Master bind function coordinates binding of all components in dependency order
4. **Operation**: Components work together through DRM atomic commit interface

## Panel Command Mode Support
The ILI9881C panel supports both video and command modes:
- **Video Mode**: Continuous display updates during active video period
- **Command Mode**: Control operations using MIPI DCS commands through LPM (Low Power Mode)
- **Configuration**: Enabled by `MIPI_DSI_MODE_LPM` flag in device tree
