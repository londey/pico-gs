# UNIT-003: Register File

## Purpose

Stores GPU state and vertex data

## Implements Requirements

- REQ-001 (Basic Host Communication)
- REQ-015 (Memory Upload Interface)
- REQ-022 (Vertex Submission Protocol)
- REQ-029 (Memory Upload Interface)

## Interfaces

### Provides

- INT-010 (GPU Register Map)

### Consumes

None

### Internal Interfaces

- Receives commands from UNIT-002 (Command FIFO) via cmd_valid/cmd_rw/cmd_addr/cmd_wdata
- Outputs triangle vertex data to UNIT-004/UNIT-005 (Triangle Setup / Rasterizer) via tri_valid and vertex buses
- Outputs framebuffer configuration (fb_draw, fb_display) to UNIT-007 (SRAM Arbiter) and UNIT-008 (Display Controller)
- Outputs mode flags (gouraud, textured, z_test, z_write) to rasterizer pipeline
- Outputs clear_trigger/clear_color to framebuffer clear logic
- Outputs dither_enable/dither_pattern to UNIT-006 (Pixel Pipeline) for ordered dithering control
- Outputs color_grade_ctrl/lut_addr/lut_data to UNIT-008 (Display Controller) for color grading LUT
- Reads gpu_busy from rasterizer, vblank from display controller, fifo_depth from UNIT-002 for status register

## Design Description

### Inputs

| Signal | Width | Description |
|--------|-------|-------------|
| `clk` | 1 | System clock |
| `rst_n` | 1 | Active-low reset |
| `cmd_valid` | 1 | Command valid from FIFO |
| `cmd_rw` | 1 | 1=read, 0=write |
| `cmd_addr` | 7 | Register address |
| `cmd_wdata` | 64 | Write data |
| `gpu_busy` | 1 | GPU is currently rendering |
| `vblank` | 1 | Vertical blanking active |
| `fifo_depth` | 8 | Current command FIFO occupancy |

### Outputs

| Signal | Width | Description |
|--------|-------|-------------|
| `cmd_rdata` | 64 | Read data (combinational, addressed by cmd_addr) |
| `tri_valid` | 1 | One-cycle pulse when 3rd vertex submitted |
| `tri_x[0:2]` | 3x16 | Vertex X coordinates (12.4 fixed) |
| `tri_y[0:2]` | 3x16 | Vertex Y coordinates (12.4 fixed) |
| `tri_z[0:2]` | 3x25 | Vertex Z depth values |
| `tri_color[0:2]` | 3x32 | Vertex RGBA8888 colors |
| `tri_inv_area` | 16 | 1/area (0.16 fixed), CPU-provided |
| `mode_gouraud` | 1 | Gouraud shading enabled (TRI_MODE[0]) |
| `mode_textured` | 1 | Texture mapping enabled (TRI_MODE[1]) |
| `mode_z_test` | 1 | Z-test enabled (TRI_MODE[2]) |
| `mode_z_write` | 1 | Z-write enabled (TRI_MODE[3]) |
| `fb_draw` | 20 | Draw target address [31:12] |
| `fb_display` | 20 | Display source address [31:12] |
| `clear_color` | 32 | RGBA8888 clear color |
| `clear_trigger` | 1 | One-cycle clear command pulse |
| `dither_enable` | 1 | Ordered dithering enabled (DITHER_MODE[0]) |
| `dither_pattern` | 2 | Dither pattern selection (DITHER_MODE[3:2]) |
| `color_grade_enable` | 1 | Color grading LUT enabled (COLOR_GRADE_CTRL[0]) |
| `color_grade_swap` | 1 | One-cycle pulse to swap LUT banks (COLOR_GRADE_CTRL[1]) |
| `color_grade_reset_addr` | 1 | One-cycle pulse to reset LUT address pointer (COLOR_GRADE_CTRL[2]) |
| `color_grade_lut_select` | 2 | LUT select: 00=Red, 01=Green, 10=Blue (COLOR_GRADE_LUT_ADDR[7:6]) |
| `color_grade_lut_index` | 6 | LUT entry index (COLOR_GRADE_LUT_ADDR[5:0]) |
| `color_grade_lut_data` | 24 | RGB888 LUT entry data (COLOR_GRADE_LUT_DATA[23:0]) |
| `color_grade_lut_wr` | 1 | One-cycle pulse on COLOR_GRADE_LUT_DATA write |

### Internal State

- **vertex_count** [1:0]: Counts submitted vertices (0, 1, 2); resets to 0 after 3rd
- **vertex_x/y/z** [0:2]: Latched vertex positions for vertices 0-2
- **vertex_colors** [0:2]: Latched RGBA8888 colors for vertices 0-2
- **current_color** [31:0]: Color to apply to the next VERTEX write (default white)
- **current_inv_area** [15:0]: 1/area value to apply when triangle emitted
- **tri_mode** [7:0]: Mode flags register (bits [3:0] decoded to gouraud/textured/z_test/z_write)
- **dither_mode** [7:0]: Dither control register (bit 0 = enable, bits [3:2] = pattern)
- **color_grade_ctrl** [7:0]: Color grading control (bit 0 = enable, bit 1 = swap_banks pulse, bit 2 = reset_addr pulse)
- **color_grade_lut_addr** [7:0]: LUT address (bits [7:6] = LUT select, bits [5:0] = entry index)

**Register Address Map:**

| Address | Name | Access |
|---------|------|--------|
| 0x00 | COLOR | R/W |
| 0x01 | UV | R/W (deferred) |
| 0x02 | VERTEX | W (triggers on 3rd write) |
| 0x03 | INV_AREA | W |
| 0x04 | TRI_MODE | R/W |
| 0x08 | FB_DRAW | R/W |
| 0x09 | FB_DISPLAY | R/W |
| 0x0A | CLEAR_COLOR | R/W |
| 0x0B | CLEAR | W (pulse) |
| 0x10 | STATUS | R (busy, vblank, fifo_depth, vertex_count) |
| 0x32 | DITHER_MODE | R/W (enable, pattern) |
| 0x44 | COLOR_GRADE_CTRL | R/W (enable, swap_banks pulse, reset_addr pulse) |
| 0x45 | COLOR_GRADE_LUT_ADDR | R/W (LUT select, entry index) |
| 0x46 | COLOR_GRADE_LUT_DATA | W (RGB888 LUT entry, triggers write pulse) |
| 0x7F | ID | R (0x6702) |

### Algorithm / Behavior

**Vertex Submission State Machine:**
1. Host writes COLOR register to set the color for the next vertex
2. Host writes INV_AREA to set the reciprocal triangle area
3. Host writes VERTEX register with packed {Z[24:0], Y[15:0], X[15:0]}
4. On each VERTEX write: latch x/y/z/color into vertex_x/y/z/vertex_colors[vertex_count], increment vertex_count
5. On 3rd VERTEX write (vertex_count == 2): assert tri_valid for one cycle, latch all three vertices and inv_area onto the tri_* output buses, reset vertex_count to 0

**Register Write Logic:**
- All writes gated by cmd_valid && !cmd_rw
- CLEAR register (0x0B) generates a one-cycle clear_trigger pulse
- tri_valid and clear_trigger are self-clearing (deasserted next cycle)
- DITHER_MODE (0x32): Stores dither_mode register; outputs dither_enable (bit 0) and dither_pattern (bits [3:2]) to UNIT-006 (Pixel Pipeline). Reset value: 0x01 (enabled, blue noise pattern)
- COLOR_GRADE_CTRL (0x44): Stores color_grade_ctrl; bit 0 = enable (persistent), bit 1 = swap_banks (one-cycle pulse to UNIT-008), bit 2 = reset_addr (one-cycle pulse to UNIT-008). Pulse bits are self-clearing
- COLOR_GRADE_LUT_ADDR (0x45): Stores color_grade_lut_addr; bits [7:6] select the LUT (Red/Green/Blue), bits [5:0] select the entry index
- COLOR_GRADE_LUT_DATA (0x46): Write-only; outputs the 24-bit RGB888 data (bits [23:0]) and asserts a one-cycle color_grade_lut_wr pulse to UNIT-008 (Display Controller). The LUT address from 0x45 determines the target entry

**Register Read Logic (combinational):**
- STATUS register packs: {vblank, gpu_busy, fifo_depth[7:0], vertex_count[1:0], 4'b0}
- DITHER_MODE returns: {56'b0, dither_mode[7:0]}
- COLOR_GRADE_CTRL returns: {56'b0, color_grade_ctrl[7:0]} (pulse bits read as 0)
- COLOR_GRADE_LUT_ADDR returns: {56'b0, color_grade_lut_addr[7:0]}
- ID register returns constant 0x6702
- Undefined addresses return 0

## Implementation

- `spi_gpu/src/spi/register_file.sv`: Main implementation

## Verification

- Verify vertex submission: write 3 vertices, confirm tri_valid pulse and correct tri_* outputs
- Verify vertex_count wraps: submit 6 vertices (2 triangles), confirm 2 tri_valid pulses
- Verify color latching: change COLOR between vertices, confirm per-vertex colors on output
- Verify register read-back: write then read COLOR, TRI_MODE, FB_DRAW, FB_DISPLAY, CLEAR_COLOR
- Verify STATUS register: confirm gpu_busy, vblank, fifo_depth, vertex_count fields are correct
- Verify ID register: read 0x7F returns 0x6702
- Verify clear_trigger: write to CLEAR, confirm one-cycle pulse
- Verify DITHER_MODE: write then read back, confirm dither_enable and dither_pattern outputs match written value
- Verify DITHER_MODE reset: confirm reset value is 0x01 (enabled, blue noise)
- Verify COLOR_GRADE_CTRL: write enable bit, confirm color_grade_enable output; write swap_banks bit, confirm one-cycle pulse; write reset_addr bit, confirm one-cycle pulse
- Verify COLOR_GRADE_LUT_ADDR: write LUT select and index, confirm color_grade_lut_select and color_grade_lut_index outputs
- Verify COLOR_GRADE_LUT_DATA: write data, confirm 24-bit color_grade_lut_data output and one-cycle color_grade_lut_wr pulse
- Verify reset: all registers return to defaults (white color, address 0, modes disabled, dither enabled)

## Design Notes

Migrated from speckit module specification.

Registers DITHER_MODE (0x32), COLOR_GRADE_CTRL (0x44), COLOR_GRADE_LUT_ADDR (0x45), COLOR_GRADE_LUT_DATA (0x46) were added per INT-010 v5.0 and are now reflected in the Outputs, Internal State, Register Address Map, and Algorithm/Behavior sections above. DITHER_MODE outputs to UNIT-006 (Pixel Pipeline). COLOR_GRADE registers output to UNIT-008 (Display Controller). Note: the RTL implementation (register_file.sv) does not yet include these registers and needs to be updated to match this design.
