# UNIT-005.04: Iteration FSM

## Purpose

Drives the 4×4 tile-ordered bounding box walk, hierarchical tile rejection, edge testing, perspective correction pipeline, and fragment output handshake.
Sub-unit of UNIT-005 (Rasterizer).

## Implements Requirements

- REQ-002.03 (Rasterization Algorithm) — 4×4 tile traversal, hierarchical tile rejection, and per-pixel perspective correction

## Interfaces

### Internal Interfaces

- Receives e0/e1/e2 initial values, row-start registers, and A/B edge coefficients from UNIT-005.01 (Edge Setup) and UNIT-005.02 (Derivative Pre-computation)
- Receives S/T projected attribute values (Q4.12) and Q/W (Q3.12) from UNIT-005.03 (Attribute Accumulation) at each inside pixel
- Commands UNIT-005.03 to step accumulators on X-step, Y-step, and row-reload events
- Uses a dedicated per-pixel reciprocal module (`raster_recip_q.sv`) for 1/Q computation; UNIT-005.01 uses a separate dedicated module (`raster_recip_area.sv`)
- Drives fragment output bus (frag_valid/frag_ready) toward UNIT-006 (Pixel Pipeline)

## Design Description

**FSM states:** TILE_TEST, EDGE_TEST, BRAM_READ, PERSP_1, PERSP_2, EMIT, ITER_NEXT (inner loop)

### 4×4 Tile-Ordered Traversal

The bounding box is partitioned into 4×4 tiles.
The FSM advances through tiles in row-major order (left-to-right, top-to-bottom across the bounding box), and within each tile advances through pixels in row-major order (left-to-right, top-to-bottom within the 4×4 block).

Tile and pixel positions are tracked by:

- `tile_col`, `tile_row`: current tile index within the bounding box (outer counters)
- `px`, `py`: pixel offset within the current tile, each in [0, 3] (inner counters)

Edge function accumulators (e0, e1, e2) are maintained at the current pixel, stepped by A/B coefficients as in the scanline algorithm.
Row-start registers (e0_row, e1_row, e2_row) are maintained at the start of each tile row for Y-advance row-reloads.

### Hierarchical Tile Rejection (TILE_TEST)

At the start of each 4×4 tile, the FSM evaluates the edge functions at the four tile corners using the current e0/e1/e2 values (no multiplies — corner values are computed by adding 3×A or 3×B to the tile-origin edge values).
When all four corners yield a negative value for the same edge (i.e., the entire tile lies outside one half-plane), the tile is rejected:

- Step e0/e1/e2 by 4×A to advance the tile-origin accumulators to the next tile column, or by 4×B to advance to the next tile row.
- Advance `tile_col` or `tile_row` accordingly and return to TILE_TEST.

Tiles that cannot be rejected by this test proceed to pixel-level EDGE_TEST.

### Pixel Edge Test (EDGE_TEST)

For each pixel within an accepted tile, check e0 ≥ 0, e1 ≥ 0, e2 ≥ 0 (inside triangle).
Pixels that fail any edge test advance to ITER_NEXT without entering the perspective correction pipeline.
No multiply is required.

### Perspective Correction Pipeline (BRAM_READ, PERSP_1, PERSP_2)

For inside pixels, the FSM executes a 3-cycle perspective correction pipeline:

**Cycle 1 (BRAM_READ):**

- Apply CLZ to the interpolated Q/W value from UNIT-005.03 (unsigned — Q = 1/W is always positive for visible geometry) to determine the normalization shift.
- Index the dedicated per-pixel reciprocal module (`raster_recip_q.sv`) with the 10-bit CLZ-normalized mantissa (from normalized[29:20]); initiate DP16KD BRAM read (18×1024 mode, UQ1.17 entries).
- Compute frag_lod = CLZ(Q) as a UQ4.4 integer mip-level estimate.

**Cycle 2 (PERSP_1):**

- BRAM read result available; apply 1 MULT18X18D linear interpolation to produce 1/Q in UQ4.14 (18-bit unsigned).

**Cycle 3 (PERSP_2):**

- Multiply S0 × (1/Q) using 1 dedicated MULT18X18D; extract upper bits as U0 (Q4.12).
- Multiply T0 × (1/Q) using 1 dedicated MULT18X18D; extract upper bits as V0 (Q4.12).
- Multiply S1 × (1/Q) using 1 dedicated MULT18X18D; extract upper bits as U1 (Q4.12).
- Multiply T1 × (1/Q) using 1 dedicated MULT18X18D; extract upper bits as V1 (Q4.12).

Total DSP usage for perspective correction: 1 MULT18X18D (1/Q interpolation, dedicated to this module) + 4 MULT18X18D (S/T multiply) = 5 MULT18X18D.

### Fragment Emission (EMIT)

After PERSP_2 completes, assert frag_valid and drive the fragment bus with:

- (x, y): current pixel screen coordinates (UQ12.0)
- z: extracted Z from UNIT-005.03 (16-bit unsigned)
- color0, color1: clamped UNORM8 RGBA from UNIT-005.03
- uv0 = (U0, V0): true perspective-correct texture coordinates (Q4.12 each)
- uv1 = (U1, V1): true perspective-correct texture coordinates (Q4.12 each)
- lod: frag_lod (UQ4.4)

The FSM holds in EMIT (stalls all state) while frag_ready is deasserted by UNIT-006.

### Pixel and Tile Advance (ITER_NEXT)

After EMIT (or after a rejected pixel in EDGE_TEST), step to the next pixel:

- Increment px; if px < 4, add A coefficients to e0/e1/e2 and command UNIT-005.03 to step-X.
- When px wraps to 0, increment py; if py < 4, add B coefficients to e0/e1/e2, reload e0/e1/e2 from row-start, add B to row-start, and command UNIT-005.03 to row-reload.
- When both px and py wrap to 0, advance to the next tile: increment tile_col; when tile_col reaches the tile-row boundary, increment tile_row.
- On bounding box exhaustion, return to IDLE and assert tri_ready.

### Block Framing Signals

The FSM asserts block framing signals on the fragment bus to allow UNIT-006 to identify tile boundaries:

- `frag_tile_start`: asserted on the first emitted fragment of each 4×4 tile.
- `frag_tile_end`: asserted on the last emitted fragment of each 4×4 tile (or the last inside pixel if the tile ends early).

These signals enable downstream consumers to optimize SDRAM burst scheduling and texture cache prefetching at tile granularity.

### DSP Usage

| Usage | MULT18X18D count |
|---|---|
| Per-pixel 1/Q reciprocal interpolation (`raster_recip_q.sv`) | 1 |
| Perspective correction: U0 = S0 × (1/Q) | 1 |
| Perspective correction: V0 = T0 × (1/Q) | 1 |
| Perspective correction: U1 = S1 × (1/Q) | 1 |
| Perspective correction: V1 = T1 × (1/Q) | 1 |
| **Sub-unit total** | **5** |

## Implementation

- `components/rasterizer/rtl/raster_edge_walk.sv`: Tile-ordered iteration FSM, hierarchical tile rejection, edge testing, 3-cycle perspective correction pipeline, block framing signals, fragment output handshake.
- `components/rasterizer/rtl/raster_recip_q.sv`: Dedicated per-pixel 1/Q reciprocal module — 1 DP16KD (18×1024), UQ1.17 entries, 2-cycle latency (BRAM read + MULT18X18D interpolation), UQ4.14 output.

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).

Key verification points for this sub-unit:

- Verify 4×4 tile traversal order: confirm fragment emission order is tile-major (row-major tile order) then pixel-major (row-major within tile); cross-check against expected (x, y) sequence for a known bounding box.
- Verify hierarchical tile rejection: for a triangle where a tile's four corners all lie outside one edge half-plane, confirm no fragments are emitted from that tile and the FSM advances to the next tile in one step.
- Verify perspective correction accuracy: for a known Q/W value and S/T inputs, confirm U, V outputs match the analytic S×(1/Q), T×(1/Q) within Q4.12 rounding tolerance.
- Verify frag_lod (UQ4.4): confirm CLZ(Q) matches the expected mip-level estimate for Q values at power-of-two boundaries and intermediate values.
- Verify block framing: confirm frag_tile_start and frag_tile_end assert at the correct fragment positions for tiles with varying numbers of inside pixels.
- Verify handshake stall: when frag_ready is deasserted, confirm all FSM state (edge accumulators, attribute outputs, pipeline stage registers) is frozen until frag_ready reasserts.
