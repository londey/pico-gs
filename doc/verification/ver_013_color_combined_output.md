# VER-013: Color-Combined Output Golden Image Test

## Verification Method

**Test:** Verified by executing a Verilator golden image simulation that renders a textured, vertex-shaded triangle through the full GPU RTL hierarchy -- including the texture cache, texture decoder, color combiner (UNIT-010), and behavioral SDRAM model -- and compares the output pixel-exactly against an approved golden image.
The test confirms that the color combiner correctly evaluates the MODULATE equation `TEX0 * SHADE0` in cycle 0, passes the result through cycle 1 unchanged, and produces a final pixel color equal to the per-component product of the sampled texture color and the interpolated vertex color.

## Verifies Requirements

- REQ-004.01 (Color Combiner)

## Verified Design Units

- UNIT-003 (Register File -- CC_MODE, CONST_COLOR register writes)
- UNIT-006 (Pixel Pipeline -- texture sampling feeding combiner)
- UNIT-010 (Color Combiner -- two-stage pipeline)

## Preconditions

- UNIT-010 (Color Combiner) has reached Stable status: the WIP flag has been removed from `doc/design/unit_010_color_combiner.md`, indicating that combiner equation pipeline timing and register decoding are finalized.
- `pixel_pipeline.sv` is the fully integrated module (not a stub): it instantiates UNIT-010 (Color Combiner) with live connections to `cc_mode` and `const_color` from the register file, along with the texture cache, format-select mux, and FB/Z write logic per UNIT-006.
- Integration simulation harness (`spi_gpu/tests/harness/`) compiles successfully under Verilator, with a behavioral SDRAM model that correctly implements the INT-032 Cache Miss Handling Protocol (IDLE -> FETCH -> DECOMPRESS -> WRITE_BANKS -> IDLE FSM, with format-dependent burst lengths).
- Golden image `spi_gpu/tests/golden/color_combined.ppm` has been approved and committed.
  This image is created after the pixel pipeline integration and UNIT-010 stabilization; the simulation output must be visually inspected and approved before the first commit of the golden file.
- Verilator 5.x is installed and available on `$PATH`.
- All RTL sources in the rendering pipeline (`register_file.sv`, `rasterizer.sv`, `pixel_pipeline.sv`, `texture_cache.sv`, `texture_rgb565.sv`, `color_combiner.sv`) compile without errors under `verilator --lint-only -Wall`.

## Procedure

### Test Scene

The test renders a single triangle that is both textured and vertex-shaded, with the color combiner configured in MODULATE mode.
The MODULATE equation multiplies the sampled texture color by the interpolated vertex color per component, producing a tinted texture output.

**Texture:** A 16x16 RGB565 checker pattern (same as VER-012), generated programmatically by the harness:

- **Dimensions:** 16x16 pixels (WIDTH_LOG2=4, HEIGHT_LOG2=4).
- **Format:** RGB565 (FORMAT=4, uncompressed).
- **Pattern:** 4x4 block checker.
  Even blocks (where `(block_x + block_y) % 2 == 0`) are white (`0xFFFF`); odd blocks are mid-gray (`0x8410`, approximately 50% intensity in RGB565).
  Using white and mid-gray (rather than white and black) ensures that the MODULATE product is non-zero for all texels, making vertex color tinting visible across the entire triangle.
- **Layout:** Stored in SDRAM using the 4x4 block-tiled layout defined in INT-014.
- **Base address:** A known aligned address (e.g., `0x00040000`) written to TEX0_BASE.

**Vertex data:**

| Vertex | Screen Position (Q12.4) | Primary Color (RGBA8888) | UV Coordinates (U, V) — Q4.12 on fragment bus | Description |
|--------|-------------------------|--------------------------|-----------------------------------------------|-------------|
| V0 | (320, 60) | `0xFF0000FF` (red, opaque) | (0.5, 0.0) | Top center |
| V1 | (100, 380) | `0x00FF00FF` (green, opaque) | (0.0, 1.0) | Bottom left |
| V2 | (540, 380) | `0x0000FFFF` (blue, opaque) | (1.0, 1.0) | Bottom right |

Secondary vertex colors (COLOR1) are set to black (`0x000000FF`) for all three vertices (not used in MODULATE mode).
The Gouraud-interpolated vertex colors produce a smooth red-green-blue gradient across the triangle surface.
When multiplied by the checker texture via MODULATE, the output is a color-tinted checker pattern: white checker squares show the full vertex gradient, while mid-gray squares show the gradient at half intensity.

### CC_MODE Register Encoding

The color combiner is configured via the CC_MODE register (address `0x18`) for the MODULATE preset.
Per REQ-004.01 FR-009-2 and UNIT-010, the two-stage combiner evaluates `(A - B) * C + D` in each cycle:

**Cycle 0 (MODULATE):**
- A = TEX_COLOR0 (CC_TEX0)
- B = ZERO (CC_ZERO)
- C = SHADE0 (CC_SHADE0)
- D = ZERO (CC_ZERO)
- Equation: `(TEX0 - ZERO) * SHADE0 + ZERO = TEX0 * SHADE0`

**Cycle 1 (pass-through):**
- A = COMBINED (cycle 0 output)
- B = ZERO
- C = ONE
- D = ZERO
- Equation: `(COMBINED - ZERO) * ONE + ZERO = COMBINED`

Per INT-010 source select encoding, the single-cycle encoding for MODULATE is:
- `CC_A_SOURCE[19:16] = 0x0` (TEX_COLOR0)
- `CC_B_SOURCE[23:20] = 0x7` (ZERO)
- `CC_C_SOURCE[27:24] = 0x2` (VER_COLOR0 / SHADE0)
- `CC_D_SOURCE[31:28] = 0x7` (ZERO)
- Alpha selectors: same encoding in bits [15:0].

**CONST_COLOR (address `0x19`) / MAT_COLOR0:** Not required for MODULATE mode (neither CONST0 nor CONST1 is used as a combiner input in this test).
Write as `0x0000000000000000` (default).

### Harness Command Sequence

The integration harness drives the following register-write sequence into UNIT-003 (Register File):

1. **Load test texture into behavioral SDRAM model:**
   Generate the 16x16 RGB565 checker pattern (white/mid-gray) and write it into the SDRAM model at the chosen base address using the 4x4 block-tiled layout (INT-014).

2. **Configure texture unit 0:**
   - Write `TEX0_CFG` (address `0x10`) with the texture base address (e.g., `0x00040000`, 4K aligned).
   - Write `TEX0_FMT` (address `0x11`) with:
     - `ENABLE = 1` (bit 0)
     - `FORMAT = RGB565` (4 << 2, bits [4:2]; 3-bit field per INT-010 post-integration)
     - `WIDTH_LOG2 = 4` (4 << 8, bits [11:8])
     - `HEIGHT_LOG2 = 4` (4 << 12, bits [15:12])
     - `SWIZZLE = 0` (identity, bits [19:16])
     - `FILTER = NEAREST` (0, bits [7:6])
     - `MIP_LEVELS = 1` (1 << 20, bits [23:20])

3. **Configure color combiner:**
   Write `CC_MODE` (address `0x18`) with the MODULATE preset encoding as described above.
   For the single-cycle register layout per INT-010: `0x0000000000720020` (A=TEX0, B=ZERO, C=VER0, D=ZERO, with matching alpha selectors).
   Encode cycle 1 as pass-through in bits [63:32] per the finalized UNIT-010 two-cycle register layout.

4. **Configure render mode:**
   Write `RENDER_MODE` (address `0x30`) with:
   - `GOURAUD_EN = 1` (bit 0, Gouraud shading for vertex color interpolation)
   - `Z_TEST_EN = 0` (bit 2, no depth test)
   - `Z_WRITE_EN = 0` (bit 3, no depth write)
   - `COLOR_WRITE_EN = 1` (bit 4)
   - `TEX0_EN` via TEX0_FMT (texture unit 0 enabled above)
   - All other mode bits = 0 (no dithering, no alpha blend, no stipple, no culling)

5. **Configure framebuffer:**
   Write `FB_CONFIG` (address `0x40`) with:
   - `fb_color_base` = chosen color buffer base address (SDRAM-aligned).
   - `fb_width_log2 = 9` (surface width = 512 pixels).
   - `fb_height_log2 = 9` (surface height = 512 pixels).
   The harness framebuffer readback in step 10 must use `WIDTH_LOG2 = 9` for the block-tiled address calculation (INT-011).

6. **Submit vertex 0:**
   - Write `COLOR` (address `0x00`) with `0x000000FF_FF0000FF` (COLOR1=black in upper 32 bits, COLOR0=red in lower 32 bits).
   - Write `UV0_UV1` (address `0x01`) with UV0 = (0.5, 0.0) packed per register format.
   - Write `VERTEX_NOKICK` (address `0x06`) with V0 position (X=320, Y=60, Z=`0x0000`).

7. **Submit vertex 1:**
   - Write `COLOR` (address `0x00`) with `0x000000FF_00FF00FF` (COLOR1=black, COLOR0=green).
   - Write `UV0_UV1` (address `0x01`) with UV0 = (0.0, 1.0).
   - Write `VERTEX_NOKICK` (address `0x06`) with V1 position (X=100, Y=380, Z=`0x0000`).

8. **Submit vertex 2 (with kick):**
   - Write `COLOR` (address `0x00`) with `0x000000FF_0000FFFF` (COLOR1=black, COLOR0=blue).
   - Write `UV0_UV1` (address `0x01`) with UV0 = (1.0, 1.0).
   - Write `VERTEX_KICK_012` (address `0x07`) with V2 position (X=540, Y=380, Z=`0x0000`).

9. **Wait for completion:**
   Run the simulation until the `frag_done` signal (or equivalent pipeline-idle indicator) asserts, indicating all fragments have been processed through the color combiner and written to the behavioral SDRAM model.

10. **Read back framebuffer:**
    The harness reads the simulated framebuffer contents from the behavioral SDRAM model using the 4x4 block-tiled address layout per INT-011, with `WIDTH_LOG2 = 9` matching the `fb_width_log2` written in step 5.
    The pixel data is serialized as a PPM file at `spi_gpu/tests/sim_out/color_combined.ppm`.

11. **Pixel-exact comparison:**
    Compare the simulation output against the approved golden image:
    ```
    diff -q spi_gpu/tests/sim_out/color_combined.ppm spi_gpu/tests/golden/color_combined.ppm
    ```

## Expected Results

- **Pass Criteria:** Pixel-exact match between the simulation output (`spi_gpu/tests/sim_out/color_combined.ppm`) and the approved golden image (`spi_gpu/tests/golden/color_combined.ppm`).
  The rendered image shows a triangle with a checker pattern modulated by the Gouraud vertex color gradient.
  Output color at each pixel equals `texture_color * vertex_color` (per-component MODULATE), producing a color-tinted checker pattern: the red-green-blue vertex gradient is visible across both white and mid-gray checker regions, with the mid-gray regions at approximately half intensity.
  The color combiner correctly evaluates `(TEX0 - ZERO) * SHADE0 + ZERO` in cycle 0 and passes the result through cycle 1 unchanged.

- **Fail Criteria:** Any pixel differs between the simulation output and the approved golden image.
  Common failure modes include:
  - Texture appears without vertex color tinting (indicating the combiner ignored SHADE0 or defaulted to pass-through instead of MODULATE).
  - Vertex gradient appears without texture pattern (indicating the combiner ignored TEX_COLOR0 or texture sampling failed).
  - Output is solid black (indicating the combiner produced ZERO for all inputs, or CC_MODE was not applied).
  - Incorrect color arithmetic (indicating Q4.12 multiply or saturation error in the combiner pipeline).
  - Cycle 1 modifies the cycle 0 result (indicating pass-through misconfiguration: A!=COMBINED, B!=ZERO, C!=ONE, or D!=ZERO).
  - CC_MODE register not decoded correctly by UNIT-010 (indicating register decode mismatch between UNIT-003 output and UNIT-010 input muxing).

## Test Implementation

- `spi_gpu/tests/harness/`: Integration simulation harness.
  Instantiates the full GPU RTL hierarchy under Verilator, provides a behavioral SDRAM model implementing the INT-032 cache miss fill FSM, drives register-write command sequences, and reads back the framebuffer as PPM files.
- `spi_gpu/tests/golden/color_combined.ppm`: Approved golden image (created after the initial simulation run following UNIT-010 stabilization and pixel pipeline integration; visually inspected and approved before commit).

## Notes

- **CC_MODE bit encoding:** The exact CC_MODE encoding for the two-cycle MODULATE + pass-through configuration is determined by the finalized UNIT-010 register decode logic.
  Verify the encoding value `0x0000000000720020` against the UNIT-010 implementation before approving the golden image.
- See `doc/verification/test_strategy.md` (Golden Image Approval Testing section) for the approval workflow: run the simulation, visually inspect the output PPM, copy to the `golden/` directory, and commit.
- **Makefile target:** Run this test with: `cd spi_gpu && make test-color-combined`.
- **Relationship to VER-012:** VER-012 tests texture sampling in isolation (vertex colors are white, so MODULATE produces `texture * 1.0 = texture`).
  VER-013 exercises the same texture path but with non-trivial vertex colors, confirming that the color combiner correctly multiplies the two input sources.
- **Dithering:** Dithering is disabled (`DITHER_EN=0`) for this test to ensure deterministic, fully reproducible output.
- **Z-testing:** Z-testing and Z-writing are disabled to isolate color combiner correctness from depth buffer behavior.
- **VER-013 together with VER-004** (Color Combiner Unit Testbench) jointly satisfy REQ-004.01 per the requirement document's Verification Method section.
  VER-004 verifies individual combiner modes and arithmetic at the unit level; VER-013 verifies the MODULATE mode through the full integrated pipeline including texture sampling and vertex color interpolation.
- The background of the framebuffer (pixels outside the triangle) will contain whatever the SDRAM model initializes to (typically zero/black).
  The golden image includes the full 512×512 framebuffer surface, so the background color is part of the pixel-exact comparison.
- The golden image must be regenerated and re-approved whenever the rasterizer tiled address stride changes (e.g. after wiring `fb_width_log2` to replace a hardcoded constant), after the incremental interpolation redesign (UNIT-005), or after any change to UNIT-010 combiner arithmetic.
  See `test_strategy.md` for the re-approval workflow.
- **UV format and golden image:** UV coordinates on the rasterizer→pixel_pipeline fragment bus are Q4.12, as defined by the `q4_12_t` typedef in `fp_types_pkg.sv`.
  If the UV format mismatch between the rasterizer output and the pixel pipeline's UV consumption logic is corrected, the texture coordinates used for cache set indexing will change, altering the rendered checker pattern at pixel level.
  Re-run this test, visually inspect the corrected output, and re-approve the golden image if pixel output changes.
- **Q4.12 arithmetic constants:** The color combiner ONE (0x1000) and ZERO (0x0000) constants are centralized in `fp_types_pkg.sv`.
  If those constant values change (which is not expected for a correct implementation), VER-013 pixel output will change and the golden image must be re-approved.
- Of the five golden image tests (VER-010 through VER-014), this test has the deepest dependency chain: it requires a stable UNIT-010 implementation and a fully integrated pixel pipeline (UNIT-006) in addition to the shared integration harness infrastructure.
