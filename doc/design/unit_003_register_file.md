# UNIT-003: Register File

## Purpose

Stores GPU state and vertex data

## Parent Requirements

- REQ-001 (GPU SPI Controller)

## Implements Requirements

- REQ-001.01 (Basic Host Communication)
- REQ-001.02 (Memory Upload Interface)
- REQ-001.05 (Vertex Submission Protocol)
- REQ-011.02 (Resource Constraints)

## Interfaces

### Provides

- INT-010 (GPU Register Map)

### Consumes

None

### Internal Interfaces

- Receives commands from UNIT-002 (Command FIFO) via cmd_valid/cmd_rw/cmd_addr/cmd_wdata.
  In Verilator simulation with `SIM_DIRECT_CMD` defined, these signals are driven by the injection path in gpu_top.sv (see UNIT-002), which bypasses UNIT-001 but presents the identical cmd_* bus to UNIT-003 — no change to register_file.sv itself is required.
- Outputs triangle vertex data to UNIT-004/UNIT-005 (Triangle Setup / Rasterizer) via tri_valid and vertex buses
- Outputs render target configuration (fb_config, including `fb_width_log2` and `fb_height_log2`) to UNIT-005 (Rasterizer), UNIT-006 (Pixel Pipeline), and UNIT-007 (Memory Arbiter)
- Outputs display configuration (fb_display, including `fb_display_width_log2` and `fb_line_double`) to UNIT-008 (Display Controller)
- Outputs mode flags (gouraud, textured, z_test, z_write, color_write, dither_en, alpha_blend, cull_mode, z_compare, stipple_en, alpha_test_func, alpha_ref) to rasterizer pipeline
- Outputs Z range clipping parameters (z_range_min, z_range_max) to pixel pipeline (UNIT-006)
- Outputs scissor rectangle (scissor_x, scissor_y, scissor_width, scissor_height) to pixel pipeline (UNIT-006)
- Outputs color combiner configuration (cc_mode, const_color) to color combiner (UNIT-010)
- Outputs mem_fill trigger and parameters to the SDRAM fill unit
- Outputs fb_display_sync trigger signals to UNIT-008 (Display Controller)
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
| `tri_x[0:2]` | 3x16 | Vertex X coordinates (S12.4 fixed) |
| `tri_y[0:2]` | 3x16 | Vertex Y coordinates (S12.4 fixed) |
| `tri_z[0:2]` | 3x16 | Vertex Z depth values (16-bit unsigned) |
| `tri_q[0:2]` | 3x16 | Vertex 1/W values (S3.12 fixed) |
| `tri_color0[0:2]` | 3x32 | Vertex COLOR0 RGBA8888 per vertex |
| `tri_color1[0:2]` | 3x32 | Vertex COLOR1 RGBA8888 per vertex |
| `tri_uv0[0:2]` | 3x32 | Vertex UV0 coordinates per vertex |
| `tri_uv1[0:2]` | 3x32 | Vertex UV1 coordinates per vertex |
| `mode_gouraud` | 1 | Gouraud shading enabled (RENDER_MODE[0]) |
| `mode_z_test` | 1 | Z-test enabled (RENDER_MODE[2]) |
| `mode_z_write` | 1 | Z-write enabled (RENDER_MODE[3]) |
| `mode_color_write` | 1 | Color buffer write enabled (RENDER_MODE[4]) |
| `mode_cull` | 2 | Backface culling mode (RENDER_MODE[6:5]) |
| `mode_alpha_blend` | 3 | Alpha blend mode (RENDER_MODE[9:7]) |
| `mode_dither_en` | 1 | Ordered dithering enabled (RENDER_MODE[10]) |
| `mode_dither_pattern` | 2 | Dither pattern (RENDER_MODE[12:11]) |
| `mode_z_compare` | 3 | Z comparison function (RENDER_MODE[15:13]) |
| `mode_stipple_en` | 1 | Stipple test enabled (RENDER_MODE[16]) |
| `mode_alpha_test` | 2 | Alpha test function (RENDER_MODE[18:17]) |
| `mode_alpha_ref` | 8 | Alpha test reference (RENDER_MODE[26:19]) |
| `z_range_min` | 16 | Z range clipping minimum (Z_RANGE[15:0]) |
| `z_range_max` | 16 | Z range clipping maximum (Z_RANGE[31:16]) |
| `stipple_pattern` | 64 | 8x8 stipple bitmask (STIPPLE_PATTERN[63:0]) |
| `fb_color_base` | 16 | Render target color base (FB_CONFIG[15:0], ×512 byte addr) |
| `fb_z_base` | 16 | Render target Z base (FB_CONFIG[31:16], ×512 byte addr) |
| `fb_width_log2` | 4 | Render surface width log2 (FB_CONFIG[35:32]) |
| `fb_height_log2` | 4 | Render surface height log2 (FB_CONFIG[39:36]) |
| `scissor_x` | 10 | Scissor X origin (FB_CONTROL[9:0]) |
| `scissor_y` | 10 | Scissor Y origin (FB_CONTROL[19:10]) |
| `scissor_width` | 10 | Scissor width (FB_CONTROL[29:20]) |
| `scissor_height` | 10 | Scissor height (FB_CONTROL[39:30]) |
| `mem_fill_trigger` | 1 | One-cycle pulse when MEM_FILL is written |
| `mem_fill_base` | 16 | Fill target base address (MEM_FILL[15:0], ×512) |
| `mem_fill_value` | 16 | Fill constant value (MEM_FILL[31:16]) |
| `mem_fill_count` | 20 | Fill word count (MEM_FILL[51:32]) |
| `fb_lut_addr` | 16 | LUT SDRAM base address (FB_DISPLAY[31:16]) |
| `fb_display_addr` | 16 | Display scanout base address (FB_DISPLAY[47:32]) |
| `fb_display_width_log2` | 4 | Display FB width log2 (FB_DISPLAY[51:48]) |
| `fb_line_double` | 1 | Line-double mode (FB_DISPLAY[1]) |
| `color_grade_enable` | 1 | Color grading LUT enabled (FB_DISPLAY[0]) |
| `cc_mode` | 64 | Color combiner mode (CC_MODE register) |
| `const_color` | 64 | Constant colors 0+1 packed (CONST_COLOR register) |
| `vsync_edge` | 1 | Input: vsync rising edge detector |
| `ts_mem_wr` | 1 | One-cycle pulse: write cycle counter to SDRAM |
| `ts_mem_addr` | 23 | SDRAM word address for timestamp write |
| `ts_mem_data` | 32 | Cycle counter value to write |

### Internal State

- **vertex_count** [1:0]: Counts submitted vertices (0, 1, 2); resets to 0 after kick
- **vertex_buf**: Latched X/Y/Z/Q/COLOR0/COLOR1/UV0/UV1 for up to 3 buffered vertices
- **current_color0** [63:0]: COLOR register value for next vertex write (default white)
- **current_uv01** [63:0]: UV0_UV1 register value for next vertex write
- **render_mode** [63:0]: RENDER_MODE register
- **z_range** [63:0]: Z_RANGE register (reset: Z_RANGE_MIN=0, Z_RANGE_MAX=0xFFFF)
- **stipple_pattern** [63:0]: STIPPLE_PATTERN register (reset: all ones)
- **fb_config** [63:0]: FB_CONFIG register
- **fb_display** [63:0]: FB_DISPLAY register
- **fb_control** [63:0]: FB_CONTROL register
- **cc_mode** [63:0]: CC_MODE register
- **const_color** [63:0]: CONST_COLOR register
- **tex0_cfg, tex1_cfg** [63:0]: TEX0_CFG, TEX1_CFG registers
- **cycle_counter** [31:0]: Frame-relative cycle counter (clk_core, resets to 0 on vsync rising edge)
- **vblank_prev** [0]: Previous vblank value for rising-edge detection

**Register Address Map:**

| Address | Name | Access |
|---------|------|--------|
| 0x00 | COLOR | R/W |
| 0x01 | UV0_UV1 | R/W |
| 0x06 | VERTEX_NOKICK | W (buffers vertex, no triangle emit) |
| 0x07 | VERTEX_KICK_012 | W (buffers vertex, emits triangle v[0],v[1],v[2]) |
| 0x08 | VERTEX_KICK_021 | W (buffers vertex, emits triangle v[0],v[2],v[1]) |
| 0x09 | VERTEX_KICK_RECT | W (two-corner rectangle emit) |
| 0x10 | TEX0_CFG | R/W |
| 0x11 | TEX1_CFG | R/W |
| 0x18 | CC_MODE | R/W |
| 0x19 | CONST_COLOR | R/W |
| 0x30 | RENDER_MODE | R/W |
| 0x31 | Z_RANGE | R/W |
| 0x32 | STIPPLE_PATTERN | R/W |
| 0x40 | FB_CONFIG | R/W |
| 0x41 | FB_DISPLAY | W (blocks until vsync) |
| 0x43 | FB_CONTROL | R/W |
| 0x44 | MEM_FILL | W (triggers fill operation) |
| 0x50 | PERF_TIMESTAMP | R/W |
| 0x70 | MEM_ADDR | R/W |
| 0x71 | MEM_DATA | R/W |
| 0x7F | ID | R (0x00000A00_00006702) |

### Algorithm / Behavior

**Vertex Submission State Machine:**

The register file maintains a 3-entry vertex ring buffer indexed by vertex_count.

1. Host writes COLOR register to set COLOR0/COLOR1 for the next vertex
2. Host writes UV0_UV1 register to set UV coordinates for the next vertex
3. Host writes a VERTEX register variant:
   - **VERTEX_NOKICK (0x06):** Latch position data with current COLOR/UV into vertex_buf[vertex_count & 2]; advance vertex_count
   - **VERTEX_KICK_012 (0x07):** Latch as above; assert tri_valid for one cycle; output vertex_buf entries as triangle (0,1,2); advance vertex_count
   - **VERTEX_KICK_021 (0x08):** Latch as above; assert tri_valid; output as (0,2,1) winding order
   - **VERTEX_KICK_RECT (0x09):** Use current and previous vertex as opposite corners; assert rect_valid

**Register Write Logic:**
- All writes gated by cmd_valid && !cmd_rw
- MEM_FILL (0x44): Generates a one-cycle mem_fill_trigger pulse; outputs fill parameters
- tri_valid and mem_fill_trigger are self-clearing (deasserted next cycle)
- **RENDER_MODE (0x30):** Stores render_mode register; all mode_* outputs are combinational decodes of the fields.
  Reset value: 0 (all modes disabled, DITHER_EN=0, no culling, no blending)
- **CC_MODE (0x18):** Stores cc_mode register; passed combinationally to UNIT-010 (Color Combiner).
  Two-stage combiner: cycle 0 fields [31:0], cycle 1 fields [63:32].
- **CONST_COLOR (0x19):** Stores const_color register; CONST0 in [31:0], CONST1/fog color in [63:32].
- **TEX0_CFG (0x10), TEX1_CFG (0x11):** Any write invalidates the corresponding texture cache in UNIT-006.
- **FB_DISPLAY (0x41):** Blocking register — write blocks the GPU pipeline until the next vsync, then applies atomically.
  Outputs fb_display_addr, fb_lut_addr, fb_display_width_log2, fb_line_double, color_grade_enable to UNIT-008.
  `fb_display_width_log2` drives the horizontal scaler source width in UNIT-008 (`source_width = 1 << fb_display_width_log2`).
  `fb_line_double` enables vertical line doubling in UNIT-008 (240 source rows output twice to fill 480 display lines).
  If COLOR_GRADE_ENABLE=1 and LUT_ADDR!=0, the hardware auto-loads the LUT from SDRAM during vblank.
- **FB_CONFIG (0x40):** Non-blocking render target switch.
  `fb_width_log2` drives the tiled address stride in UNIT-005 (Rasterizer) and UNIT-006 (Pixel Pipeline): stride = `1 << fb_width_log2` tiles per row.
  `fb_height_log2` drives the bounding box scissor upper bound in UNIT-005: Y clamp = `(1 << fb_height_log2) - 1`.
- **FB_CONTROL (0x43):** Scissor rectangle configuration.

**Cycle Counter:**
- `vblank_prev` tracks previous vblank level for rising-edge detection
- On vsync rising edge (`vblank && !vblank_prev`): reset `cycle_counter` to 0
- Otherwise: increment `cycle_counter` by 1 each `clk_core` cycle (saturates at 0xFFFFFFFF)
- Counter runs at 100 MHz (10 ns resolution), saturates after ~42.9 seconds

**PERF_TIMESTAMP Write (0x50):**
- DATA[22:0] is a 23-bit SDRAM word address (32-bit word granularity)
- Asserts `ts_mem_wr` for one cycle with `ts_mem_addr` = DATA[22:0] and `ts_mem_data` = cycle_counter
- gpu_top.sv latches the request and drives memory arbiter port 3 to write the 32-bit timestamp to SDRAM
- Fire-and-forget: command FIFO advances immediately; back-to-back writes overwrite the pending request

**Register Read Logic (combinational):**
- RENDER_MODE, Z_RANGE, STIPPLE_PATTERN, FB_CONFIG, FB_CONTROL, CC_MODE, CONST_COLOR: Return stored register value
- FB_DISPLAY: Write-only (blocking register, no read value; returns 0)
- PERF_TIMESTAMP returns: {32'd0, cycle_counter} (live instantaneous value)
- ID register returns constant 0x00000A00_00006702
- TEX0_CFG, TEX1_CFG: Return stored register values
- MEM_DATA: Return prefetched SDRAM dword
- Undefined addresses return 0

## Implementation

- `spi_gpu/src/spi/register_file.sv`: Main implementation

## Verification

Formal testbench: **VER-003** (`tb_register_file` — Verilator unit testbench).

- Verify vertex submission: write COLOR + UV + VERTEX_KICK_012 for 3 vertices; confirm tri_valid pulse and correct tri_* outputs
- Verify strip submission: write VERTEX_NOKICK for v0, v1 then VERTEX_KICK_012 for v2; confirm one tri_valid pulse
- Verify VERTEX_KICK_021 emits opposite winding order
- Verify color latching: change COLOR between vertices; confirm per-vertex colors on output
- Verify register read-back: write then read COLOR, CC_MODE, FB_CONFIG, CONST_COLOR, RENDER_MODE, Z_RANGE
- Verify ID register: read 0x7F returns 0x00000A00_00006702
- Verify MEM_FILL trigger: write MEM_FILL, confirm one-cycle mem_fill_trigger pulse with correct base/value/count
- Verify RENDER_MODE: write various combinations; confirm all mode_* outputs decode correctly
- Verify RENDER_MODE reset: confirm reset value is 0x00 (all flags disabled)
- Verify Z_RANGE reset: confirm reset value has Z_RANGE_MIN=0x0000, Z_RANGE_MAX=0xFFFF
- Verify STIPPLE_PATTERN reset: confirm reset value is 0xFFFFFFFF_FFFFFFFF (all bits set)
- Verify FB_CONFIG: write color_base, z_base, width_log2, height_log2; confirm all outputs
- Verify FB_CONTROL: write scissor rectangle; confirm scissor_x/y/width/height outputs
- Verify CC_MODE: write two-stage combiner configuration; confirm cc_mode output passes through
- Verify CONST_COLOR: write two constant colors; confirm const_color output
- Verify TEXn_CFG write triggers cache invalidation signal for sampler N
- Verify FB_DISPLAY blocks SPI pipeline until vsync; confirm outputs updated atomically
- Verify cycle_counter resets to 0 on vsync rising edge
- Verify cycle_counter increments once per clk_core cycle and saturates at 0xFFFFFFFF
- Verify PERF_TIMESTAMP write asserts ts_mem_wr pulse with correct addr and captured counter
- Verify PERF_TIMESTAMP read returns live cycle_counter value
- Verify reset: all registers return to defaults
- VER-003 (Register File Unit Testbench)
- VER-010 (Gouraud Triangle Golden Image Test)
- VER-011 (Depth-Tested Overlapping Triangles Golden Image Test)
- VER-012 (Textured Triangle Golden Image Test)
- VER-013 (Color-Combined Output Golden Image Test)
- The interactive Verilator simulator (UNIT-037) generalises the VER-010 through VER-013 injection approach into a live interactive tool.
  It drives cmd_valid/cmd_rw/cmd_addr/cmd_wdata via the `SIM_DIRECT_CMD` path in UNIT-002 and observes the display output tap signals produced downstream of UNIT-008; UNIT-003 itself is not modified.

## Design Notes

Migrated from speckit module specification.
