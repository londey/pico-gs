# VER-001: Rasterizer Unit Testbench

## Verification Method

**Test:** Verified by executing the `tb_rasterizer` Verilator simulation testbench against the rasterizer RTL (UNIT-005).
The testbench drives known triangle configurations through the triangle setup and edge-walking pipeline, then checks computed values and fragment output against reference data.

## Verifies Requirements

- REQ-002.03 (Rasterization Algorithm)

## Verified Design Units

- UNIT-005 (Rasterizer)

## Preconditions

- Verilator 5.x installed and available on `$PATH`.
- `spi_gpu/src/render/rasterizer.sv` compiles without errors under `verilator --lint-only -Wall`.
- `spi_gpu/src/render/early_z.sv` compiles without errors under `verilator --lint-only -Wall` (rasterizer depends on early Z integration signals).
- Triangle setup module (UNIT-004) is instantiated or stubbed so that the rasterizer receives valid setup data.
- The testbench drives `fb_width_log2` and `fb_height_log2` register inputs (from UNIT-003) to configure the active surface dimensions before each test case.

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

3. **Fragment emission count.**
   Drive the rasterizer with a triangle of known area.
   Count the number of fragment emission pulses (fragment_valid assertions) during edge walking.
   Compare the count against a reference pixel count for the test triangle.
   The count must be exact (no tolerance).

4. **Barycentric interpolation accuracy.**
   For a triangle with distinct vertex colors and Z values, sample the interpolated output at:
   - Each of the three vertices (barycentric weights should be (1,0,0), (0,1,0), (0,0,1) respectively).
   - The centroid (barycentric weights should be approximately (1/3, 1/3, 1/3)).
   - Edge midpoints.
   Verify that interpolated color and Z values match reference values within 1 ULP of the 17-bit barycentric precision (1.16 fixed point).

5. **Degenerate triangle handling.**
   Submit the following degenerate cases and verify correct behavior (using `fb_width_log2 = 9`, `fb_height_log2 = 9`):
   - Zero-area triangle (all three vertices collinear): rasterizer should emit zero fragments.
   - Single-pixel triangle (three vertices that enclose exactly one pixel center): rasterizer should emit exactly one fragment.
   - Fully off-screen triangle (all vertices outside the configured surface bounds): rasterizer should emit zero fragments after bounding box clamp results in an empty region.

6. **Winding order.**
   Submit the same triangle in both clockwise and counter-clockwise winding order.
   Verify that edge function signs are consistent with the expected winding convention and that fragment emission occurs for the correct winding.

## Expected Results

- **Pass Criteria:**
  - All edge function coefficients (A, B, C) for each edge match reference values exactly.
  - Bounding box X coordinate is clamped to `[0, (1 << fb_width_log2) - 1]` and Y coordinate to `[0, (1 << fb_height_log2) - 1]` for each configured surface size (512×512 and 256×256).
  - Fragment emission counts match reference pixel counts exactly for all test triangles.
  - Interpolated color and Z values at vertices, centroid, and midpoints match reference values within 1 ULP (least significant bit of the 17-bit barycentric weight).
  - Degenerate triangles produce the expected fragment count (0 or 1 as specified).
  - Winding order tests produce consistent edge function signs.

- **Fail Criteria:**
  - Any edge function coefficient differs from the reference value.
  - Bounding box exceeds the configured surface bounds or is incorrectly computed for any `fb_width_log2` / `fb_height_log2` combination.
  - Fragment count differs from expected value for any test triangle.
  - Interpolated values exceed the 1 ULP tolerance at any sampled point.
  - Degenerate triangle produces unexpected fragments.

## Test Implementation

- `spi_gpu/tests/render/tb_rasterizer.sv`: Verilator unit testbench for the rasterizer module.
  Drives triangle vertex data, monitors edge function outputs, counts fragment emissions, and checks interpolated values against reference data.

## Notes

- See `doc/verification/test_strategy.md` for the Verilator simulation framework, coverage goals, and test execution procedures.
- Run this test with: `cd spi_gpu && make test-rasterizer`.
- The testbench exercises the rasterizer in isolation.
  Full pipeline integration (framebuffer writes, Z-buffer interaction) is covered by VER-010 through VER-013 (golden image tests).
- The rasterizer operates at the unified 100 MHz `clk_core` domain.
  The testbench clock should match this frequency for cycle-accurate fragment throughput verification.
- Edge function coefficients use serialized computation through a shared pair of 11x11 multipliers (3 setup cycles + 3 initial evaluation cycles).
  The testbench should allow sufficient cycles for setup completion before checking output values.
