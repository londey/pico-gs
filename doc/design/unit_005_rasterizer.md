# UNIT-005: Rasterizer

## Purpose

Edge-walking rasterization engine

## Implements Requirements

- REQ-003 (Flat Shaded Triangle)
- REQ-004 (Gouraud Shaded Triangle)
- REQ-005 (Depth Tested Triangle)
- REQ-006 (Textured Triangle)
- REQ-023 (Rasterization Algorithm)
- REQ-134 (Extended Precision Fragment Processing) — RGBA8 interpolation output promotion to 10.8

## Interfaces

### Provides

None

### Consumes

- INT-010 (GPU Register Map)

### Internal Interfaces

- Receives triangle setup data from UNIT-004 (Triangle Setup) via setup_valid/downstream_ready handshake
- Outputs fragment data to UNIT-006 (Pixel Pipeline) for SRAM access
- All internal interfaces operate in the unified 100 MHz `clk_core` domain (no CDC required)

## Design Description

### Inputs

- Triangle vertex data from UNIT-004 (Triangle Setup):
  - 3× vertex position (X, Y, Z)
  - 3× vertex color (RGBA8 — ABGR8888 from COLOR register)
  - 3× UV coordinates per enabled texture unit (up to 4 sets)
- Register state (TRI_MODE, FB_DRAW, FB_ZBUFFER)

### Outputs

- Fragment data to UNIT-006 (Pixel Pipeline):
  - Fragment position (x, y) in screen coordinates
  - Interpolated Z depth (16-bit)
  - Interpolated vertex color in 10.8 fixed-point (4× 18-bit channels: R, G, B, A)
  - Interpolated UV coordinates per enabled texture unit (up to 4 sets)

**Note**: The rasterizer does **not** write directly to the framebuffer. All fragment output goes through the pixel pipeline (UNIT-006) for texture blending, dithering, and framebuffer conversion.

### Internal State

- Edge-walking state machine registers
- Edge function accumulators (e0, e1, e2) and row-start registers (e0_row, e1_row, e2_row) for incremental stepping
- Barycentric weight registers (17-bit, 1.16 fixed point)
- Current scanline and span tracking

### Algorithm / Behavior

1. **Edge Setup** (SETUP, 1 cycle): Compute edge coefficients A (11-bit), B (11-bit), C (21-bit) and bounding box
2. **Initial Evaluation** (ITER_START, 1 cycle): Evaluate edge functions at bounding box origin using multiplies (cold path, once per triangle); latch into e0/e1/e2 and row-start registers
3. **Pixel Test** (EDGE_TEST, per pixel): Check e0/e1/e2 ≥ 0 (inside triangle); if inside, compute 17-bit barycentric weights (1.16 fixed point) from edge values × inv_area
4. **Interpolation** (INTERPOLATE, per inside pixel): Compute vertex color (RGB888) and Z depth from barycentric weights using 17×8 and 17×16 multiplies (each fits in a single MULT18X18D)
5. **Pixel Advance** (ITER_NEXT): Step to next pixel using **incremental addition only** — add edge A coefficients when stepping right, add edge B coefficients when stepping to a new row.
   No multiplies are needed in the per-pixel inner loop.
6. **Memory Address**: Framebuffer and Z-buffer addresses use shift-add for y×640 (640 = 512 + 128) instead of multiplication

## Implementation

- `spi_gpu/src/render/rasterizer.sv`: Main implementation

## Verification

- Verify edge function computation for known triangles (clockwise/counter-clockwise winding)
- Test bounding box clamping at screen edges (0, 639, 479)
- Verify barycentric interpolation produces correct colors at vertices and midpoints
- Test Z-buffer read-compare-write sequence with near/far values
- Verify RGB888-to-RGB565 conversion in framebuffer writes
- Test degenerate triangles (zero area, single-pixel, off-screen)
- Verify SRAM arbiter handshake (req/ack/ready protocol)

## Design Notes

Migrated from speckit module specification.

**v2.0 unified clock update:** The rasterizer now operates at the unified 100 MHz `clk_core`, doubling pixel evaluation throughput compared to the previous 50 MHz design.
At one fragment evaluation per clock cycle in the inner edge-walking loop, the rasterizer achieves a peak rate of 100 million fragment evaluations per second.
Fragment output to the pixel pipeline (UNIT-006) is synchronous within the same 100 MHz clock domain, and downstream SRAM access through the arbiter (UNIT-007) incurs no CDC latency.
Effective sustained pixel output rate is approximately 25 Mpixels/sec after SRAM arbitration contention with display scanout, Z-buffer, and texture fetch (see INT-011 bandwidth budget).

**Burst-friendly access patterns:** The edge-walking algorithm emits fragments in scanline order (left-to-right within each row of the bounding box), producing sequential screen-space positions.
This sequential output enables the downstream pixel pipeline (UNIT-006) and SRAM arbiter (UNIT-007) to exploit SRAM burst write mode for framebuffer writes and burst read/write mode for Z-buffer accesses, improving effective SRAM throughput for runs of horizontally adjacent fragments.

**Incremental edge stepping (multiplier optimization):** Edge functions are linear: E(x+1,y) = E(x,y) + A and E(x,y+1) = E(x,y) + B.
The rasterizer exploits this by computing edge values at the bounding box origin once per triangle (using multiplies in ITER_START), then stepping incrementally with pure addition in the per-pixel loop.
Barycentric weights are truncated to 17-bit (1.16 fixed point) so that downstream interpolation multiplies (17×8 for color, 17×16 for Z) each fit in a single ECP5 MULT18X18D block.
This reduces total DSP usage from 47 to 27 MULT18X18D blocks (ECP5-25K has 28 available).
