# VER-005: Texture Decoder Unit Testbench

## Verification Method

**Test:** Verified by executing the `texture_decoder_tb` Verilator simulation testbench against the texture decoder RTL sub-modules of UNIT-006 (Pixel Pipeline).
The testbench drives known input data through each texture format decoder and the texel promotion and stipple modules, then compares decoded RGBA5652 output against software-computed reference values.

## Verifies Requirements

- REQ-003.01 (Textured Triangle)
- REQ-003.03 (Compressed Textures)
- REQ-003.06 (BC2 Texture Decoding)
- REQ-003.07 (BC3 Texture Decoding)
- REQ-003.08 (BC4 Texture Decoding)

## Verified Design Units

- UNIT-006 (Pixel Pipeline — texture decoder sub-modules)

## Preconditions

- Verilator 5.x installed and available on `$PATH`.
- The following RTL source files compile without errors under `verilator --lint-only -Wall`:
  - `spi_gpu/src/render/texture_rgb565.sv`
  - `spi_gpu/src/render/texture_rgba8888.sv`
  - `spi_gpu/src/render/texture_r8.sv`
  - `spi_gpu/src/render/texture_bc2.sv`
  - `spi_gpu/src/render/texture_bc3.sv`
  - `spi_gpu/src/render/texture_bc4.sv`
  - `spi_gpu/src/render/texel_promote.sv`
  - `spi_gpu/src/render/stipple.sv`
- Test vector data is embedded directly in the testbench source (no external vector files required).

## Procedure

1. **RGB565 decoder: verify 4x4 block decode to RGBA5652.**
   Provide a 4x4 block of 16 known RGB565 pixels covering boundary values (all-zeros, all-ones, pure red, pure green, pure blue).
   For each of the 16 texel indices, verify the decoded RGBA5652 output matches the expected value with A2=11 (opaque).
   Confirm the bit mapping: RGB565 R5 maps to RGBA5652[17:13], G6 to RGBA5652[12:7], B5 to RGBA5652[6:2], and A2=11 in RGBA5652[1:0].

2. **RGBA8888 decoder: verify truncation to RGBA5652 precision.**
   Provide a 4x4 block of 16 RGBA8888 values with distinct per-channel values.
   Verify truncation produces correct results: R8[7:3] to R5, G8[7:2] to G6, B8[7:3] to B5, A8[7:6] to A2.
   Test boundary values including fully transparent (A8=0x00 producing A2=00) and fully opaque (A8=0xFF producing A2=11).

3. **R8 decoder: verify single-channel replication and alpha.**
   Provide 16 single-channel R8 values including 0x00, 0xFF, and intermediate values.
   Verify that R is replicated to G and B channels: R5=R8[7:3], G6=R8[7:2], B5=R8[7:3].
   Verify A2=11 (opaque) for all texels.

4. **texel_promote: verify RGBA5652 to Q4.12 conversion across boundary patterns.**
   Drive all boundary RGBA5652 patterns through the promotion logic:
   - R5=0 produces Q4.12 R=0x0000; R5=31 produces Q4.12 R=0x1FFF.
   - G6=0 produces Q4.12 G=0x0000; G6=63 produces the maximum Q4.12 G value.
   - B5=0 produces Q4.12 B=0x0000; B5=31 produces Q4.12 B=0x1FFF.
   - A2=00 produces Q4.12 A=0x0000; A2=01 produces 0x0555; A2=10 produces 0x0AAA; A2=11 produces 0x1000.
   Verify that all Q4.12 output values span the [0.0, 1.0] range as specified in INT-032.
   The RTL implementation of these formulas is the `promote_unorm8_to_q412` and related named functions in `fp_types_pkg.sv`.
   The expected output values for each boundary pattern are derived from the formulas in INT-032 and serve as the acceptance test for those functions.

5. **Stipple test: verify fragment discard logic.**
   - When STIPPLE_EN=1 and the pattern bit at index `(y & 7) * 8 + (x & 7)` is 0: verify discard is asserted.
   - When STIPPLE_EN=1 and the pattern bit is 1: verify discard is deasserted (fragment passes).
   - When STIPPLE_EN=0: verify discard is deasserted regardless of pattern bit value.
   Test with multiple (x, y) coordinates and pattern values to cover corner cases.

6. **BC1 decoder (if present in testbench): verify 4-color and 1-bit alpha punch-through modes.**
   - When color0 > color1: verify 4-color palette interpolation (C0, C1, lerp 1/3, lerp 2/3) and all texels opaque (A2=11).
   - When color0 <= color1: verify 3-color plus transparent mode (C0, C1, lerp 1/2, transparent with A2=00).

7. **BC2 decoder: verify explicit 4-bit alpha and BC1-style color block.**
   Provide a known 16-byte BC2 block where the 8-byte alpha section contains explicit 4-bit alpha values for all 16 texels and the 8-byte color section contains a standard BC1 color block.
   For each texel, verify that A2 is the correct truncation of the 4-bit explicit alpha (`alpha4[3:2]`), and that R5, G6, B5 are decoded from the BC1 color section using the same 4-color interpolation path as BC1 (BC2 never uses the transparent mode).

8. **BC3 decoder: verify interpolated 8-bit alpha and BC1-style color block.**
   Provide a known 16-byte BC3 block.
   When alpha0 > alpha1: verify the 8-alpha interpolation table (alpha0, alpha1, and 6 interpolated values) is applied correctly for each texel index.
   When alpha0 <= alpha1: verify the 6-alpha plus black-and-white table (alpha0, alpha1, 4 interpolated, 0x00, 0xFF).
   Verify that the BC1 color section is decoded correctly for R, G, B channels in both cases.

9. **BC4 decoder: verify single-channel alpha-as-red replication.**
   Provide a known 8-byte BC4 block (single channel, same bit layout as the alpha section of BC3).
   Verify the 8-value interpolation table is applied for the red channel.
   Verify that the decoded red value is replicated to G and B channels (same replication as R8 format) and that A2=11 (opaque) for all texels.

10. **Format-select mux wiring (integration path).**
    For each of the seven `tex_format` encodings (0=BC1 through 6=R8, per INT-032), drive the format select input to the decoder mux and verify that the correct decoder module output is propagated to the mux output.
    Decoder outputs for non-selected formats must not affect the result.
    The `tex_format` input is 3 bits wide (per INT-032 Step 5 expansion from 2-bit).

11. **RGBA5652 encoding format verification.**
    Confirm the RGBA5652 bit layout matches INT-032: R5 in bits [17:13], G6 in bits [12:7], B5 in bits [6:2], A2 in bits [1:0].

## Expected Results

- **Pass Criteria:**
  - All decoded texel values exactly match software-computed reference values for every tested format (RGB565, RGBA8888, R8, BC1, BC2, BC3, BC4).
  - texel_promote output values match the INT-032 specified Q4.12 expansion formulas exactly (no rounding tolerance; promotion is combinational bit manipulation).
  - Stipple discard signal matches expected value for all tested (x, y, pattern, enable) combinations.
  - RGBA5652 bit field positions match INT-032 format definition.
  - Format-select mux routes the correct decoder output for all seven `tex_format` encodings.
  - All test assertions pass with zero failures.

- **Fail Criteria:**
  - Any decoded RGBA5652 texel differs from its expected reference value for any format.
  - Any texel_promote Q4.12 output differs from the expected bit-exact value.
  - Stipple discard is incorrect for any tested input combination.
  - Format-select mux produces incorrect output for any `tex_format` encoding.
  - The testbench reports one or more assertion failures.

## Test Implementation

- `spi_gpu/tests/render/texture_decoder_tb.sv`: Verilator unit testbench covering the RGB565, RGBA8888, R8, BC1, BC2, BC3, BC4, texel_promote, stipple, and format-select mux.
  Instantiates each decoder as a separate DUT plus the format-select mux, drives known input block data with specific texel indices, and checks output RGBA5652 values against expected constants.
  Uses embedded test vectors (no external file dependencies).

## Notes

- See INT-032 (Texture Cache Architecture) for the RGBA5652 format definition, conversion tables from each source format, Q4.12 promotion formulas, and the 3-bit `tex_format` encoding table.
  The `fp_types_pkg.sv` package (`spi_gpu/src/fp_types_pkg.sv`) centralizes the Q4.12 type definitions (`q4_12_t`) and the named promotion functions (e.g., `promote_unorm8_to_q412`) that implement the INT-032 formulas in RTL.
  If Step 4 promotion output differs from the INT-032 formula, verify the `fp_types_pkg.sv` function implementation against INT-032 before updating test vectors.
- See `doc/verification/test_strategy.md` for the Verilator simulation framework, coverage goals, and test execution procedures.
- Run this test with: `cd spi_gpu && make test-texture-decoder`.
- REQ-003.01 coverage is jointly satisfied by VER-005 (unit test for the decode path in isolation) and VER-012 (golden image integration test exercising the full texture sampling pipeline including cache, rasterizer, and framebuffer output).
- The `texture_decoder_tb` testbench exercises only combinational decoder logic and the format-select mux; it does not test the texture cache fill FSM or SDRAM burst protocol (those are covered by VER-012 and future cache-specific VER documents).
- The `tex_format` field is 3 bits wide, encoding 7 formats (BC1=0, BC2=1, BC3=2, BC4=3, RGB565=4, RGBA8888=5, R8=6) as defined in INT-032.
  The testbench format-select mux test (step 10) must exercise all valid `tex_format` encodings.
