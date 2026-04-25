# VER-001: Rasterizer Unit Testbench

## Verification Method

**Test:** Verified by executing the `tb_rasterizer` Verilator simulation testbench against the rasterizer RTL (UNIT-005).
The testbench drives known triangle configurations through the triangle setup and edge-walking pipeline, then checks computed values and fragment output against reference data.

## Verifies Requirements

- REQ-002.03 (Rasterization Algorithm)

## Verified Design Units

- UNIT-005 (Rasterizer — including UNIT-005.05 Hi-Z tile rejection state)

## Preconditions

- Triangle setup module (UNIT-005.01) is instantiated or stubbed so that the rasterizer receives valid setup data.
- The testbench drives `fb_width_log2` and `fb_height_log2` register inputs (from UNIT-003) to configure the active surface dimensions before each test case.
- The rasterizer computes inv_area internally via a dedicated reciprocal module (`raster_recip_area.sv`, DP16KD 36×512 mode) in UNIT-005.02; the testbench does not supply `setup_inv_area` as an external input.
- Per-pixel 1/Q is computed by a separate dedicated reciprocal module (`raster_recip_q.sv`, DP16KD 18×1024 mode) in UNIT-005.05.
- A setup-iteration overlap FIFO (compile-time configurable depth, default 2) allows triangle N+1 setup to proceed concurrently with triangle N iteration.

## Procedure

1. **Edge function coefficient verification.**
   Drive the rasterizer with a known triangle (three vertex positions with pre-computed reference values).
   After triangle setup completes, read back the computed edge function coefficients A (11-bit), B (11-bit), and C (21-bit) for all three edges.
   Compare each coefficient against reference values computed offline.

2. **Bounding box clamping.**
   Submit triangles that extend partially or fully outside the configured surface boundaries.
   Verify that the bounding box X coordinate is clamped to `[0, (1 << fb_width_log2) - 1]` and the Y coordinate is clamped to `[0, (1 << fb_height_log2) - 1]`.
   Execute this step for two surface configurations:

   a. **512×512 surface** (`fb_width_log2 = 9`, `fb_height_log2 = 9`): clamp bounds are [0, 511] × [0, 511].
      Test cases: triangle extending past the right edge (X > 511), past the bottom edge (Y > 511), past the top-left corner, and a triangle fully within bounds.

   b. **256×256 surface** (`fb_width_log2 = 8`, `fb_height_log2 = 8`): clamp bounds are [0, 255] × [0, 255].
      Test cases: triangle extending past the right edge (X > 255) and a triangle fully within bounds.

   For each case, verify the bounding box after clamping does not exceed the configured surface boundary.

3. **Fragment emission count and traversal order.**
   Drive the rasterizer with a triangle of known area.
   Count the number of fragment emission pulses (fragment_valid assertions on the output handshake bus) during edge walking.
   Compare the count against a reference pixel count for the test triangle.
   The count must be exact (no tolerance).
   Additionally, verify that fragments within the bounding box are emitted in 4×4 tile-major order: the rasterizer walks 4×4 pixel tiles across the bounding box in raster order, emitting all covered pixels within each tile before advancing to the next tile.

4. **Incremental interpolation accuracy.**
   For a triangle with distinct vertex colors, Z values, UV coordinates, and Q (1/W) values, the rasterizer initializes per-attribute derivative values at triangle setup time and advances them incrementally per 4×4 tile and per pixel within each tile.
   Sample the interpolated output on the fragment output bus at:
   - Each of the three vertices.
   - The centroid.
   - Edge midpoints.
   Verify that the following 14 interpolated attributes match reference values within 1 ULP of the fixed-point derivative step precision:
   - 3 edge function values
   - Z depth
   - Q (1/W)
   - R/G/B/A of color0
   - R/G/B/A of color1 (Gouraud mode)
   - S0/T0 and S1/T1 perspective-projected texture coordinates
   UV0 and UV1 coordinates on the fragment output bus (`frag_uv0`, `frag_uv1`) carry true perspective-correct U,V values in Q4.12 (16-bit signed, 4 integer bits, 12 fractional bits) as defined in `fp_types_pkg.sv`.
   The rasterizer performs perspective correction internally: S×(1/Q) and T×(1/Q) are computed via the dedicated per-pixel reciprocal module (`raster_recip_q.sv`) and 4 MULT18X18D blocks before the fragment is emitted.
   `frag_lod` (UQ4.4) is present on the fragment bus; its value is derived from CLZ applied to Q at the pixel location.
   `frag_q` is not present on the fragment bus.
   Reference values are computed offline using the same incremental step model (not the barycentric MAC model), with UV values in Q4.12 representing true perspective-correct coordinates.

5. **Fragment output bus handshake.**
   Verify that the rasterizer emits fragments using the valid/ready handshake protocol on the fragment output bus.
   Assert `ready = 0` from the consumer side for several cycles while fragments are being generated, then assert `ready = 1`.
   Verify that the rasterizer does not advance to the next fragment while `ready = 0` (back-pressure is respected) and that no fragments are dropped when `ready` deasserts and reasserts.

6. **Degenerate triangle handling.**
   Submit the following degenerate cases and verify correct behavior (using `fb_width_log2 = 9`, `fb_height_log2 = 9`):
   - Zero-area triangle (all three vertices collinear): rasterizer should emit zero fragments.
   - Single-pixel triangle (three vertices that enclose exactly one pixel center): rasterizer should emit exactly one fragment.
   - Fully off-screen triangle (all vertices outside the configured surface bounds): rasterizer should emit zero fragments after bounding box clamp results in an empty region.

7. **Winding order.**
   Submit the same triangle in both clockwise and counter-clockwise winding order.
   Verify that edge function signs are consistent with the expected winding convention and that fragment emission occurs for the correct winding.

8. **Hi-Z tile rejection.**
   Pre-populate the Hi-Z metadata for a set of 4×4 tiles with a known min_z value (e.g., `0x40` in the 9-bit Z[15:7] field, corresponding to Z ≈ `0x4000`).
   Submit a triangle whose bounding box covers those tiles, configured with Z_TEST_EN=1 and a per-vertex Z value larger than the stored min_z (e.g., `0x8000`), so the LEQUAL comparison `fragment_z[15:7] <= min_z[8:0]` fails for every tile.
   Verify that the rasterizer emits zero fragments for those tiles — the HIZ_TEST FSM state must skip all covered tiles without entering EDGE_TEST.

   Then submit the same triangle with a per-vertex Z value smaller than the stored min_z (e.g., `0x2000`).
   Verify that the rasterizer emits the expected fragments for those tiles, passing through EDGE_TEST normally.

   Finally, submit a triangle that overlaps tiles whose Hi-Z metadata contains the sentinel value `9'h1FF` (all-ones, meaning uninitialized — no writes recorded yet) alongside tiles with a valid min_z value.
   Verify that tiles with the sentinel value are not rejected by Hi-Z — they must proceed to EDGE_TEST unconditionally, regardless of the incoming fragment Z.

## Expected Results

- **Pass Criteria:**
  - All edge function coefficients (A, B, C) for each edge match reference values exactly.
  - Bounding box X coordinate is clamped to `[0, (1 << fb_width_log2) - 1]` and Y coordinate to `[0, (1 << fb_height_log2) - 1]` for each configured surface size (512×512 and 256×256).
  - Fragment emission counts match reference pixel counts exactly for all test triangles.
  - Fragments are emitted in 4×4 tile-major order: all covered pixels within a tile are emitted before the rasterizer advances to the next tile.
  - Interpolated color, Z, UV0, UV1 (Q4.12 true perspective-correct U,V), and `frag_lod` (UQ4.4) values at vertices, centroid, and midpoints match reference values within 1 ULP of the fixed-point derivative step precision.
  - `frag_q` is absent from the fragment output bus; `frag_lod` (UQ4.4) is present and matches the CLZ-on-Q reference.
  - All 14 attributes (3 edge functions, Z, Q, RGBA color0, RGBA color1, S0/T0/S1/T1) step correctly across the triangle.
  - Back-pressure on the fragment output bus (`ready = 0`) halts fragment emission without loss or duplication.
  - Degenerate triangles produce the expected fragment count (0 or 1 as specified).
  - Winding order tests produce consistent edge function signs.
  - Hi-Z rejection: tiles with a valid (non-sentinel) min_z and fragment_z > min_z produce zero fragment emissions; the HIZ_TEST FSM state is entered and exits directly to TILE_NEXT without entering EDGE_TEST.
  - Hi-Z pass-through: tiles with a valid (non-sentinel) min_z and fragment_z <= min_z proceed normally to EDGE_TEST and emit the expected fragments.
  - Hi-Z sentinel: tiles whose metadata contains the sentinel value 9'h1FF are never rejected by Hi-Z, regardless of the incoming fragment Z value.

## Test Implementation

- `rtl/components/rasterizer/tests/tb_rasterizer.sv`: Verilator unit testbench for the rasterizer module.
  Drives triangle vertex data, monitors edge function outputs, counts fragment emissions, and checks interpolated values against reference data.

## Notes

- See `doc/verification/test_strategy.md` for the Verilator simulation framework, coverage goals, and test execution procedures.
- Run this test with: `cd integration && make test-rasterizer`.
- The testbench exercises the rasterizer in isolation with a stub consumer for the fragment output bus.
  Full pipeline integration (framebuffer writes, Z-buffer interaction) is covered by VER-010 through VER-013 (golden image tests).
- The rasterizer uses incremental derivative interpolation (per UNIT-005): attribute derivatives (dAttr/dx, dAttr/dy) are precomputed during triangle setup by UNIT-005.03, then stepped per-pixel by the rasterizer.
  The testbench reference model must use the same incremental step computation; the previously-used barycentric multiply-accumulate reference is no longer applicable.
  The testbench must allow sufficient setup cycles for derivative precomputation to complete before expecting the first fragment (see UNIT-005.03 for cycle count).
- The rasterizer does not perform direct SDRAM writes.
  Fragment data (x, y, z, color0, color1, uv0, uv1, lod) is emitted on the fragment output bus toward the pixel pipeline (UNIT-006) via a valid/ready handshake.
  UV coordinates (`frag_uv0`, `frag_uv1`) carry true perspective-correct U,V values in Q4.12 (16-bit signed), as defined by the `q4_12_t` typedef in `fp_types_pkg.sv`.
  `frag_lod` (UQ4.4) carries a per-pixel LOD estimate derived from CLZ on the interpolated Q value; it is present on the fragment bus and forwarded to UNIT-006, but is not consumed by the texture sampler (UNIT-011) under the INDEXED8_2X2 NEAREST-only architecture (mipmapping is not supported).
  `frag_q` is not present on this bus.
  The testbench instantiates a simple ready-signal driver to simulate downstream back-pressure.
- The rasterizer operates at the unified 100 MHz `clk_core` domain.
  The testbench clock should match this frequency for cycle-accurate fragment throughput verification.
- Edge function C coefficients are computed using 2 MULT18X18D DSP blocks in the edge setup unit (UNIT-005.02).
  inv_area is computed by a dedicated reciprocal module (`raster_recip_area.sv`, DP16KD 36×512 mode, UQ4.14 output) in UNIT-005.02.
  Per-pixel 1/Q is computed by a separate dedicated reciprocal module (`raster_recip_q.sv`, DP16KD 18×1024 mode, UQ4.14 output) in UNIT-005.05.
  Perspective correction (S×(1/Q), T×(1/Q)) uses 4 dedicated MULT18X18D in the iteration FSM (UNIT-005.05).
  A setup-iteration overlap FIFO (compile-time configurable depth, default 2) allows triangle N+1 setup to proceed concurrently with triangle N iteration; multi-triangle tests should verify that overlap does not corrupt interpolated values.
  The testbench should allow sufficient cycles for setup completion before checking output values, accounting for derivative precomputation and perspective correction pipeline latency.
  Test cases should include small triangles (e.g., 4×4 pixels or smaller) to verify derivative precision with large inv_area values.
