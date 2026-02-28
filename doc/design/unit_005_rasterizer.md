# UNIT-005: Rasterizer

## Purpose

Edge-walking rasterization engine

## Parent Requirements

- REQ-002 (Rasterizer)

## Implements Requirements

- REQ-002.01 (Flat Shaded Triangle)
- REQ-002.02 (Gouraud Shaded Triangle)
- REQ-002.03 (Rasterization Algorithm)
- REQ-003.01 (Textured Triangle)
- REQ-004.02 (Extended Precision Fragment Processing) — RGBA8 interpolation output promotion to 10.8
- REQ-005.02 (Depth Tested Triangle)
- REQ-005.04 (Enhanced Z-Buffer) — emits Z values for downstream Z-buffer operations
- REQ-005.05 (Triangle-Based Clearing) — rasterizes screen-covering clear triangles
- REQ-005.07 (Z-Buffer Operations) — generates per-fragment Z values for Z-buffer read/write
- REQ-011.01 (Performance Targets) — triangle throughput and fill rate are primary performance drivers
- REQ-002 (Rasterizer)
- REQ-005 (Blend / Frame Buffer Store)

## Interfaces

### Provides

None

### Consumes

- INT-010 (GPU Register Map)
- INT-011 (SDRAM Memory Layout)

### Internal Interfaces

- Receives triangle setup data from UNIT-004 (Triangle Setup) via setup_valid/downstream_ready handshake, including two vertex colors (color0, color1) per vertex
- Outputs fragment data to UNIT-006 (Pixel Pipeline) for SRAM access
- All internal interfaces operate in the unified 100 MHz `clk_core` domain (no CDC required)

## Design Description

### Inputs

- Triangle vertex data from UNIT-004 (Triangle Setup):
  - 3× vertex position (X, Y, Z)
  - 3× primary vertex color (RGBA8888 UNORM8 from COLOR register, used as VER_COLOR0)
  - 3× secondary vertex color (RGBA8888 UNORM8 from COLOR1 register, used as VER_COLOR1)
  - 3× UV coordinates per enabled texture unit (up to 2 sets: UV0, UV1)
- Register state (TRI_MODE, FB_CONFIG including FB_CONFIG.WIDTH_LOG2 and FB_CONFIG.HEIGHT_LOG2)

### Outputs

- Fragment data to UNIT-006 (Pixel Pipeline):
  - Fragment position (x, y) in screen coordinates
  - Interpolated Z depth (16-bit)
  - Interpolated primary vertex color (VER_COLOR0) in 10.8 fixed-point (4× 18-bit channels: R, G, B, A)
  - Interpolated secondary vertex color (VER_COLOR1) in 10.8 fixed-point (4× 18-bit channels: R, G, B, A)
  - Interpolated UV coordinates per enabled texture unit (up to 2 sets: UV0, UV1)

**Note**: The rasterizer does **not** write directly to the framebuffer. All fragment output goes through the pixel pipeline (UNIT-006) for texture blending, dithering, and framebuffer conversion.

### Internal State

- Edge-walking state machine registers
- Edge function accumulators (e0, e1, e2) and row-start registers (e0_row, e1_row, e2_row) for incremental stepping
- Barycentric weight registers (17-bit, 1.16 fixed point)
- Current scanline and span tracking

### Algorithm / Behavior

1. **Edge Setup** (SETUP → SETUP_2 → SETUP_3, 3 cycles): Compute edge coefficients A (11-bit), B (11-bit) in cycle 1; compute edge C coefficients (21-bit) serialized over 3 cycles using a shared pair of 11×11 multipliers; compute bounding box
2. **Initial Evaluation** (ITER_START → INIT_E1 → INIT_E2, 3 cycles): Evaluate edge functions at bounding box origin serialized over 3 cycles using the same shared multiplier pair (cold path, once per triangle); latch into e0/e1/e2 and row-start registers
3. **Pixel Test** (EDGE_TEST, per pixel): Check e0/e1/e2 ≥ 0 (inside triangle); if inside, compute 17-bit barycentric weights (1.16 fixed point) from edge values × inv_area
4. **Interpolation** (INTERPOLATE, per inside pixel): Compute both vertex colors (color0 and color1, each RGB888) and Z depth from barycentric weights using 17×8 and 17×16 multiplies (each fits in a single MULT18X18D). The secondary color (color1) interpolation uses the same barycentric weights as the primary color.
5. **Pixel Advance** (ITER_NEXT): Step to next pixel using **incremental addition only** — add edge A coefficients when stepping right, add edge B coefficients when stepping to a new row.
   No multiplies are needed in the per-pixel inner loop.
6. **Scissor Bounds**: Bounding box is clamped to `[0, (1<<FB_CONFIG.WIDTH_LOG2)-1]` in X and `[0, (1<<FB_CONFIG.HEIGHT_LOG2)-1]` in Y, using the register values for the current render surface.
7. **Memory Address**: Framebuffer and Z-buffer addresses use the 4×4 block-tiled formula from INT-011, with stride driven by `FB_CONFIG.WIDTH_LOG2` from the register file (UNIT-003).
   No fixed-width multiply is used; the stride computation is purely shift-based (`block_idx = (block_y << (WIDTH_LOG2 - 2)) | block_x`).

## Implementation

- `spi_gpu/src/render/rasterizer.sv`: Main implementation

## Verification

Formal testbenches:
- **VER-001** (`tb_rasterizer` — Verilator unit testbench; covers REQ-002.03 rasterization algorithm)
- **VER-010** through **VER-014** (golden image integration tests exercise the full rasterizer-to-framebuffer path)

- Verify edge function computation for known triangles (clockwise/counter-clockwise winding)
- Test bounding box clamping at the configured surface boundary — `(1<<FB_CONFIG.WIDTH_LOG2)-1` in X and `(1<<FB_CONFIG.HEIGHT_LOG2)-1` in Y — not at a fixed 640×480
- Verify barycentric interpolation produces correct colors at vertices and midpoints
- Test Z-buffer read-compare-write sequence with near/far values
- Verify RGB888-to-RGB565 conversion in framebuffer writes
- Test degenerate triangles (zero area, single-pixel, off-screen)
- Verify SRAM arbiter handshake (req/ack/ready protocol)
- VER-001 (Rasterizer Unit Testbench)
- VER-010 (Gouraud Triangle Golden Image Test)
- VER-011 (Depth-Tested Overlapping Triangles Golden Image Test)
- VER-012 (Textured Triangle Golden Image Test)
- VER-013 (Color-Combined Output Golden Image Test)
- VER-014 (Textured Cube Golden Image Test) — exercises the rasterizer across multiple triangles with varying depth and projection angles under perspective
- VER-014 (Textured Cube Golden Image Test)
- VER-010 (Gouraud Triangle Golden Image Test)
- VER-011 (Depth-Tested Overlapping Triangles Golden Image Test)
- VER-012 (Textured Triangle Golden Image Test)
- VER-001 (Rasterizer Unit Testbench)

The Verilator interactive simulator (REQ-010.02, `make sim-interactive`) extends the golden image harness concept to a live interactive tool.
It injects commands via `SIM_DIRECT_CMD` ports into the same register-file input path that VER-010–VER-014 use, but renders output live to an SDL3 window rather than comparing against a static reference image.
The interactive sim is a companion development tool, not a replacement for the golden image regression tests.

## Design Notes

Migrated from speckit module specification.

**Unified clock update:** The rasterizer now operates at the unified 100 MHz `clk_core`, doubling pixel evaluation throughput compared to the previous 50 MHz design.
At one fragment evaluation per clock cycle in the inner edge-walking loop, the rasterizer achieves a peak rate of 100 million fragment evaluations per second.
Fragment output to the pixel pipeline (UNIT-006) is synchronous within the same 100 MHz clock domain, and downstream SRAM access through the arbiter (UNIT-007) incurs no CDC latency.
Effective sustained pixel output rate is approximately 25 Mpixels/sec after SRAM arbitration contention with display scanout, Z-buffer, and texture fetch (see INT-011 bandwidth budget).

**Burst-friendly access patterns:** The edge-walking algorithm emits fragments in scanline order (left-to-right within each row of the bounding box), producing sequential screen-space positions within each 4×4 tile.
This sequential output enables the downstream pixel pipeline (UNIT-006) and SRAM arbiter (UNIT-007) to exploit SDRAM burst write mode for framebuffer writes and burst read/write mode for Z-buffer accesses, improving effective SDRAM throughput for runs of horizontally adjacent fragments.
The tile stride depends on `FB_CONFIG.WIDTH_LOG2`, which sets the number of tiles per row as `1 << (WIDTH_LOG2 - 2)`.

**Incremental edge stepping (multiplier optimization):** Edge functions are linear: E(x+1,y) = E(x,y) + A and E(x,y+1) = E(x,y) + B.
The rasterizer exploits this by computing edge values at the bounding box origin once per triangle (using multiplies in ITER_START), then stepping incrementally with pure addition in the per-pixel loop.
Barycentric weights are truncated to 17-bit (1.16 fixed point) so that downstream interpolation multiplies (17×8 for color, 17×16 for Z) each fit in a single ECP5 MULT18X18D block.
Additionally, the 12 cold-path setup multipliers (6 for edge C coefficients, 6 for initial edge evaluation) are serialized through a shared pair of 11×11 multipliers over 6 cycles total (3 for setup, 3 for initial evaluation).
Since the SPI interface limits triangle throughput to one every ~72+ core cycles minimum, the extra 4 setup cycles have zero impact on sustained performance.
This reduces total DSP usage from 47 to 17 MULT18X18D blocks (ECP5-25K has 28 available), leaving 11 blocks free for texture sampling and color combiner.

**Dual-texture + color combiner update:** The rasterizer now interpolates two vertex colors (VER_COLOR0 and VER_COLOR1) per fragment instead of one.
UV interpolation is reduced from up to 4 sets to up to 2 sets (UV0, UV1).
The additional color interpolation requires 3 extra MULT18X18D blocks (17×8 per R/G/B channel of color1), increasing per-pixel DSP usage modestly.
The reduction from 4 to 2 UV sets frees interpolation resources that offset this increase.
Both interpolated vertex colors are output to UNIT-006 for use as VER_COLOR0 and VER_COLOR1 inputs to the color combiner.
