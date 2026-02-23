# UNIT-003: Register File

## Purpose

Stores GPU state and vertex data

## Parent Requirements

- REQ-001 (GPU SPI Controller)

## Implements Requirements

- REQ-001.01 (Basic Host Communication)
- REQ-001.02 (Memory Upload Interface)
- REQ-001.05 (Vertex Submission Protocol)

## Interfaces

### Provides

- INT-010 (GPU Register Map)

### Consumes

None

### Internal Interfaces

- Receives commands from UNIT-002 (Command FIFO) via cmd_valid/cmd_rw/cmd_addr/cmd_wdata
- Outputs triangle vertex data to UNIT-004/UNIT-005 (Triangle Setup / Rasterizer) via tri_valid and vertex buses
- Outputs framebuffer configuration (fb_draw, fb_display) to UNIT-007 (SRAM Arbiter) and UNIT-008 (Display Controller)
- Outputs mode flags (gouraud, textured, z_test, z_write, color_write) to rasterizer pipeline
- Outputs Z range clipping parameters (z_range_min, z_range_max) to pixel pipeline (UNIT-006)
- Outputs color combiner configuration to color combiner (UNIT-010) — register layout preliminary, pending UNIT-010 design
- Outputs clear_trigger/clear_color to framebuffer clear logic
- Outputs dither_enable/dither_pattern to UNIT-006 (Pixel Pipeline) for ordered dithering control
- Outputs fb_display_sync/lut_dma_trigger signals to UNIT-008 (Display Controller) for LUT auto-load DMA
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
| `mode_gouraud` | 1 | Gouraud shading enabled (RENDER_MODE[0]) |
| `mode_textured` | 1 | Texture mapping enabled (RENDER_MODE[1]) |
| `mode_z_test` | 1 | Z-test enabled (RENDER_MODE[2]) |
| `mode_z_write` | 1 | Z-write enabled (RENDER_MODE[3]) |
| `mode_color_write` | 1 | Color buffer write enabled (RENDER_MODE[4]) |
| `z_range_min` | 16 | Z range clipping minimum (Z_RANGE[15:0]) |
| `z_range_max` | 16 | Z range clipping maximum (Z_RANGE[31:16]) |
| `fb_draw` | 20 | Draw target address [31:12] |
| `fb_display` | 20 | Display source address [31:12] |
| `clear_color` | 32 | RGBA8888 clear color |
| `clear_trigger` | 1 | One-cycle clear command pulse |
| `dither_enable` | 1 | Ordered dithering enabled (DITHER_MODE[0]) |
| `dither_pattern` | 2 | Dither pattern selection (DITHER_MODE[3:2]) |
| `fb_lut_addr` | 13 | LUT SRAM base address (FB_DISPLAY[18:6]) |
| `color_grade_enable` | 1 | Color grading LUT enabled (FB_DISPLAY[0]) |
| `lut_dma_trigger` | 1 | One-cycle pulse at vsync when LUT_ADDR != 0 |
| `combiner_cfg` | TBD | Color combiner configuration — field layout pending UNIT-010 design |
| `mat_color0` | 32 | Material color 0 (RGBA8888) for color combiner |
| `mat_color1` | 32 | Material color 1 (RGBA8888) for color combiner |
| `spi_cs_hold` | 1 | Keep SPI CS asserted for blocking write (FB_DISPLAY_SYNC) |
| `vsync_edge` | 1 | Input: vsync rising edge detector |

### Internal State

- **vertex_count** [1:0]: Counts submitted vertices (0, 1, 2); resets to 0 after 3rd
- **vertex_x/y/z** [0:2]: Latched vertex positions for vertices 0-2
- **vertex_colors** [0:2]: Latched RGBA8888 colors for vertices 0-2
- **current_color** [31:0]: Color to apply to the next VERTEX write (default white)
- **current_inv_area** [15:0]: 1/area value to apply when triangle emitted
- **tri_mode** [7:0]: Mode flags register (bits [3:0] decoded to gouraud/textured/z_test/z_write)
- **dither_mode** [7:0]: Dither control register (bit 0 = enable, bits [3:2] = pattern)
- **combiner_cfg**: Color combiner configuration — exact field layout pending UNIT-010 design; addresses 0x18–0x1F reserved per INT-010
- **mat_color0** [31:0]: Material color 0 (RGBA8888), used as a color combiner input
- **mat_color1** [31:0]: Material color 1 (RGBA8888), used as a color combiner input
- **fb_display** [31:0]: Framebuffer display address + LUT control
  - [31:19]: FB address >> 12 (4KiB aligned)
  - [18:6]: LUT address >> 12 (4KiB aligned, 0 = no LUT load)
  - [0]: Color grading enable
- **fb_display_sync_pending** [0]: FB_DISPLAY_SYNC write pending (blocking mode)
- **fb_display_sync_data** [31:0]: Latched FB_DISPLAY_SYNC data during blocking wait

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
| 0x31 | Z_RANGE | R/W (z_range_min, z_range_max) |
| 0x32 | DITHER_MODE | R/W (enable, pattern) |
| 0x18–0x1F | Color Combiner | R/W (reserved block — layout per INT-010 / UNIT-010, preliminary) |
| 0x47 | FB_DISPLAY_SYNC | W |
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
- Color Combiner registers (0x18–0x1F): Reserved address block for color combiner configuration.
  Exact register layout (field widths, reset values, input selector encoding) pending UNIT-010 design.
  MAT_COLOR0 and MAT_COLOR1 (RGBA8888 material colors) are within this block; other registers TBD.
  Outputs combiner configuration to UNIT-010 (Color Combiner).
- **FB_DISPLAY (0x09)**: Stores fb_display register (non-blocking):
  - [31:19]: Framebuffer address >> 12
  - [18:6]: LUT SRAM address >> 12 (0 = no LUT load)
  - [0]: Color grading enable
  - Outputs fb_lut_addr, color_grade_enable to UNIT-008
  - At vsync edge: if LUT_ADDR != 0, assert lut_dma_trigger for one cycle
- **FB_DISPLAY_SYNC (0x47)**: Blocking variant of FB_DISPLAY:
  - Latch write data to fb_display_sync_data
  - Set fb_display_sync_pending = 1
  - Assert spi_cs_hold = 1 (keeps SPI CS asserted, blocking host)
  - Wait for vsync_edge input
  - On vsync_edge: apply fb_display_sync_data to fb_display, clear pending, deassert spi_cs_hold
  - Trigger lut_dma if LUT_ADDR != 0

**Register Read Logic (combinational):**
- DITHER_MODE returns: {56'b0, dither_mode[7:0]}
- Color Combiner registers (0x18–0x1F): Read-back behavior per UNIT-010 design (TBD)
- FB_DISPLAY returns: {32'b0, fb_display[31:0]}
- FB_DISPLAY_SYNC: Write-only (blocking register, no read value)
- ID register returns constant 0x00000900_00006702
- Undefined addresses return 0

## Implementation

- `spi_gpu/src/spi/register_file.sv`: Main implementation

## Verification

- Verify vertex submission: write 3 vertices, confirm tri_valid pulse and correct tri_* outputs
- Verify vertex_count wraps: submit 6 vertices (2 triangles), confirm 2 tri_valid pulses
- Verify color latching: change COLOR between vertices, confirm per-vertex colors on output
- Verify register read-back: write then read COLOR, TRI_MODE, FB_DRAW, FB_DISPLAY, CLEAR_COLOR
- Verify ID register: read 0x7F returns 0x6702
- Verify clear_trigger: write to CLEAR, confirm one-cycle pulse
- Verify DITHER_MODE: write then read back, confirm dither_enable and dither_pattern outputs match written value
- Verify DITHER_MODE reset: confirm reset value is 0x01 (enabled, blue noise)
- **Verify FB_DISPLAY**: write with FB/LUT addresses + enable, confirm outputs; at vsync, confirm lut_dma_trigger if LUT_ADDR != 0
- **Verify FB_DISPLAY_SYNC**: write and confirm spi_cs_hold asserted; simulate vsync_edge, confirm cs_hold deasserted and fb_display updated; confirm lut_dma_trigger
- **Verify blocking timeout**: confirm FB_DISPLAY_SYNC blocks SPI transaction until vsync (max 16.67ms)
- Verify COLOR_GRADE_LUT_ADDR: write LUT select and index, confirm color_grade_lut_select and color_grade_lut_index outputs
- Verify COLOR_GRADE_LUT_DATA: write data, confirm 24-bit color_grade_lut_data output and one-cycle color_grade_lut_wr pulse
- Verify Z_RANGE: write then read back, confirm z_range_min and z_range_max outputs match written value
- Verify Z_RANGE reset: confirm reset value is 0x0000FFFF (min=0, max=0xFFFF)
- Verify mode_color_write output: write RENDER_MODE with bit 4 set/clear, confirm mode_color_write output tracks
- Verify color combiner registers (0x18–0x1F): write/read-back — specific test cases pending UNIT-010 design
- Verify reset: all registers return to defaults (white color, address 0, modes disabled, dither enabled)

## Design Notes

Migrated from speckit module specification.


