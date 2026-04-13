# UNIT-005: Rasterizer

## Purpose

Incremental derivative-based rasterization engine with internal perspective correction.

## Implements Requirements

- REQ-002.02 (Gouraud Shaded Triangle)
- REQ-002.03 (Rasterization Algorithm)
- REQ-003.01 (Textured Triangle)
- REQ-004.02 (Extended Precision Fragment Processing) — RGBA8 interpolation output promotion to Q4.12
- REQ-005.02 (Depth Tested Triangle)
- REQ-005.04 (Enhanced Z-Buffer) — emits Z values for downstream Z-buffer operations; Hi-Z tile rejection reduces unnecessary fragment emission
- REQ-005.07 (Z-Buffer Operations) — generates per-fragment Z values for Z-buffer read/write; Hi-Z metadata lookup provides tile-level pre-rejection
- REQ-011.01 (Performance Targets) — triangle throughput and fill rate are primary performance drivers; Hi-Z rejection reduces downstream pipeline load
- REQ-002 (Rasterizer)
- REQ-011.02 (Resource Constraints)

## Interfaces

### Provides

None

### Consumes

- INT-010 (GPU Register Map)
- INT-011 (SDRAM Memory Layout)

### Internal Interfaces

- Receives triangle setup data from UNIT-005.01 (Triangle Setup) via setup_valid/downstream_ready handshake, including three vertex positions, two sets of vertex colors (color0, color1), perspective-correct Q/W at each vertex, and S/T projected texture coordinates
- Outputs fragment data to UNIT-006 (Pixel Pipeline) via frag_valid/frag_ready handshake
- All internal interfaces operate in the unified 100 MHz `clk_core` domain (no CDC required)

## Pipeline Substage Scope

UNIT-005 spans two substages of the Render Pipeline as defined in ARCHITECTURE.md:

- **Triangle Setup** — validates the triangle, computes edge coefficients and attribute derivatives, and performs backface culling (UNIT-005.01 through UNIT-005.03).
- **Block Pipeline** — walks the triangle's bounding box in 4×4 tile order, performs Hi-Z tile rejection (UNIT-005.06), tests edge coverage per tile, and interpolates per-fragment attributes before emission to the Pixel Pipeline.
  The Block Pipeline's Z Tile Load and Color Tile Load prefetches are initiated by UNIT-006 in response to fragment handshake signals from UNIT-005.

UNIT-006 (Pixel Pipeline) receives the per-fragment output of the Block Pipeline and executes the Pixel Pipeline substage (stipple test, depth range clip, early Z-test, texture sampling, color combining, dithering, and framebuffer write).

## Design Description

### Inputs

Triangle vertex data from UNIT-005.01 (Triangle Setup):

- 3× vertex position (X, Y, Z), screen-space integer coordinates
- 3× primary vertex color (RGBA8888 UNORM8 from COLOR register, used as VER_COLOR0)
- 3× secondary vertex color (RGBA8888 UNORM8 from COLOR1 register, used as VER_COLOR1)
- 3× Q/W value per vertex (Q3.12 signed, perspective-correct denominator)
- 3× S0/T0 projected texture coordinates per vertex (Q4.12 signed, S=U/W, T=V/W), when texture unit 0 is enabled
- 3× S1/T1 projected texture coordinates per vertex (Q4.12 signed), when texture unit 1 is enabled
- Register state (TRI_MODE, FB_CONFIG including FB_CONFIG.WIDTH_LOG2 and FB_CONFIG.HEIGHT_LOG2)

### Outputs

Fragment data to UNIT-006 (Pixel Pipeline):

- Fragment position (x, y) in screen coordinates (UQ12.0 integer)
- Interpolated Z depth (16-bit unsigned)
- Interpolated primary vertex color (VER_COLOR0) in UNORM8 (4× 8-bit channels: R, G, B, A), clamped from Q4.12 accumulator output
- Interpolated secondary vertex color (VER_COLOR1) in UNORM8 (4× 8-bit channels: R, G, B, A), clamped from Q4.12 accumulator output
- Interpolated perspective-correct UV coordinates per enabled texture unit (up to 2 sets: UV0, UV1), each component in Q4.12 signed fixed-point — these are true U, V coordinates, not S/T projections
- Per-pixel LOD estimate (frag_lod) in UQ4.4 unsigned fixed-point, derived from CLZ on the interpolated Q/W value; UNIT-011 (Texture Sampler) adds TEXn_MIP_BIAS to form the final mip level

**Note**: The rasterizer does not write directly to the framebuffer.
All fragment output goes through the pixel pipeline (UNIT-006) for early Z-test, texture dispatch to UNIT-011, color combining, dithering, and framebuffer conversion.

### Internal State

- Triangle setup reciprocal module (`raster_recip_area.sv`): 1 DP16KD in 36×512 mode, 9-bit CLZ index, UQ1.17 seed + UQ0.17 delta linear interpolation, signed input with CLZ on 22-bit magnitude; produces UQ4.14 inv_area (18-bit); optional compile-time Newton-Raphson refinement (1 MULT18X18D, 2-3 extra cycles)
- Per-pixel 1/Q reciprocal module (`raster_recip_q.sv`): 1 DP16KD in 18×1024 mode, 10-bit CLZ index, UQ1.17 entries, unsigned input only; 2-cycle latency (BRAM read + MULT18X18D interpolation); produces UQ4.14 output (18-bit)
- **Hi-Z metadata store** (`raster_hiz_meta.sv`): 8 DP16KD blocks in 36×512 mode, storing 16,384 tile metadata entries packed 4 per 36-bit word; each 9-bit entry holds `min_z = tile_min_z[15:7]` (9-bit truncated minimum Z); sentinel `9'h1FF` means no Z-write since last clear; the 14-bit tile index is decoded as `tile_index[13:11]` → block select, `tile_index[10:2]` → word address, `tile_index[1:0]` → slot within word; all 8 blocks share the same address bus and reset to sentinel in 512 cycles (fast-clear path)
- Setup-iteration overlap FIFO: compile-time configurable depth (default 2) register-based FIFO holding complete triangle setup results (~730 bits: edge coefficients A/B/C × 3, bbox min/max, inv_area, vertex attributes); allows setup of triangle N+1 to overlap with iteration of triangle N
- Edge-walking state machine registers
- Edge function accumulators (e0, e1, e2) and row-start registers (e0_row, e1_row, e2_row) for incremental stepping
- Per-attribute derivative registers (dAttr/dx, dAttr/dy) for 14 attributes: color0 RGBA, color1 RGBA, Z, Q/W, S0/T0 projected, S1/T1 projected; computed once per triangle during setup
- Accumulated attribute values (attr_x) per active fragment position; stepped with additions in the inner loop
- 4×4 tile traversal counters (tile_x, tile_y within tile; outer tile_col, tile_row across the bounding box)
- Three-stage perspective correction pipeline: BRAM read (cycle 1), 1/Q via MULT18X18D interpolation (cycle 2), then S×(1/Q) and T×(1/Q) via dedicated MULT18X18D blocks (cycle 3)

### Algorithm / Behavior

1. **Edge Setup** (SETUP → SETUP_2 → SETUP_3, 3 cycles): Compute edge coefficients A (11-bit) and B (11-bit) in cycle 1; compute edge C coefficients (21-bit) serialized over 3 cycles using 2 dedicated MULT18X18D blocks; compute bounding box clamped to the configured surface dimensions.
   Compute CLZ on the signed triangle area magnitude (22-bit) and look up `inv_area` from the dedicated triangle setup reciprocal module (`raster_recip_area.sv`), which uses 1 DP16KD in 36×512 mode with a 9-bit CLZ index.
   A single BRAM read returns a 36-bit entry packing UQ1.17 reciprocal seed + UQ0.17 delta for linear interpolation via 1 MULT18X18D.
   Output is UQ4.14 (18-bit unsigned after denormalization); optional compile-time Newton-Raphson refinement adds 1 MULT18X18D and 2-3 extra cycles.
   This module is latency-tolerant as it runs once per triangle.
   Total DSP usage for edge setup: 2 (C coefficients) + 1 (LUT interpolation) = 3 MULT18X18D (4 with Newton-Raphson enabled).

2. **Derivative Precomputation** (ITER_START → INIT_E1 → INIT_E2 → DERIV_0 … DERIV_13, 17 cycles): Evaluate edge functions at the bounding box origin using the 2 shared MULT18X18D blocks (3 cycles, cold path, once per triangle); latch into e0/e1/e2 and row-start registers.
   Then sequentially compute per-attribute derivatives for all 14 interpolated attributes (14 cycles, one attribute per cycle) using the same 2 shared MULT18X18D blocks time-multiplexed: for each attribute `f`, multiplier 0 computes `raw_dx * inv_area` and multiplier 1 computes `raw_dy * inv_area` simultaneously (DD-036).
   Initialize accumulated attribute values at the bounding box origin.

3. **Tile-Ordered Traversal** (inner loop): Walk the bounding box in 4×4 tile order — advance pixel-by-pixel within a 4×4 tile, then advance to the next tile horizontally, then vertically.
   At the start of each 4×4 tile, test edge functions at the four tile corners using the accumulated e0/e1/e2 values; when all four corners are outside the same edge half-plane, reject the entire tile without emitting fragments.
   When `RENDER_MODE.Z_TEST_EN=1` and the tile is not edge-rejected, perform a Hi-Z metadata lookup (HIZ_TEST state): compute `tile_index = (tile_row << tile_cols_log2) | tile_col`; read the 9-bit metadata entry from the Hi-Z metadata store; if `min_z != 9'h1FF` (not the sentinel) and `fragment_Z[15:7] > stored_min_z`, reject the entire tile without emitting any fragments (tile-level Z pre-rejection).

4. **Pixel Test** (EDGE_TEST, per pixel within accepted tiles): Check e0/e1/e2 ≥ 0 (inside triangle); no multiply required.

5. **Interpolation** (INTERPOLATE, per inside pixel): Add dAttr/dx to accumulators when stepping right in X; add dAttr/dy when advancing to a new row.
   No per-pixel multiplies are required for attribute interpolation — all stepping is by incremental addition.

6. **Perspective Correction** (3-cycle pipeline, per inside pixel):
   - Cycle 1 (BRAM_READ): Compute CLZ on the interpolated Q/W value (unsigned, always positive for visible geometry); index the dedicated per-pixel reciprocal module (`raster_recip_q.sv`) with the 10-bit CLZ-normalized mantissa; initiate DP16KD BRAM read (18×1024 mode, UQ1.17 entries).
     This also produces frag_lod = CLZ(Q) in UQ4.4 format.
   - Cycle 2 (PERSP_1): BRAM read result available; apply 1 MULT18X18D linear interpolation to produce 1/Q in UQ4.14 (18-bit unsigned).
   - Cycle 3 (PERSP_2): Multiply S0×(1/Q) and T0×(1/Q) using 2 dedicated MULT18X18D blocks; multiply S1×(1/Q) and T1×(1/Q) using 2 additional dedicated MULT18X18D blocks.
     Output true perspective-correct U0, V0 (Q4.12) and U1, V1 (Q4.12).
   Total DSP usage for perspective correction: 1 (1/Q interpolation) + 4 (S/T multiply) = 5 MULT18X18D.

7. **Fragment Emission**: After the 3-cycle perspective correction pipeline, emit the completed fragment to UNIT-006 via frag_valid/frag_ready.
   Stall the traversal (hold all state) when frag_ready is deasserted by UNIT-006.

8. **Scissor Bounds**: Bounding box is clamped to `[0, (1<<FB_CONFIG.WIDTH_LOG2)-1]` in X and `[0, (1<<FB_CONFIG.HEIGHT_LOG2)-1]` in Y.

### DSP Budget

| Usage | MULT18X18D count | Time-sharing |
|---|---|---|
| Edge C coefficient computation / derivative inv_area scaling (shared pair) | 2 | Setup: C coefficients; ITER_START–INIT_E2: edge eval; DERIV_0–DERIV_13: derivative scaling (DD-036) |
| Triangle setup reciprocal interpolation (inv_area, `raster_recip_area.sv`) | 1 | Once per triangle |
| Per-pixel 1/Q reciprocal interpolation (`raster_recip_q.sv`) | 1 | Per inside pixel |
| Perspective correction: U0, V0 = S0×(1/Q), T0×(1/Q) | 2 | Per inside pixel |
| Perspective correction: U1, V1 = S1×(1/Q), T1×(1/Q) | 2 | Per inside pixel |
| **Total** | **8** | |

Note: With optional Newton-Raphson refinement enabled for inv_area, total increases to 9 MULT18X18D.
The derivative computation reuses the same 2 MULT18X18D blocks as edge C-coefficient computation and edge evaluation; no additional DSP blocks are required (DD-036).

## Sub-Units

UNIT-005 decomposes internally into six functional sub-units, each documented in its own design unit file:

- [UNIT-005.01: Triangle Setup](unit_005.01_triangle_setup.md) — triangle validation, backface culling, vertex attribute passthrough
- [UNIT-005.02: Edge Setup](unit_005.02_edge_setup.md) — edge coefficient computation, bounding box, reciprocal area computation; implemented as a separate RTL module instantiated by the parent `rasterizer.sv` (DD-029)
- [UNIT-005.03: Derivative Pre-computation](unit_005.03_derivative_precomputation.md)
- [UNIT-005.04: Attribute Accumulation](unit_005.04_attribute_accumulation.md)
- [UNIT-005.05: Iteration FSM](unit_005.05_iteration_fsm.md)
- [UNIT-005.06: Hi-Z Block Metadata](unit_005.06_hiz_block_metadata.md) — 8-DP16KD metadata store, fast-clear (sentinel sweep), and Hi-Z tile rejection interface; lazy-fill is owned by UNIT-006

## Implementation

- `components/rasterizer/rtl/src/rasterizer.sv`: Parent module — FSM, vertex latches, reciprocal module instantiation, setup-iteration overlap FIFO, sub-module instantiation (DD-029).
- `components/rasterizer/rtl/src/raster_recip_area.sv`: Triangle setup reciprocal module — 1 DP16KD (36×512), CLZ normalization on signed 22-bit magnitude, UQ4.14 inv_area output, optional Newton-Raphson refinement.
- `components/rasterizer/rtl/src/raster_recip_q.sv`: Per-pixel 1/Q reciprocal module — 1 DP16KD (18×1024), CLZ normalization on unsigned input, UQ4.14 output, 2-cycle latency.
- `components/rasterizer/rtl/src/raster_hiz_meta.sv`: Hi-Z block metadata store (UNIT-005.06) — 8 DP16KD (36×512), 16,384-entry packed metadata (9-bit min_z per tile, sentinel `9'h1FF` for unwritten tiles), fast-clear (512-cycle sentinel-write sweep), Hi-Z tile rejection read/write interface.
- `components/rasterizer/rtl/src/raster_deriv.sv`: Sequential time-multiplexed derivative precomputation (UNIT-005.03), 2 shared MULT18X18D, 14-cycle attribute loop (DD-036).
- `components/rasterizer/rtl/src/raster_attr_accum.sv`: Attribute accumulators, derivative registers, output promotion and clamping (UNIT-005.03 latching / UNIT-005.04).
- `components/rasterizer/rtl/src/raster_setup_fifo.sv`: Parameterized register-based FIFO for setup-iteration overlap (DD-035).
- `components/rasterizer/rtl/src/raster_edge_walk.sv`: Tile-ordered iteration, edge functions, fragment emission, 3-cycle perspective correction pipeline, Hi-Z metadata lookup (HIZ_TEST state) (UNIT-005.05).

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
- Verify reciprocal modules: for a known area value, confirm inv_area from `raster_recip_area.sv` matches the analytic reciprocal within the specified UQ4.14 rounding tolerance; for known Q/W values, confirm 1/Q from `raster_recip_q.sv` matches within UQ4.14 rounding tolerance
- Verify derivative precomputation: for a known triangle, confirm dAttr/dx and dAttr/dy for all 14 attributes match expected values derived from vertex attributes and the internally computed inv_area
- Verify incremental interpolation: step across a rasterized triangle and confirm accumulated color0, color1, Z, Q/W, S/T projected values at each fragment match analytic values within rounding tolerance
- Verify perspective correction pipeline: confirm that emitted frag_uv0 and frag_uv1 carry true perspective-correct U, V values (not S, T projections); verify frag_lod (UQ4.4) matches CLZ(Q) for known Q values
- Verify 4×4 tile traversal order: confirm fragment emission order follows tile-major then pixel-minor order; verify hierarchical tile rejection suppresses entire tiles when all four corners lie outside a single edge half-plane
- Verify the fragment output bus carries correct (x, y, z, color0, color1, uv0, uv1, lod) values and valid/ready handshake operates correctly
- Test degenerate triangles (zero area, single-pixel, off-screen)
- **Hi-Z metadata correctness:** For a tile whose `min_z != 9'h1FF` and `min_z` is less than `fragment_Z[15:7]`, confirm no fragments are emitted from that tile and the FSM advances directly to the next tile (HIZ_TEST rejection path).
- **Hi-Z conservatism (no false rejections):** For a tile where the incoming fragment Z equals or exceeds the stored `min_z` bucket boundary, confirm the tile is not rejected (truncation ensures the stored min_z is always ≤ the true tile minimum).
- **Hi-Z bypass when Z_TEST_EN=0:** Confirm HIZ_TEST state is not entered and all tiles proceed to edge testing regardless of metadata content.
- **Hi-Z metadata update:** After a Z-write to a tile reduces the tile minimum, confirm the metadata `min_z` is updated to `new_z[15:7]` on the next update cycle.
- **Fast-clear:** After the 512-cycle sentinel-write pass, confirm all entries read as `9'h1FF` and subsequent tile accesses via UNIT-006 trigger lazy-fill rather than SDRAM reads.
- **Rejection statistics:** For a scene with a provably occluded tile (e.g., two overlapping triangles with the back triangle at greater Z), confirm the Hi-Z rejection count is non-zero.
- VER-014 (Textured Cube Golden Image Test)
- VER-010 (Gouraud Triangle Golden Image Test)
- VER-011 (Depth-Tested Overlapping Triangles Golden Image Test)
- VER-012 (Textured Triangle Golden Image Test)
- VER-001 (Rasterizer Unit Testbench)

## Design Notes

**Unified clock:** The rasterizer operates at the unified 100 MHz `clk_core`.
At one fragment evaluation per clock cycle in the inner edge-walking loop (plus 3 cycles of perspective correction latency in the pipeline), the rasterizer achieves a peak throughput of 100 million fragment evaluations per second.
Fragment output to the pixel pipeline (UNIT-006) is synchronous within the same 100 MHz clock domain.
Effective sustained pixel output rate is approximately 25 Mpixels/sec after SRAM arbitration contention with display scanout, Z-buffer, and texture fetch (see INT-011 bandwidth budget).

**Tile-ordered traversal and burst access:** The 4×4 tile-ordered traversal groups spatially coherent fragments together, improving texture cache hit rate in UNIT-011 (Texture Sampler).
Each 4×4 tile corresponds to a contiguous 4×4 block of screen pixels; fragments are emitted pixel-by-pixel within the tile, then tile-by-tile across the bounding box in row-major tile order.
The tile stride depends on `FB_CONFIG.WIDTH_LOG2`, which sets the number of tiles per row as `1 << (WIDTH_LOG2 - 2)`.
Hierarchical tile rejection allows the FSM to skip entire tiles in a single step when the tile is provably outside the triangle.

**Hi-Z block metadata (UNIT-005.06):** The rasterizer maintains a per-tile metadata array in 8 DP16KD blocks that records the minimum Z seen in each 4×4 Z-buffer tile (9-bit truncated `min_z = tile_min_z[15:7]`).
A sentinel value of `9'h1FF` (all-ones) indicates no Z-write has reached the tile since the last clear.
This enables two optimizations operating at tile granularity, complementary to the per-pixel early Z-test in UNIT-006:

1. **Hi-Z tile rejection (HIZ_TEST state):** When `Z_TEST_EN=1`, after a tile passes the edge half-plane test, the FSM checks the Hi-Z metadata before entering pixel-level EDGE_TEST.
   If the tile's `min_z` is not the sentinel and the incoming triangle Z (at tile granularity) is greater than the stored `min_z` bucket, the entire tile is rejected without emitting any fragments.
   The comparison uses `fragment_Z[15:7] > stored_min_z`, which is conservative: because `min_z` is the truncated (floor) minimum, the stored value never exceeds the true minimum, so no visible fragment is incorrectly rejected.

2. **Fast clear:** Resetting the Hi-Z metadata (writing sentinel `9'h1FF` to all 16,384 tile entries) requires only 512 write cycles — one word per DP16KD address, all 8 blocks in parallel — versus ~266,000 cycles for a full SDRAM MEM_FILL clear.
   Uninitialized-tile tracking and lazy-fill are handled by UNIT-006's dedicated uninitialized flag EBR; UNIT-005.06 only tracks `min_z`.

The 8-DP16KD budget (each in 36×512 mode) covers all 128×128 = 16,384 tiles in a 512×512 surface at 4 entries per 36-bit word.
See `doc/reports/zbuffer_dp16k_block_metadata.md` for the full sizing and addressing analysis.

**Incremental interpolation (multiplier optimization):** Edge functions are linear: E(x+1,y) = E(x,y) + A and E(x,y+1) = E(x,y) + B.
The rasterizer computes edge values and all 14 attribute derivatives at the bounding box origin once per triangle (using the 2 shared MULT18X18D blocks sequentially across 17 cycles in the ITER_START through DERIV_13 window), then steps all edge and attribute accumulators incrementally with pure addition in the per-pixel inner loop.
No per-pixel multiplies are required for edge testing or attribute interpolation.
See DD-024 for the rationale behind replacing per-pixel barycentric multiply-accumulate with precomputed derivative increments.

**Dedicated reciprocal modules:** Two separate DP16KD-backed reciprocal modules replace the shared case-statement ROM LUT:

- `raster_recip_area.sv` computes inv_area once per triangle during edge setup using 1 DP16KD in 36×512 mode.
  The 36-bit entries pack a UQ1.17 seed and UQ0.17 delta, enabling single-read linear interpolation via 1 MULT18X18D.
  Signed triangle area is handled by CLZ normalization on the 22-bit magnitude, with sign and shift reapplied after interpolation.
  Output is UQ4.14 (18-bit), providing 2 extra fractional bits over the previous Q4.12 format.
  An optional compile-time Newton-Raphson refinement stage (1 additional MULT18X18D, 2-3 extra cycles) is available for higher precision.
- `raster_recip_q.sv` computes 1/Q per pixel during traversal using 1 DP16KD in 18×1024 mode.
  Q = 1/W is always positive for visible geometry, so no sign handling is needed.
  The 10-bit CLZ index addresses 1024 UQ1.17 entries; entry 1024 is special-cased for interpolation of the last entry.
  2-cycle latency: BRAM read (cycle 1) + MULT18X18D interpolation (cycle 2).
  Output is UQ4.14 (18-bit unsigned).

Splitting the reciprocal into two dedicated modules allows setup of the next triangle to overlap with iteration of the current triangle via the setup-iteration overlap FIFO (DD-035).

**Setup-iteration overlap FIFO:** A compile-time configurable depth (default 2) register-based FIFO sits between the triangle setup producer (UNIT-005.02/005.03) and the edge-walk iteration consumer (UNIT-005.05).
The FIFO holds complete triangle setup results (~730 bits: edge coefficients A/B/C × 3, bbox min/max, inv_area, vertex attributes including colors, Z, Q, UVs).
This allows setup of triangle N+1 to proceed in parallel with iteration of triangle N, eliminating setup stalls for sequences of small triangles.
The rasterizer FSM operates as a producer-consumer pipeline rather than a sequential setup-then-iterate machine.
At depth 2, the FIFO uses approximately 1460 flip-flops (fabric registers, no BRAM).

**Perspective correction in the rasterizer:** S/T projected texture coordinates (S=U/W, T=V/W) are interpolated incrementally alongside all other attributes.
The 3-cycle perspective correction pipeline converts these to true U, V per pixel using the concurrently computed 1/Q from `raster_recip_q.sv`.
This removes the UV perspective division from the pixel pipeline (UNIT-006): frag_uv0 and frag_uv1 on the fragment bus carry fully corrected U, V in Q4.12.

**Fragment bus — frag_lod:** CLZ on the interpolated Q/W value provides an unsigned integer mip-level estimate (frag_lod, UQ4.4).
UNIT-011 (Texture Sampler) adds TEXn_MIP_BIAS to frag_lod to produce the final mip level for texture cache lookup.
frag_q is not present on the fragment bus; perspective correction is complete before fragment emission.

**Dual-texture + color combiner:** The rasterizer interpolates two vertex colors (VER_COLOR0 and VER_COLOR1) per fragment, plus UV0, UV1, Z, and Q/W.
Under the incremental interpolation scheme, additional accumulator registers and derivative storage are the only cost for each additional attribute — no additional DSP multipliers in the inner loop.
Both interpolated vertex colors are output to UNIT-006 for use as VER_COLOR0 and VER_COLOR1 inputs to the color combiner (UNIT-010).
