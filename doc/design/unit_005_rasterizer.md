# UNIT-005: Rasterizer

## Purpose

Edge-walking rasterization engine

## Parent Requirements

- REQ-002 (Rasterizer)

## Implements Requirements

- REQ-002.01 (Flat Shaded Triangle)
- REQ-002.02 (Gouraud Shaded Triangle)
- REQ-005.02 (Depth Tested Triangle)
- REQ-003.01 (Textured Triangle)
- REQ-002.03 (Rasterization Algorithm)
- REQ-004.02 (Extended Precision Fragment Processing) — RGBA8 interpolation output promotion to 10.8

## Interfaces

### Provides

None

### Consumes

- INT-010 (GPU Register Map)

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
- Register state (TRI_MODE, FB_DRAW, FB_ZBUFFER)

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
6. **Memory Address**: Framebuffer and Z-buffer addresses use shift-add for y×640 (640 = 512 + 128) instead of multiplication

## Implementation

- `spi_gpu/src/render/rasterizer.sv`: Main implementation

## Verification

Formal testbenches:
- **VER-001** (`tb_rasterizer` — Verilator unit testbench; covers REQ-002.03 rasterization algorithm)
- **VER-010** through **VER-013** (golden image integration tests exercise the full rasterizer-to-framebuffer path)

- Verify edge function computation for known triangles (clockwise/counter-clockwise winding)
- Test bounding box clamping at screen edges (0, 639, 479)
- Verify barycentric interpolation produces correct colors at vertices and midpoints
- Test Z-buffer read-compare-write sequence with near/far values
- Verify RGB888-to-RGB565 conversion in framebuffer writes
- Test degenerate triangles (zero area, single-pixel, off-screen)
- Verify SRAM arbiter handshake (req/ack/ready protocol)
- VER-001 (Rasterizer Unit Testbench)
- VER-001 (Rasterizer Unit Testbench)
- VER-010 (Gouraud Triangle Golden Image Test)
- VER-001 (Rasterizer Unit Testbench)

## Design Notes

Migrated from speckit module specification.

**Unified clock update:** The rasterizer now operates at the unified 100 MHz `clk_core`, doubling pixel evaluation throughput compared to the previous 50 MHz design.
At one fragment evaluation per clock cycle in the inner edge-walking loop, the rasterizer achieves a peak rate of 100 million fragment evaluations per second.
Fragment output to the pixel pipeline (UNIT-006) is synchronous within the same 100 MHz clock domain, and downstream SRAM access through the arbiter (UNIT-007) incurs no CDC latency.
Effective sustained pixel output rate is approximately 25 Mpixels/sec after SRAM arbitration contention with display scanout, Z-buffer, and texture fetch (see INT-011 bandwidth budget).

**Burst-friendly access patterns:** The edge-walking algorithm emits fragments in scanline order (left-to-right within each row of the bounding box), producing sequential screen-space positions.
This sequential output enables the downstream pixel pipeline (UNIT-006) and SRAM arbiter (UNIT-007) to exploit SRAM burst write mode for framebuffer writes and burst read/write mode for Z-buffer accesses, improving effective SRAM throughput for runs of horizontally adjacent fragments.

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
