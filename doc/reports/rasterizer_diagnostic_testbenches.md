# Technical Report: Rasterizer Diagnostic Testbenches

Date: 2026-03-06
Status: Draft

## Background

After completing the Phase 2 rasterizer design rewrite (UNIT-005.x), the rendered test images in `build/sim_out/` exhibit multiple visible defects:

- **Gouraud triangle** (`gouraud_triangle.png`): Color interpolation saturates to cyan almost immediately.
  Only a tiny patch near the top vertex shows the expected yellow/green gradient; the rest is solid max-green + max-blue.
- **Textured triangle** (`textured_triangle.png`): Entirely white — no texture data visible at all.
- **Textured cube** (`textured_cube.png`): White polygons with incorrect geometry — jagged edges and gaps.
- **Color combined** (`color_combined.png`): Same cyan saturation as gouraud, slightly shifted.
- **Depth test** (`depth_test.png`): Red/blue triangles render with plausible shapes, but Z-ordering correctness is uncertain.

Rather than attempting to fix these complex end-to-end images directly, this report specifies a set of small, focused diagnostic testbenches.
Each isolates a single pipeline stage or interface, making it straightforward to identify which subsystem(s) are producing incorrect results.

## Scope

**In scope:**
- Specification of 20 diagnostic testbenches covering every rasterizer submodule
- Stimulus descriptions, expected outputs, and pass/fail criteria for each test
- Mapping from each test to the likely root cause it would diagnose
- Observations from RTL analysis that motivate specific tests

**Out of scope:**
- Proposed RTL fixes (documented observations only)
- Changes to specifications or design units
- Downstream pixel pipeline tests (UNIT-006 and beyond)

## Investigation

### Documents and Code Examined

| Source | Purpose |
|--------|---------|
| `spi_gpu/src/render/raster_deriv.sv` | Derivative precomputation (combinational) |
| `spi_gpu/src/render/raster_attr_accum.sv` | Attribute accumulation, stepping, promotion |
| `spi_gpu/src/render/raster_edge_walk.sv` | Tile-ordered iteration FSM, perspective correction |
| `spi_gpu/src/render/raster_recip_lut.sv` | 1/x reciprocal LUT with CLZ normalization |
| `spi_gpu/src/render/rasterizer.sv` | Top-level FSM, shared multiplier, submodule wiring |
| `spi_gpu/tests/render/tb_raster_deriv.sv` | Existing derivative testbench (9 tests) |
| `spi_gpu/tests/render/tb_raster_attr_accum.sv` | Existing accumulator testbench (10 tests) |
| `spi_gpu/tests/render/tb_raster_edge_walk.sv` | Existing edge walk testbench (10 tests) |
| `spi_gpu/tests/render/tb_rasterizer.sv` | Existing integrated testbench (12 tests) |
| `doc/reports/rasterizer_comprehensive_plan.md` | Phase 2 design plan and status |
| `build/sim_out/*.png` | Current rendered test images |

### Key RTL Observations

The following observations emerged from the RTL analysis and directly motivate specific tests.
These are documented as observations, not proposed fixes.

#### Observation 1: inv_area Not Connected to raster_deriv

`rasterizer.sv` computes `inv_area` via the reciprocal LUT (line 1040: `next_inv_area = recip_lut_recip_out`) and stores it in a register.
However, `raster_deriv.sv` has no input port for this value.
Instead, it uses internal hardcoded constants (lines 133-134):

```systemverilog
localparam [15:0] INV_AREA   = 16'hFFFF;  // ~1.0 in UQ0.16
localparam [3:0]  AREA_SHIFT = 4'd0;
```

This means every triangle's derivatives are scaled by a fixed ~1.0 rather than by `1/area`.
For any triangle with area != 1, all derivatives will be wrong by a factor of `area`.
This is the most likely single root cause for the color saturation: derivatives are far too large, causing accumulators to overflow within a few pixels.

#### Observation 2: Color Promotion Bit Duplication

In `raster_attr_accum.sv` (line 464), the color promotion from 8.16 accumulator to Q4.12 output uses:

```systemverilog
out_c0r_q = {4'b0, c0r_acc[23:16], c0r_acc[23:20]};
```

The 8 integer bits `[23:16]` are placed in bits `[11:4]` of the output, and then bits `[23:20]` (the top 4 of those same 8 bits) are duplicated into `[3:0]`.
This appears to be an attempt to scale UNORM8 [0,255] to fill [0,4095], but the formula `(value << 4) | (value >> 4)` only works for the full 8-bit value, not for the top 4 bits.
For example, color value 128 (0x80) would produce `{4'b0, 8'h80, 4'h8}` = 0x0808, but the correct Q4.12 for 128/255 should be approximately 0x0808 (2056/4096 = 0.502).
Actually for value 1 (0x01): `{4'b0, 8'h01, 4'h0}` = 0x0010 (16/4096 = 0.0039), but correct would be 1/255 * 4096 = 16.06, so this is approximately correct.
The formula is: `(val << 4) | (val >> 4)` which for 8-bit val gives `val * 257/16`, close to `val * 4096/255 = val * 16.063`.
This is likely intentional but warrants validation across the full [0,255] range.

#### Observation 3: Reciprocal LUT Operand is 32-bit Signed but Q Values are 16-bit

The reciprocal LUT (`raster_recip_lut.sv`) takes a 32-bit signed `operand_in`, but Q accumulator values from `raster_attr_accum` are 32-bit fixed-point where only the top 16 bits represent Q4.12.
The edge walk module feeds `q_acc` (the full 32-bit accumulator) directly to the reciprocal LUT.
The CLZ normalization operates on bit 30 downward, so the position of the significant bits within the 32-bit word critically affects the denormalization math.
If Q is stored as Q4.28 in the accumulator (value in top 16 bits, 16 fractional extension bits below), the CLZ count and denormalization shift will differ from what the LUT expects.

#### Observation 4: Perspective Multiply Bit Extraction

In `raster_edge_walk.sv` (lines 242-245, 494-495), the perspective-corrected UV is computed as:

```systemverilog
mul_u0 = $signed(s0_acc[31:16]) * persp_recip;  // Q4.12 x Q4.12 = Q8.24
next_frag_uv0 = {mul_u0[27:12], mul_v0[27:12]}; // Extract Q4.12 from Q8.24
```

The extraction takes bits `[27:12]` from a Q8.24 product.
In Q8.24, bit 27 corresponds to the `2^3` integer position.
The extracted 16 bits `[27:12]` represent Q4.12 (4 integer + 12 fractional), which is correct if both operands are Q4.12.
However, `s0_acc[31:16]` from the accumulator is the top 16 bits of a 32-bit value whose format depends on the derivative scaling (Observation 1).

#### Observation 5: Existing Test Coverage Gaps

The existing testbenches have good structural coverage but notable gaps:

- **tb_raster_deriv**: Tests hardcoded `INV_AREA=0xFFFF` scaling only; no tests with dynamic inv_area (because no port exists).
- **tb_raster_attr_accum**: Tests at most 2-3 consecutive steps; no long-sequence drift tests.
  Color promotion tested at a few values but not swept across [0,255].
- **tb_raster_edge_walk**: Only tests a single 4x4 tile; no multi-tile grids.
  Reciprocal LUT is stubbed, not the real module.
  No tests with mixed inside/outside pixels within a tile.
- **tb_rasterizer**: Reference model for derivatives exists but assumes the hardcoded inv_area.
  No golden-value checks on fragment colors for known triangles.
  Color1 and UV1 paths are largely untested.

## Findings: Proposed Diagnostic Testbenches

Tests are organized by pipeline layer, from most foundational (reciprocal LUT) to most integrated (top-level rasterizer).
Within each layer, tests progress from simplest to most targeted.

The diagnosis strategy is: run tests in order; the first layer with failures identifies the root cause subsystem.

### Layer 1: Reciprocal LUT (`raster_recip_lut.sv`)

If the reciprocal LUT is wrong, both `inv_area` (triangle setup) and `1/Q` (perspective correction) are wrong, making all downstream results unreliable.

---

#### Test 1: `tb_recip_lut_sweep`

**Purpose:** Verify reciprocal accuracy across the full useful input range.

**Module under test:** `raster_recip_lut`

**Stimulus:**
- Feed 20-30 known 32-bit signed inputs spanning multiple orders of magnitude:
  - Small positive: `32'sd1`, `32'sd16`, `32'sd256`
  - Q4.12 range: `32'sd1024` (0.25), `32'sd2048` (0.5), `32'sd4096` (1.0), `32'sd8192` (2.0), `32'sd16384` (4.0)
  - Large: `32'sd65536`, `32'sd1048576`
  - Negative mirrors of the above
  - Zero (degenerate case)
- Assert `valid_in` for one cycle per input; wait for `valid_out`.

**Expected output:**
- For each non-zero input `x`: `recip_out` should approximate `(1/x) * 2^12` in Q4.12 format.
  Tolerance: +/-2 LSBs for values in the Q4.12 representable range.
- For zero input: `degenerate == 1`, `recip_out == 0`.
- `valid_out` asserts exactly 1 cycle after `valid_in`.

**Pass/fail criteria:**
- All outputs within tolerance of reference `1/x` computation.
- `clz_out` matches independently computed CLZ of `|operand_in|`.

**Diagnoses:** Reciprocal LUT ROM contents, linear interpolation, CLZ priority encoder, sign handling.

---

#### Test 2: `tb_recip_lut_clz_lod`

**Purpose:** Verify the CLZ-to-LOD mapping specifically, since LOD drives mipmap level selection.

**Module under test:** `raster_recip_lut`

**Stimulus:**
- Feed inputs that exercise every CLZ count from 0 to 30:
  - `clz=0`: `operand_in = 32'sh4000_0000` (bit 30 set)
  - `clz=1`: `operand_in = 32'sh2000_0000` (bit 29 set)
  - ...continue through...
  - `clz=29`: `operand_in = 32'sh0000_0002` (bit 1 set)
  - `clz=30`: `operand_in = 32'sh0000_0001` (bit 0 set)
  - `clz=31`: `operand_in = 32'sh0000_0000` (zero)

**Expected output:**
- `clz_out` == expected CLZ count for each input.
- `recip_out` consistent with `2^(clz-33)` scaling per the denormalization formula.
- For `clz >= 30`, verify output does not overflow Q4.12 range.

**Pass/fail criteria:** Exact match on `clz_out`; `recip_out` within +/-2 LSBs of analytical value.

**Diagnoses:** CLZ priority encoder correctness, denormalization shift `shifted_recip[46:33]`, LOD accuracy.

---

#### Test 3: `tb_recip_lut_denorm`

**Purpose:** Verify the denormalization path independently by testing inputs where the LUT lookup is trivial (index 0, mantissa = 1.0).

**Module under test:** `raster_recip_lut`

**Stimulus:**
- Feed inputs that are exact powers of 2 (so LUT index = 0, fraction = 0, `raw_recip = 0x8000`):
  - `32'sd1`, `32'sd2`, `32'sd4`, `32'sd8`, ..., `32'sd1073741824`
- Also test `32'sd3`, `32'sd5`, `32'sd7` (non-power-of-2 to exercise interpolation).

**Expected output:**
- For power-of-2 inputs: `recip_out` should be exact (no interpolation error).
  E.g., input=4096 (Q4.12 = 1.0) should give `recip_out = 4096` (1.0 in Q4.12).
  Input=8192 (Q4.12 = 2.0) should give `recip_out = 2048` (0.5 in Q4.12).
- For non-power-of-2: verify interpolation reduces error vs. nearest LUT entry.

**Pass/fail criteria:** Exact match for power-of-2 inputs; +/-1 LSB for non-power-of-2.

**Diagnoses:** Denormalization shift math correctness, interaction between CLZ and bit extraction `[46:33]`.

---

### Layer 2: Derivative Computation (`raster_deriv.sv`)

If derivatives are wrong, all interpolated attributes (color, Z, UV, Q) are wrong everywhere.

---

#### Test 4: `tb_deriv_uniform_color`

**Purpose:** Verify that uniform vertex attributes produce zero derivatives.

**Module under test:** `raster_deriv`

**Stimulus:**
- All three vertices have identical attributes:
  - `c0_r0 = c0_r1 = c0_r2 = 128` (and similarly all other color channels)
  - `z0 = z1 = z2 = 32768`
  - `uv0_u0 = uv0_u1 = uv0_u2 = 16'sh1000` (1.0 in Q4.12)
  - `q0 = q1 = q2 = 16'h1000`
- Edge coefficients: `edge1_A = 10, edge1_B = -5, edge2_A = -8, edge2_B = 12` (non-trivial but arbitrary).
- `bbox_min_x = x0 = 10`, `bbox_min_y = y0 = 10`.

**Expected output:**
- All 26 derivative outputs (`pre_*_dx`, `pre_*_dy`) == 0.
- All 13 initial values == vertex value positioned in 8.16 or 16.16 format:
  - `init_c0r` == `{8'b0, 8'd128, 16'b0}` == `32'h0080_0000`
  - `init_z` == `{16'd32768, 16'b0}` == `32'h8000_0000`
  - `init_uv0u` == `{16'sh1000, 16'b0}` == `32'sh1000_0000`

**Pass/fail criteria:** Exact match (zero derivatives, exact initial values).

**Diagnoses:** Delta computation (should be zero when values are equal), initial value positioning.

---

#### Test 5: `tb_deriv_horizontal_gradient`

**Purpose:** Verify derivative computation for a simple case where one attribute varies only in X.

**Module under test:** `raster_deriv`

**Stimulus:**
- Right triangle: v0=(0,0), v1=(100,0), v2=(0,100).
- `edge1_A = y2-y0 = 100`, `edge1_B = x0-x2 = 0`, `edge2_A = y0-y1 = 0`, `edge2_B = x1-x0 = 100`.
- Color: `c0_r0 = 0`, `c0_r1 = 200`, `c0_r2 = 0`.
  All other attributes uniform (zero derivative expected).
- `bbox_min_x = 0, bbox_min_y = 0, x0 = 0, y0 = 0`.

**Expected output:**
- `pre_c0r_dx` should be non-zero (positive, proportional to 200/100 scaled by inv_area).
- `pre_c0r_dy` should be approximately zero (color varies only in X for this geometry).
- All other attribute derivatives should be zero.
- `init_c0r` should equal `{8'b0, 8'd0, 16'b0}` since bbox origin == v0.

**Pass/fail criteria:**
- `pre_c0r_dy == 0` (exact).
- `pre_c0r_dx` matches analytical: `d10_c0r * edge1_A * INV_AREA` (with current hardcoded INV_AREA).
- All other derivatives == 0 (exact).

**Diagnoses:** Core derivative formula, cross-product cancellation, single-axis gradient correctness.

---

#### Test 6: `tb_deriv_known_triangle`

**Purpose:** Full derivative verification against hand-computed golden values for all 13 attributes.

**Module under test:** `raster_deriv`

**Stimulus:**
- Right triangle: v0=(10,10), v1=(30,10), v2=(10,30).
- Edge coefficients: `edge1_A = 20`, `edge1_B = 0`, `edge2_A = 0`, `edge2_B = 20` (for this geometry, computed from vertex differences).
- Vertex attributes chosen for easy hand computation:
  - `c0_r`: 0, 100, 0 (gradient in X only)
  - `c0_g`: 0, 0, 100 (gradient in Y only)
  - `c0_b`: 50, 50, 50 (uniform)
  - `c0_a`: 255, 0, 128 (gradient in both)
  - `z`: 0, 65535, 32768
  - `uv0_u`: 0, 0x2000 (2.0), 0
  - `uv0_v`: 0, 0, 0x2000 (2.0)
  - `q`: 0x1000, 0x2000, 0x1000 (1.0, 2.0, 1.0)
- `bbox_min_x = 10, bbox_min_y = 10` (same as v0).

**Expected output:**
- Analytical derivatives computed offline for each attribute, accounting for hardcoded `INV_AREA = 0xFFFF` and `AREA_SHIFT = 0`.
- Print all 26 derivatives and 13 initial values as hex for manual inspection even if checks pass.

**Pass/fail criteria:** All 39 outputs match golden values exactly.

**Diagnoses:** Complete derivative pipeline including wide-channel (Z, UV, Q) paths, initial value computation, edge coefficient interaction.

---

### Layer 3: Attribute Accumulation (`raster_attr_accum.sv`)

If stepping or promotion is wrong, interpolated fragment values will be incorrect even with correct derivatives.

---

#### Test 7: `tb_accum_color_ramp`

**Purpose:** Verify that stepping produces a linear color ramp with correct Q4.12 output at each step.

**Module under test:** `raster_attr_accum`

**Stimulus:**
- Latch `init_c0r = {8'b0, 8'd0, 16'b0}` (color 0) with `dx = {8'b0, 8'd1, 16'b0}` (increment by 1.0 in 8.16 format per step), `dy = 0`.
- Perform 255 consecutive `step_x` operations.
- After each step, record `out_c0r`.

**Expected output:**
- Step 0: `out_c0r` == promotion of color 0
- Step 1: `out_c0r` == promotion of color 1
- Step 128: `out_c0r` == promotion of color 128
- Step 255: `out_c0r` == promotion of color 255 (should be 0x0FFF or near it)
- The ramp should be monotonically increasing.

**Pass/fail criteria:**
- Each step's output matches the promotion formula: `{4'b0, acc[23:16], acc[23:20]}`.
- No unexpected clamping before step 256.
- Verify monotonicity.

**Diagnoses:** Accumulator addition correctness, promotion formula across full [0,255] range, potential for premature clamping.

---

#### Test 8: `tb_accum_clamp_bounds`

**Purpose:** Verify that overflow and underflow clamp correctly rather than wrapping.

**Module under test:** `raster_attr_accum`

**Stimulus:**
- **Overflow test:** Latch `init_c0r = {8'b0, 8'd250, 16'b0}` (color 250), `dx = {8'b0, 8'd10, 16'b0}` (increment 10 per step).
  Step 1: color 260 (overflow). Step 2: color 270. Continue 5 steps.
- **Underflow test:** Latch `init_c0r = {8'b0, 8'd5, 16'b0}` (color 5), `dx = -{8'b0, 8'd10, 16'b0}` (decrement 10 per step).
  Step 1: color -5 (underflow). Continue 5 steps.
- **Z overflow:** Latch `init_z = {16'hFFF0, 16'b0}`, `dz = {16'h0020, 16'b0}`. Step until overflow.
- **Z underflow:** Latch `init_z = {16'h0010, 16'b0}`, `dz = -{16'h0020, 16'b0}`. Step once.

**Expected output:**
- Color overflow: `out_c0r` clamps to `16'h0FFF` and stays there.
- Color underflow: `out_c0r` clamps to `16'h0000` and stays there.
- Z overflow: `out_z` wraps or clamps (document actual behavior).
- Z underflow: `out_z` clamps to `16'h0000`.

**Pass/fail criteria:** Clamped outputs match the promotion/clamp logic in lines 459-465 of `raster_attr_accum.sv`.

**Diagnoses:** Clamping correctness for colors and Z; whether the cyan saturation is caused by incorrect clamping.

---

#### Test 9: `tb_accum_step_y_reload`

**Purpose:** Verify that `step_y` correctly reloads the accumulator from the row register plus dy.

**Module under test:** `raster_attr_accum`

**Stimulus:**
- Latch `init_c0r = {8'b0, 8'd10, 16'b0}`, `dx = {8'b0, 8'd2, 16'b0}`, `dy = {8'b0, 8'd5, 16'b0}`.
- Sequence: `step_x` x3 (acc = 10+2+2+2=16), then `step_y` (acc should reload to row+dy = 10+5=15, NOT 16+5=21).
- Then `step_x` x3 again (acc = 15+2+2+2=21), then `step_y` (acc = 15+5=20).

**Expected output:**
- After 3x step_x: `out_c0r` == promotion of 16.
- After step_y: `out_c0r` == promotion of 15 (row register was 10, now 10+5=15).
- After 3x step_x: `out_c0r` == promotion of 21.
- After step_y: `out_c0r` == promotion of 20 (row was 15, now 15+5=20).

**Pass/fail criteria:** Exact match at each step.

**Diagnoses:** Row register vs. accumulator distinction, step_y reload logic, multi-row traversal correctness.

---

#### Test 10: `tb_accum_extended_walk`

**Purpose:** Detect accumulator drift over many steps (simulating a large triangle).

**Module under test:** `raster_attr_accum`

**Stimulus:**
- Latch `init_c0r` with color 0, `dx` with a small fractional increment (e.g., `32'sh0000_0100` = 1/256 in 8.16).
- Perform 512 consecutive `step_x` operations.
- Expected final accumulator: `0 + 512 * (1/256) = 2.0` in 8.16 = `{8'b0, 8'd2, 16'b0}`.

**Expected output:**
- Final `out_c0r` == promotion of color value 2.
- Sample intermediate values at steps 0, 128, 256, 384, 512 for monotonicity.

**Pass/fail criteria:**
- Final value matches analytical expectation exactly (integer arithmetic, no rounding).
- No unexpected saturation or wrap-around.

**Diagnoses:** 32-bit accumulator precision over long walks, absence of truncation in addition path.

---

### Layer 4: Edge Walk (`raster_edge_walk.sv`)

If the iterator visits wrong pixels or in wrong order, fragment positions and interpolated values are both wrong.

---

#### Test 11: `tb_edge_walk_single_tile`

**Purpose:** Verify pixel-level correctness for the simplest possible walk: a triangle fitting within one 4x4 tile.

**Module under test:** `raster_edge_walk`

**Stimulus:**
- Small right triangle: bbox (0,0)-(3,3) (one tile).
- Edge coefficients chosen so that approximately half the pixels are inside (e.g., upper-left triangle of the 4x4 grid).
- All attribute inputs set to constant values (uniform color, Q=1.0).
- `frag_ready = 1` (no backpressure).
- Stub reciprocal LUT: return `recip_out = 16'sh1000` (1.0 in Q4.12), `clz_out = 5'd18`.

**Expected output:**
- Collect all emitted `(frag_x, frag_y)` pairs.
- Compare against analytical set: pixels where `e0 >= 0 && e1 >= 0 && e2 >= 0`.
- Print a 4x4 text grid showing hit ('X') vs miss ('.') for visual inspection.
- `frag_tile_start` asserted on first fragment only.
- `frag_tile_end` asserted when last pixel (3,3) is processed (if inside) or not asserted if (3,3) is outside.

**Pass/fail criteria:**
- Fragment set matches analytical inside-pixel set exactly.
- No extra or missing fragments.
- Tile boundary flags correct.

**Diagnoses:** Edge function evaluation, inside_triangle test, pixel iteration within a single tile.

---

#### Test 12: `tb_edge_walk_multi_tile`

**Purpose:** Verify correct tile-to-tile traversal across a multi-tile bounding box with mixed rejection.

**Module under test:** `raster_edge_walk`

**Stimulus:**
- Triangle spanning a 3x3 grid of tiles (12x12 pixel bbox, tiles at (0,0), (4,0), (8,0), (0,4), ..., (8,8)).
- Edge coefficients chosen so that corner tiles are rejected (outside triangle) and center tiles pass.
- `frag_ready = 1`.
- Stub reciprocal LUT as in Test 11.

**Expected output:**
- Rejected tiles produce zero fragments.
- Accepted tiles produce correct inside-pixel fragments.
- Tile traversal order is row-major (left-to-right, top-to-bottom).
- `attr_step_x` and `attr_step_y` pulse counts match expected pixel traversal.
- `walk_done` asserts after last tile.

**Pass/fail criteria:**
- Total fragment count matches analytical count.
- No fragments outside triangle bounds.
- Tile order is monotonically row-major.

**Diagnoses:** Tile rejection logic, tile-boundary edge function update (`e_row - 3*B + 4*A`), multi-tile iteration correctness.

---

#### Test 13: `tb_edge_walk_attr_step_sync`

**Purpose:** Verify that `attr_step_x` and `attr_step_y` fire at the correct times relative to pixel position changes.

**Module under test:** `raster_edge_walk`

**Stimulus:**
- Single 4x4 tile where all 16 pixels are inside the triangle.
- Monitor `attr_step_x`, `attr_step_y`, `curr_x`, `curr_y` every clock cycle.
- `frag_ready = 1`.

**Expected output:**
- `attr_step_x` pulses exactly when `curr_x` increments (px 0->1, 1->2, 2->3).
- `attr_step_y` pulses exactly when `curr_y` increments and `curr_x` resets (py 0->1, 1->2, 2->3).
- Total `attr_step_x` count == 12 (3 per row x 4 rows).
- Total `attr_step_y` count == 3 (3 row transitions).
- No step pulses occur during PERSP_1, PERSP_2, or EMIT states.

**Pass/fail criteria:** Exact step counts and timing alignment.

**Diagnoses:** Attribute/edge walk synchronization, off-by-one in step timing.

---

### Layer 5: Perspective Correction

If 1/Q or the UV multiply is wrong, all textured rendering is broken (explaining the all-white output).

---

#### Test 14: `tb_persp_correction_identity`

**Purpose:** Verify that Q=1.0 at all vertices produces pass-through UV values (no perspective distortion).

**Module under test:** `raster_edge_walk` (with real `raster_recip_lut` instance, or testbench computing expected values from the stub)

**Stimulus:**
- Single-tile triangle, all pixels inside.
- `q_acc = 32'sh1000_0000` (Q4.12 = 1.0 in top 16 bits of 32-bit accumulator) at every pixel (zero Q derivatives).
- `s0_acc = 32'sh2000_0000` (U=2.0 in top 16 bits), `t0_acc = 32'sh0800_0000` (V=0.5 in top 16 bits).
- Stub reciprocal LUT: `recip_out = 16'sh1000` (1/1.0 = 1.0 in Q4.12).

**Expected output:**
- `frag_uv0[31:16]` (U) == `16'sh2000` (2.0 in Q4.12).
- `frag_uv0[15:0]` (V) == `16'sh0800` (0.5 in Q4.12).
- Same for every emitted fragment (uniform UV).

**Pass/fail criteria:** Exact match for all fragments.

**Diagnoses:** Perspective multiply path when 1/Q = 1.0, bit extraction `[27:12]` from Q8.24 product.

---

#### Test 15: `tb_persp_correction_known`

**Purpose:** Verify perspective correction with non-trivial Q values against hand-computed golden results.

**Module under test:** `raster_edge_walk` (or top-level `rasterizer`)

**Stimulus:**
- 3 test pixels with different Q values:
  - Pixel A: `q_acc` top 16 = `16'sh1000` (Q=1.0), `s0_acc` top 16 = `16'sh2000` (S=2.0).
    Expected: `frag_uv0_u = S * (1/Q) = 2.0 * 1.0 = 2.0` = `16'sh2000`.
  - Pixel B: `q_acc` top 16 = `16'sh2000` (Q=2.0), `s0_acc` top 16 = `16'sh2000` (S=2.0).
    Expected: `frag_uv0_u = 2.0 * 0.5 = 1.0` = `16'sh1000`.
  - Pixel C: `q_acc` top 16 = `16'sh0800` (Q=0.5), `s0_acc` top 16 = `16'sh1000` (S=1.0).
    Expected: `frag_uv0_u = 1.0 * 2.0 = 2.0` = `16'sh2000`.
- Stub or use real reciprocal LUT with known outputs.

**Expected output:** Fragment UV values match analytical perspective-corrected results within +/-2 LSBs.

**Pass/fail criteria:** UV outputs within tolerance for all 3 test cases.

**Diagnoses:** Full perspective correction chain: Q accumulator -> 1/Q lookup -> S*(1/Q) multiply -> bit extraction.

---

#### Test 16: `tb_persp_mul_bit_extract`

**Purpose:** Specifically verify the `[27:12]` bit extraction from the 32-bit perspective multiply product.

**Module under test:** `raster_edge_walk` (perspective multiply section only, or full module)

**Stimulus:**
- Construct input pairs where the Q8.24 product has known bit patterns:
  - `s0_acc[31:16] = 16'sh1000` (1.0), `persp_recip = 16'sh1000` (1.0): product = `32'sh0100_0000`.
    Bits `[27:12]` = `16'sh1000` (1.0). Correct.
  - `s0_acc[31:16] = 16'sh7FFF` (max positive ~8.0), `persp_recip = 16'sh1000` (1.0): product = `32'sh07FFF000`.
    Bits `[27:12]` = `16'sh7FFF`. Correct.
  - `s0_acc[31:16] = 16'sh8000` (max negative = -8.0), `persp_recip = 16'sh1000` (1.0): product = `32'sh8000_0000` (signed).
    Bits `[27:12]`: verify sign extension behavior.

**Expected output:** Extracted bits match analytical Q4.12 values for each test case.

**Pass/fail criteria:** Exact match.

**Diagnoses:** Signed multiply behavior, bit extraction alignment, sign handling in perspective products.

---

### Layer 6: Top-Level Integration (`rasterizer.sv`)

These tests exercise the full pipeline with the simplest possible inputs to isolate wiring and sequencing issues.

---

#### Test 17: `tb_rasterizer_flat_red`

**Purpose:** Verify that a triangle with uniform color produces uniform fragment output (the simplest possible end-to-end test).

**Module under test:** `rasterizer` (top-level)

**Stimulus:**
- Triangle: v0=(10,10), v1=(30,10), v2=(20,30) — small, well-behaved.
- All vertices: `color0 = 32'hFF000000` (R=255, G=0, B=0, A=0).
  `color1 = 32'h00000000`. `uv0 = uv1 = 32'h0`. `q = 16'h1000` (1.0). `z = 16'h8000`.
- `fb_width_log2 = 9, fb_height_log2 = 9` (512x512).
- `frag_ready = 1`.

**Expected output:**
- Every emitted fragment should have:
  - `frag_color0[63:48]` (R) == promotion of 255 == `16'h0FFF` (or the correct promoted value).
  - `frag_color0[47:32]` (G) == `16'h0000`.
  - `frag_color0[31:16]` (B) == `16'h0000`.
  - `frag_color0[15:0]` (A) == `16'h0000`.
- At least 1 fragment emitted (triangle is not degenerate).
- Fragment positions within bbox of the triangle.

**Pass/fail criteria:**
- All fragments have identical color0 values matching the promoted vertex color.
- Any deviation indicates wiring or derivative scaling issues.

**Diagnoses:** End-to-end path from vertex input through derivative (should be zero) -> accumulation -> promotion -> fragment bus.
This test directly reveals whether the inv_area disconnect causes problems even for uniform-color triangles (it shouldn't, since derivatives should be zero regardless of inv_area when all vertices have the same color).

---

#### Test 18: `tb_rasterizer_color_gradient`

**Purpose:** Verify that a triangle with a simple color gradient produces smoothly varying fragment output.

**Module under test:** `rasterizer` (top-level)

**Stimulus:**
- Triangle: v0=(0,0), v1=(40,0), v2=(0,40) — right triangle at origin.
- Vertex colors: v0 red (255,0,0), v1 green (0,255,0), v2 blue (0,0,255).
  `color1` all zero, `uv0 = uv1 = 0`, `q = 16'h1000`, `z = 16'h8000`.
- `fb_width_log2 = 6` (64x64 surface).

**Expected output:**
- Capture all fragment `(x, y, color0)` tuples.
- At v0 position (0,0): color should be close to red (high R, low G, low B).
- At midpoints: colors should be interpolated blends.
- Key check: **no saturation to max values** except at vertices. If the gradient immediately saturates to cyan (max G + max B) as seen in the current gouraud image, this test catches it.
- Optional: dump fragment data to a CSV for offline plotting.

**Pass/fail criteria:**
- R channel decreases monotonically moving away from v0.
- G channel increases monotonically moving toward v1.
- B channel increases monotonically moving toward v2.
- No channel exceeds `16'h0FFF` or drops below `16'h0000` for interior pixels.

**Diagnoses:** The core interpolation defect visible in the gouraud image.
This test will fail if inv_area is not correctly scaling derivatives.

---

#### Test 19: `tb_rasterizer_inv_area_check`

**Purpose:** Verify that the computed `inv_area` register receives the correct value from the reciprocal LUT.

**Module under test:** `rasterizer` (top-level, inspecting internal signals)

**Stimulus:**
- Three triangles with known areas:
  - Triangle A: v0=(0,0), v1=(10,0), v2=(0,10). Area = 50 (half of 10x10). `2*area = 100`.
  - Triangle B: v0=(0,0), v1=(100,0), v2=(0,100). Area = 5000. `2*area = 10000`.
  - Triangle C: v0=(0,0), v1=(4,0), v2=(0,4). Area = 8. `2*area = 16`.

**Expected output:**
- After SETUP_RECIP state for each triangle, read `dut.inv_area` via hierarchical access.
- Triangle A: `inv_area` should approximate `1/100` in Q4.12 = ~41.
- Triangle B: `inv_area` should approximate `1/10000` in Q4.12 = ~0 (very small).
- Triangle C: `inv_area` should approximate `1/16` in Q4.12 = 256.
- Also verify `triangle_area` intermediate signal matches expected `2*area`.

**Pass/fail criteria:**
- `triangle_area` matches expected value exactly.
- `inv_area` matches reciprocal LUT output for that area (within LUT precision).

**Diagnoses:** Triangle area computation from edge coefficients, reciprocal LUT integration for inv_area, SETUP_RECIP state latching.
**Note:** This test will show that `inv_area` IS computed correctly in `rasterizer.sv` but is NOT passed to `raster_deriv.sv`.

---

#### Test 20: `tb_rasterizer_color1_path`

**Purpose:** Verify that the Color1 interpolation path works (currently largely untested in existing testbenches).

**Module under test:** `rasterizer` (top-level)

**Stimulus:**
- Same triangle geometry as Test 17 (flat color, small triangle).
- `color0 = 32'h00000000` (all zero).
- `color1 = 32'h00FF0000` (G=255 only in color1).
- All other attributes as in Test 17.

**Expected output:**
- `frag_color0` == all zeros for every fragment (uniform zero input).
- `frag_color1[47:32]` (G channel) == promotion of 255 for every fragment.
- All other `frag_color1` channels == 0.

**Pass/fail criteria:** Uniform color1 output matching promoted vertex values.

**Diagnoses:** Color1 derivative/accumulation/promotion path is wired identically to Color0; confirms no wiring errors in the second color channel.

---

### Supplemental Tests

These tests target specific concerns that cut across layers.

---

#### Test S1: `tb_edge_walk_backpressure_resume`

**Purpose:** Verify that fragment data remains stable during backpressure and that the walk resumes correctly.

**Module under test:** `raster_edge_walk`

**Stimulus:**
- Single-tile triangle with all 16 pixels inside.
- Pattern: accept 3 fragments (frag_ready=1), then stall for 10 cycles (frag_ready=0), then resume.
- During stall, sample `frag_x`, `frag_y`, `frag_z`, `frag_color0`, `frag_uv0` every cycle.

**Expected output:**
- During stall: all fragment outputs remain stable (same values every cycle).
- `frag_valid` remains asserted during stall.
- After resume: next fragment is the correct 4th pixel (not a repeat, not a skip).
- Total fragment count after walk completes == 16.

**Pass/fail criteria:**
- Output stability during stall (no bit flips).
- Correct fragment sequence after resume.

**Diagnoses:** DD-025 handshake compliance, registered output stability, FSM resume from EW_EMIT.

---

#### Test S2: `tb_rasterizer_degenerate_triangles`

**Purpose:** Verify that degenerate triangles (zero area, collinear, single-point) produce zero fragments and do not hang the FSM.

**Module under test:** `rasterizer` (top-level)

**Stimulus:**
- Triangle A: all three vertices at the same point (0,0).
- Triangle B: collinear vertices (0,0), (10,0), (20,0).
- Triangle C: two vertices coincident: (10,10), (10,10), (20,20).
- For each, submit and wait up to 1000 cycles for `tri_ready` to reassert.

**Expected output:**
- Zero fragments emitted for each triangle.
- FSM returns to IDLE and `tri_ready` reasserts within a bounded cycle count.
- No hangs or infinite loops.

**Pass/fail criteria:**
- Fragment count == 0 for each degenerate triangle.
- FSM recovers within 100 cycles of submission.

**Diagnoses:** Zero-area detection via reciprocal LUT degenerate flag, FSM recovery path.

---

## Diagnosis Strategy

Run the tests in layer order.
The first layer with failures identifies the root cause subsystem:

| Tests Failing | Root Cause Area | Likely Visible Symptom |
|---|---|---|
| 1-3 (Reciprocal LUT) | 1/x computation wrong | Both inv_area and perspective correction broken |
| 4-6 (Derivatives) | Derivative math wrong | All interpolation broken |
| 7-10 (Accumulation) | Stepping or promotion wrong | Color saturation, incorrect gradients |
| 11-13 (Edge Walk) | Wrong pixels visited | Missing/extra fragments, wrong positions |
| 14-16 (Perspective) | UV correction wrong | White/wrong textures |
| 17-20 (Integration) | Wiring between submodules | Symptoms depend on which wiring is broken |
| S1-S2 (Supplemental) | Protocol or edge cases | Hangs, data corruption under backpressure |

### Predicted Outcomes Based on RTL Observations

Given the observations documented above, these are the predicted test outcomes:

1. **Tests 1-3 (Reciprocal LUT):** Expected to PASS — the LUT itself appears correctly implemented.
2. **Tests 4-6 (Derivatives):** Test 4 (uniform color) may PASS (zero derivatives don't need inv_area), but Tests 5-6 will likely produce incorrect derivative magnitudes because `INV_AREA` is hardcoded.
3. **Tests 7-10 (Accumulation):** Expected to PASS in isolation (when fed correct derivatives), but will show saturation if fed the actual oversized derivatives from raster_deriv.
4. **Tests 11-13 (Edge Walk):** Expected to PASS — tile iteration logic appears sound.
5. **Tests 14-16 (Perspective):** Depends on whether `q_acc` format matches what the reciprocal LUT expects.
6. **Test 18 (Color Gradient):** Expected to FAIL — will reproduce the cyan saturation seen in `gouraud_triangle.png`.
7. **Test 19 (inv_area Check):** Expected to reveal that `inv_area` is computed correctly in `rasterizer.sv` but never reaches `raster_deriv.sv`.

## Conclusions

1. **The most impactful single issue** is the disconnected `inv_area` path between `rasterizer.sv` and `raster_deriv.sv` (Observation 1).
   Tests 5, 6, 18, and 19 are specifically designed to expose this.

2. **The all-white texture output** is likely a compound effect of wrong derivatives (Observation 1) and potentially wrong perspective correction operand format (Observation 3).
   Tests 14-16 isolate the perspective path independent of derivative errors.

3. **The existing testbenches are structurally sound** but test against the hardcoded `INV_AREA` placeholder, meaning they validate the *interim Phase 1 behavior* rather than the *intended Phase 2 behavior*.
   The integrated testbench (`tb_rasterizer.sv`) has a reference derivative model that also uses the hardcoded constant.

4. **The color promotion formula** (Observation 2) appears to be mathematically reasonable for UNORM8-to-Q4.12 conversion but should be validated across the full [0,255] range by Test 7.

5. **20 tests total** (12 original + 6 additional + 2 supplemental) provide layer-by-layer isolation of every rasterizer subsystem with minimal redundancy.

## Recommendations

1. **Implement tests in layer order** (reciprocal LUT first, integration last) so that foundational correctness is established before testing composed behavior.

2. **Tests 17 and 18 are the highest-value pair:** Test 17 (flat red) should pass even with the inv_area bug (zero derivatives), while Test 18 (gradient) should fail, clearly demonstrating the derivative scaling issue.

3. **Test 19** should be implemented early as a diagnostic probe — it will confirm or deny whether `inv_area` is the root cause without requiring any RTL changes.

4. After tests confirm root causes, use findings as context for a `/syskit-impact` analysis to determine which specifications need updating before implementing fixes.
