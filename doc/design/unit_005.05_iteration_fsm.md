# UNIT-005.05: Iteration FSM

## Purpose

Drives the 4×4 tile-ordered bounding box walk, hierarchical tile rejection, edge testing, perspective correction pipeline, and fragment output handshake.
Sub-unit of UNIT-005 (Rasterizer).

## Implements Requirements

- REQ-002.03 (Rasterization Algorithm) — 4×4 tile traversal, hierarchical tile rejection, and per-pixel perspective correction

## Interfaces

### Internal Interfaces

- Receives e0/e1/e2 initial values, row-start registers, and A/B edge coefficients from UNIT-005.02 (Edge Setup) and UNIT-005.03 (Derivative Pre-computation)
- Receives S/T projected attribute values (Q4.12) and Q/W (Q3.12) from UNIT-005.04 (Attribute Accumulation) at each inside pixel
- Commands UNIT-005.04 to step accumulators on X-step, Y-step, and row-reload events
- Uses a dedicated per-pixel reciprocal module (`raster_recip_q.sv`) for 1/Q computation; UNIT-005.02 uses a separate dedicated module (`raster_recip_area.sv`)
- Drives fragment output bus (frag_valid/frag_ready) toward UNIT-006 (Pixel Pipeline)

## Design Description

**FSM states:** TILE_TEST, HIZ_TEST, EDGE_TEST, BRAM_READ, PERSP_1, PERSP_2, EMIT, ITER_NEXT (inner loop)

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

Tiles that cannot be rejected by this test proceed to HIZ_TEST (when `Z_TEST_EN=1`) or directly to pixel-level EDGE_TEST (when `Z_TEST_EN=0`).

### Hi-Z Tile Rejection (HIZ_TEST)

When `RENDER_MODE.Z_TEST_EN=1`, tiles that survive TILE_TEST enter HIZ_TEST before any pixel-level work begins.

**HIZ_TEST procedure:**

1. Compute the 14-bit tile index: `tile_index = (tile_row << tile_cols_log2) | tile_col`, where `tile_cols_log2 = FB_CONFIG.WIDTH_LOG2 - 2`.
2. Decode the index into block select `tile_index[13:11]`, word address `tile_index[10:2]`, and slot `tile_index[1:0]`.
3. Assert a read request to UNIT-005.06 (Hi-Z Block Metadata); the read result is registered one cycle later.
4. Extract the 9-bit metadata entry: `min_z = entry[8:0]` (= Z[15:7] of the tile minimum depth).
5. **Rejection condition:** If `min_z != 9'h1FF` (not the sentinel "unwritten" value) and `fragment_Z[15:7] > min_z`, reject the tile:
   - Step tile-origin accumulators to the next tile (same advance as TILE_TEST rejection).
   - Advance `tile_col` / `tile_row` and return to TILE_TEST.
   - No fragments are emitted; EDGE_TEST is not entered.
6. If `min_z == 9'h1FF` (sentinel — no Z-write yet since last clear) or the Z comparison does not reject, proceed to EDGE_TEST.

The comparison is conservative: `min_z` stores `floor(tile_minimum_Z / 128)`, so a stored value of `N` represents real tile minimum Z in `[128·N, 128·N+127]`.
A fragment with `fragment_Z[15:7] > N` is guaranteed to be farther than every pixel currently in the tile, making rejection safe.
The tile is not rejected when `fragment_Z[15:7] == min_z`, even though some pixels in that bucket may already be closer — this avoids false rejections at bucket boundaries.
The sentinel value `9'h1FF` prevents rejection of tiles not yet written since the last clear, regardless of the incoming fragment Z.

**Bypass:** When `Z_TEST_EN=0`, the FSM transitions directly from TILE_TEST acceptance to EDGE_TEST; HIZ_TEST is never entered.

### Pixel Edge Test (EDGE_TEST)

For each pixel within an accepted tile, check e0 ≥ 0, e1 ≥ 0, e2 ≥ 0 (inside triangle).
Pixels that fail any edge test advance to ITER_NEXT without entering the perspective correction pipeline.
No multiply is required.

### Perspective Correction Pipeline (BRAM_READ, PERSP_1, PERSP_2)

For inside pixels, the FSM executes a 3-cycle perspective correction pipeline:

**Cycle 1 (BRAM_READ):**

- Apply CLZ to the interpolated Q/W value from UNIT-005.04 (unsigned — Q = 1/W is always positive for visible geometry) to determine the normalization shift.
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
- z: extracted Z from UNIT-005.04 (16-bit unsigned)
- color0, color1: clamped UNORM8 RGBA from UNIT-005.04
- uv0 = (U0, V0): true perspective-correct texture coordinates (Q4.12 each)
- uv1 = (U1, V1): true perspective-correct texture coordinates (Q4.12 each)
- lod: frag_lod (UQ4.4)

The FSM holds in EMIT (stalls all state) while frag_ready is deasserted by UNIT-006.

### Pixel and Tile Advance (ITER_NEXT)

After EMIT (or after a rejected pixel in EDGE_TEST), step to the next pixel:

- Increment px; if px < 4, add A coefficients to e0/e1/e2 and command UNIT-005.04 to step-X.
- When px wraps to 0, increment py; if py < 4, add B coefficients to e0/e1/e2, reload e0/e1/e2 from row-start, add B to row-start, and command UNIT-005.04 to row-reload.
- When both px and py wrap to 0, advance to the next tile: increment tile_col; when tile_col reaches the tile-row boundary, increment tile_row.
- On bounding box exhaustion, return to IDLE and assert tri_ready.

### Block Framing Signals

The FSM asserts block framing signals on the fragment bus to allow UNIT-006 to identify tile boundaries:

- `frag_tile_start`: asserted on the first emitted fragment of each 4×4 tile.
- `frag_tile_end`: asserted on the last emitted fragment of each 4×4 tile (or the last inside pixel if the tile ends early).

These signals enable downstream consumers to optimize SDRAM burst scheduling and texture cache prefetching at tile granularity.

### DSP Usage

| Usage | MULT18X18D count |
| --- | --- |
| Per-pixel 1/Q reciprocal interpolation (`raster_recip_q.sv`) | 1 |
| Perspective correction: U0 = S0 × (1/Q) | 1 |
| Perspective correction: V0 = T0 × (1/Q) | 1 |
| Perspective correction: U1 = S1 × (1/Q) | 1 |
| Perspective correction: V1 = T1 × (1/Q) | 1 |
| **Sub-unit total** | **5** |

## Implementation

- `components/rasterizer/rtl/src/raster_edge_walk.sv`: Tile-ordered iteration FSM, hierarchical tile rejection, Hi-Z metadata lookup (HIZ_TEST state), edge testing, 3-cycle perspective correction pipeline, block framing signals, fragment output handshake.
- `components/rasterizer/rtl/src/raster_recip_q.sv`: Dedicated per-pixel 1/Q reciprocal module — 1 DP16KD (18×1024), UQ1.17 entries, 2-cycle latency (BRAM read + MULT18X18D interpolation), UQ4.14 output.
- `components/rasterizer/rtl/src/raster_hiz_meta.sv`: Hi-Z block metadata store (UNIT-005.06) — provides the read/write interface consumed by HIZ_TEST and the Hi-Z metadata update path from the pixel pipeline.
- `components/rasterizer/twin/src/rasterize.rs`: Digital twin — `HizMetadata` struct and Hi-Z tile rejection logic integrated into the tile traversal loop.

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).

Key verification points for this sub-unit:

- Verify 4×4 tile traversal order: confirm fragment emission order is tile-major (row-major tile order) then pixel-major (row-major within tile); cross-check against expected (x, y) sequence for a known bounding box.
- Verify hierarchical tile rejection: for a triangle where a tile's four corners all lie outside one edge half-plane, confirm no fragments are emitted from that tile and the FSM advances to the next tile in one step.
- **Verify HIZ_TEST rejection:** For a tile with `stored_min_z != 9'h1FF` and `stored_min_z < fragment_Z[15:7]`, confirm no fragments are emitted and the FSM advances to TILE_TEST for the next tile without entering EDGE_TEST.
- **Verify HIZ_TEST conservatism:** For a tile where `fragment_Z[15:7] == stored_min_z`, confirm the tile is not rejected and proceeds to EDGE_TEST.
- **Verify HIZ_TEST bypass:** When `Z_TEST_EN=0`, confirm the FSM transitions directly from TILE_TEST acceptance to EDGE_TEST without a HIZ_TEST cycle.
- **Verify HIZ_TEST on cleared tile (sentinel `min_z == 9'h1FF`):** Confirm the tile is not rejected and proceeds to EDGE_TEST.
- Verify perspective correction accuracy: for a known Q/W value and S/T inputs, confirm U, V outputs match the analytic S×(1/Q), T×(1/Q) within Q4.12 rounding tolerance.
- Verify frag_lod (UQ4.4): confirm CLZ(Q) matches the expected mip-level estimate for Q values at power-of-two boundaries and intermediate values.
- Verify block framing: confirm frag_tile_start and frag_tile_end assert at the correct fragment positions for tiles with varying numbers of inside pixels.
- Verify handshake stall: when frag_ready is deasserted, confirm all FSM state (edge accumulators, attribute outputs, pipeline stage registers) is frozen until frag_ready reasserts.
