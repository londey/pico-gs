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
  - Interpolated UV coordinates per enabled texture unit (up to 2 sets: UV0, UV1), each component in Q4.12 signed fixed-point

**Note**: The rasterizer does **not** write directly to the framebuffer. All fragment output goes through the pixel pipeline (UNIT-006) for texture blending, dithering, and framebuffer conversion.

### Internal State

- Edge-walking state machine registers
- Edge function accumulators (e0, e1, e2) and row-start registers (e0_row, e1_row, e2_row) for incremental stepping
- Per-attribute derivative registers (dAttr/dx, dAttr/dy) for color0, color1, Z, UV0, UV1, and Q; computed once per triangle during setup
- Accumulated attribute values (attr_x) per active fragment position; stepped with additions in the inner loop
- Current scanline and span tracking

### Algorithm / Behavior

1. **Edge Setup** (SETUP → SETUP_2 → SETUP_3, 3 cycles): Compute edge coefficients A (11-bit), B (11-bit) in cycle 1; compute edge C coefficients (21-bit) serialized over 3 cycles using a shared pair of 11×11 multipliers; compute bounding box.
2. **Derivative Precomputation** (ITER_START → INIT_E1 → INIT_E2, 3 cycles): Evaluate edge functions at bounding box origin using the same shared multiplier pair (cold path, once per triangle); latch into e0/e1/e2 and row-start registers.
   Compute per-attribute derivatives using the precomputed `inv_area` from UNIT-004: for each attribute `f` at vertices v0, v1, v2, compute `df/dx = (f1-f0)*A01 + (f2-f0)*A02` and `df/dy = (f1-f0)*B01 + (f2-f0)*B02` (scaled by inv_area), using the shared multiplier pair in the same 3-cycle window.
   Initialize accumulated attribute values at the bounding box origin.
   Attributes subject to derivative precomputation: color0 (RGBA, 8-bit per channel), color1 (RGBA, 8-bit per channel), Z (16-bit unsigned), UV0 (Q4.12 per component), UV1 (Q4.12 per component), and Q/W (Q3.12).
3. **Pixel Test** (EDGE_TEST, per pixel): Check e0/e1/e2 ≥ 0 (inside triangle); no multiply required.
4. **Interpolation** (INTERPOLATE, per inside pixel): Add the precomputed dx derivatives to the accumulated attribute values when stepping right in X; add the dy derivatives when advancing to a new row.
   No per-pixel multiplies are required — all attribute interpolation is performed by incremental addition only.
   Output interpolated UV values as Q4.12 by extracting bits [31:16] of the Q4.28 accumulator (which discards the 16 guard bits, recovering the Q4.12 representation).
   Output interpolated color values by promoting the 8-bit accumulated UNORM to Q4.12 (see UNIT-006, Stage 3).
5. **Pixel Advance** (ITER_NEXT): Step to next pixel — add edge A coefficients when stepping right, add edge B coefficients when stepping to a new row.
6. **Scissor Bounds**: Bounding box is clamped to `[0, (1<<FB_CONFIG.WIDTH_LOG2)-1]` in X and `[0, (1<<FB_CONFIG.HEIGHT_LOG2)-1]` in Y, using the register values for the current render surface.

## Sub-Units

UNIT-005 decomposes internally into four functional sub-units, each implemented as a separate RTL module instantiated by the parent `rasterizer.sv` (DD-029).
Each sub-unit is documented in its own design unit file:

- [UNIT-005.01: Edge Setup](unit_005.01_edge_setup.md)
- [UNIT-005.02: Derivative Pre-computation](unit_005.02_derivative_precomputation.md)
- [UNIT-005.03: Attribute Accumulation](unit_005.03_attribute_accumulation.md)
- [UNIT-005.04: Iteration FSM](unit_005.04_iteration_fsm.md)

## Implementation

- `spi_gpu/src/render/rasterizer.sv`: Parent module — FSM, shared multiplier, vertex latches, edge setup (UNIT-005.01), sub-module instantiation.
- `spi_gpu/src/render/raster_deriv.sv`: Purely combinational derivative precomputation (UNIT-005.02 combinational path).
- `spi_gpu/src/render/raster_attr_accum.sv`: Attribute accumulators, derivative registers, output promotion (UNIT-005.02 latching / UNIT-005.03).
- `spi_gpu/src/render/raster_edge_walk.sv`: Iteration position, edge functions, fragment emission (UNIT-005.04).
- See DD-029 (UNIT-005 RTL Module Decomposition) for the architectural rationale.

## Verification

- **VER-001** (`tb_rasterizer` — Verilator unit testbench; covers REQ-002.03 rasterization algorithm)
- **VER-010** (Gouraud Triangle Golden Image Test)
- **VER-011** (Depth-Tested Overlapping Triangles Golden Image Test)
- **VER-012** (Textured Triangle Golden Image Test)
- **VER-013** (Color-Combined Output Golden Image Test)
- **VER-014** (Textured Cube Golden Image Test) — exercises the rasterizer across multiple triangles with varying depth and projection angles under perspective

Key verification points:
- Verify edge function computation for known triangles (clockwise/counter-clockwise winding)
- Test bounding box clamping at the configured surface boundary — `(1<<FB_CONFIG.WIDTH_LOG2)-1` in X and `(1<<FB_CONFIG.HEIGHT_LOG2)-1` in Y — not at a fixed 640×480
- Verify derivative precomputation: for a known triangle, confirm dColor/dx, dColor/dy, dZ/dx, dZ/dy, dUV/dx, dUV/dy, dQ/dx, dQ/dy match expected values derived from vertex attributes and inv_area
- Verify incremental interpolation: step across a rasterized triangle and confirm accumulated color0, color1, Z, UV0, UV1, Q/W values at each fragment match analytic values within rounding tolerance
- Verify the fragment output bus carries correct (x, y, z, color0, color1, uv0, uv1, q) values and valid/ready handshake operates correctly
- Test degenerate triangles (zero area, single-pixel, off-screen)

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

**Incremental interpolation (multiplier optimization):** Edge functions are linear: E(x+1,y) = E(x,y) + A and E(x,y+1) = E(x,y) + B.
The rasterizer exploits this by computing edge values and all attribute derivatives at the bounding box origin once per triangle (using multiplies in the ITER_START / INIT_E1 / INIT_E2 window), then stepping all edge and attribute accumulators incrementally with pure addition in the per-pixel inner loop.
No per-pixel multiplies are required for either edge testing or attribute interpolation.
See DD-024 for the rationale behind replacing per-pixel barycentric multiply-accumulate with precomputed derivative increments.
The 12 cold-path setup multipliers (6 for edge C coefficients, 6 for initial edge evaluation + derivative precomputation) are serialized through a shared pair of 11×11 multipliers over 6 cycles total (3 for setup, 3 for derivative init).
Since the SPI interface limits triangle throughput to one every ~72+ core cycles minimum, the extra setup cycles have zero impact on sustained performance.
This reduces total DSP usage to 3–4 MULT18X18D blocks (the shared setup pair, plus any fractional-multiply needed for Q promotion at output), freeing 13–14 blocks compared to the previous barycentric MAC approach, and leaving ample headroom for the color combiner (UNIT-010, 4–6 DSPs) and texture cache decoders (UNIT-006, 2–4 DSPs per BC decoder).

**Dual-texture + color combiner update:** The rasterizer interpolates two vertex colors (VER_COLOR0 and VER_COLOR1) per fragment, plus UV0, UV1, Z, and Q/W (perspective-correct denominator).
UV interpolation covers up to 2 sets (UV0, UV1); UV2_UV3 is removed.
Under the incremental interpolation scheme, adding color1 and Q/W interpolation costs only additional accumulator registers and derivative storage — no additional DSP multipliers in the inner loop.
Both interpolated vertex colors are output to UNIT-006 for use as VER_COLOR0 and VER_COLOR1 inputs to the color combiner (UNIT-010).
Q/W is output to UNIT-006 for perspective-correct UV division before texture lookup.

**Fragment output interface:** The rasterizer emits per-fragment data to UNIT-006 (Pixel Pipeline) via a valid/ready handshake (see DD-025).
The fragment bus carries: (x, y) screen coordinates in Q12.4; interpolated Z (16-bit unsigned); interpolated color0 and color1 (Q4.12 RGBA, 4 × 16-bit channels); interpolated UV0 and UV1 (Q4.12 per component, 16-bit signed each, packed as U[31:16]/V[15:0] in a 32-bit bus); and interpolated Q/W (Q3.12, 16-bit signed).
UV components use Q4.12 format throughout — sign bit, 3 integer bits, 12 fractional bits — matching the vertex input format from UNIT-003 and the accumulator output extraction `acc[31:16]` (top half of the Q4.28 accumulator).
The pixel pipeline (UNIT-006) must interpret `frag_u0[15:0]` and `frag_v0[15:0]` as Q4.12: sign bit at [15], integer bits at [14:12], fractional bits at [11:0].
The rasterizer does not access SDRAM directly; all framebuffer, Z-buffer, and texture memory accesses are the responsibility of UNIT-006 through UNIT-007.
