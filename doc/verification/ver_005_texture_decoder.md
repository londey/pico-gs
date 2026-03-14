# VER-005: Texture Decoder Unit Testbench

## Verification Method

**Test:** Verified by executing the `texture_decoder_tb` Verilator simulation testbench against the texture decoder RTL sub-modules of UNIT-006 (Pixel Pipeline).
The testbench drives known input data through each texture format decoder and the texel promotion and stipple modules, then compares decoded texel output (RGBA5652 in 18-bit mode, UQ1.8 in 36-bit mode) against software-computed reference values.

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

4. **texel_promote: verify RGBA5652 → Q4.12 conversion (CACHE_MODE=0) across boundary patterns.**
   Assert CACHE_MODE=0 and drive all boundary RGBA5652 patterns through the promotion logic:
   - R5=0 produces Q4.12 R=0x0000; R5=31 produces Q4.12 R=0x1FFF.
   - G6=0 produces Q4.12 G=0x0000; G6=63 produces the maximum Q4.12 G value.
   - B5=0 produces Q4.12 B=0x0000; B5=31 produces Q4.12 B=0x1FFF.
   - A2=00 produces Q4.12 A=0x0000; A2=01 produces 0x0555; A2=10 produces 0x0AAA; A2=11 produces 0x1000.
   Verify that all Q4.12 output values span the [0.0, 1.0] range as specified in INT-032.
   The RTL implementation of these formulas is the `promote_unorm8_to_q412` and related named functions in `fp_types_pkg.sv`.
   The expected output values for each boundary pattern are derived from the formulas in INT-032 and serve as the acceptance test for those functions.

5. **texel_promote: verify UQ1.8 → Q4.12 conversion (CACHE_MODE=1) across boundary patterns.**
   Assert CACHE_MODE=1 and drive boundary 9-bit UQ1.8 channel values through the promotion logic:
   - channel=0x000 (0.0) produces Q4.12=0x0000.
   - channel=0x100 (256/256 = 1.0) produces Q4.12=0x1000.
   - channel=0x080 (128/256 = 0.5) produces Q4.12=0x0800.
   - channel=0x1FF (511/512, maximum UQ1.8) produces Q4.12=0x1FF8.
   Verify the promotion is a combinational left-shift-by-3 with zero-pad as defined in INT-032: `{3'b000, channel_9bit, 3'b000}`.
   Verify all four RGBA channels are promoted independently with the same formula.
   If Step 5 output differs from the INT-032 formula, verify `fp_types_pkg.sv` against INT-032 before updating test vectors.

6. **Stipple test: verify fragment discard logic.**
   - When STIPPLE_EN=1 and the pattern bit at index `(y & 7) * 8 + (x & 7)` is 0: verify discard is asserted.
   - When STIPPLE_EN=1 and the pattern bit is 1: verify discard is deasserted (fragment passes).
   - When STIPPLE_EN=0: verify discard is deasserted regardless of pattern bit value.
   Test with multiple (x, y) coordinates and pattern values to cover corner cases.

7. **BC1 decoder (if present in testbench): verify 4-color and 1-bit alpha punch-through modes.**
   - When color0 > color1: verify 4-color palette interpolation (C0, C1, lerp 1/3, lerp 2/3) using shift+add reciprocal-multiply (DD-039), and all texels opaque.
   - When color0 <= color1: verify 3-color plus transparent mode (C0, C1, lerp 1/2, transparent).
   In CACHE_MODE=1, verify endpoints are expanded to 8-bit before interpolation and output is 36-bit UQ1.8.

8. **BC2 decoder: verify explicit 4-bit alpha and BC1-style color block.**
   Provide a known 16-byte BC2 block where the 8-byte alpha section contains explicit 4-bit alpha values for all 16 texels and the 8-byte color section contains a standard BC1 color block.
   For each texel, verify alpha truncation and BC1 color decoding using shift+add interpolation (DD-039).
   In CACHE_MODE=0: verify A2 = `alpha4[3:2]` and R5/G6/B5 match expected RGBA5652.
   In CACHE_MODE=1: verify alpha and color channels are UQ1.8 values matching expected 36-bit output.

9. **BC3 decoder: verify interpolated 8-bit alpha and BC1-style color block.**
   Provide a known 16-byte BC3 block.
   When alpha0 > alpha1: verify the 8-alpha interpolation table (alpha0, alpha1, and 6 interpolated values using shift+add) is applied correctly for each texel index.
   When alpha0 <= alpha1: verify the 6-alpha plus black-and-white table (alpha0, alpha1, 4 interpolated, 0x00, 0xFF).
   Verify that the BC1 color section is decoded correctly for R, G, B channels in both cases.

10. **BC4 decoder: verify single-channel alpha-as-red replication.**
    Provide a known 8-byte BC4 block (single channel, same bit layout as the alpha section of BC3).
    Verify the 8-value interpolation table is applied using shift+add formulas (DD-039) for the red channel.
    Verify that the decoded red value is replicated to G and B channels and that A is opaque for all texels.

11. **Format-select mux wiring (integration path).**
    For each of the seven `tex_format` encodings (0=BC1 through 6=R8, per INT-032), drive the format select input to the decoder mux and verify that the correct decoder module output is propagated to the mux output.
    Decoder outputs for non-selected formats must not affect the result.
    The `tex_format` input is 3 bits wide (per INT-032).

12. **Cache format bit layout verification.**
    In CACHE_MODE=0: confirm RGBA5652 bit layout matches INT-032: R5 in bits [17:13], G6 in bits [12:7], B5 in bits [6:2], A2 in bits [1:0].
    In CACHE_MODE=1: confirm UQ1.8 bit layout matches INT-032: R9 in bits [35:27], G9 in bits [26:18], B9 in bits [17:9], A9 in bits [8:0].

## Expected Results

- **Pass Criteria:**
  - All decoded texel values exactly match software-computed reference values for every tested format (RGB565, RGBA8888, R8, BC1, BC2, BC3, BC4), in both CACHE_MODE=0 (RGBA5652) and CACHE_MODE=1 (UQ1.8) where applicable.
  - texel_promote output values match the INT-032 specified Q4.12 expansion formulas exactly for both RGBA5652 (step 4) and UQ1.8 (step 5) promotion paths (no rounding tolerance; promotion is combinational bit manipulation).
  - Stipple discard signal matches expected value for all tested (x, y, pattern, enable) combinations.
  - Cache format bit field positions match INT-032 format definitions for both RGBA5652 and UQ1.8.
  - Format-select mux routes the correct decoder output for all seven `tex_format` encodings.
  - All test assertions pass with zero failures.

- **Fail Criteria:**
  - Any decoded texel differs from its expected reference value for any format or cache mode.
  - Any texel_promote Q4.12 output differs from the expected bit-exact value for either promotion path.
  - Stipple discard is incorrect for any tested input combination.
  - Format-select mux produces incorrect output for any `tex_format` encoding.
  - The testbench reports one or more assertion failures.

## Test Implementation

- `spi_gpu/tests/render/texture_decoder_tb.sv`: Verilator unit testbench covering the RGB565, RGBA8888, R8, BC1, BC2, BC3, BC4, texel_promote, stipple, and format-select mux.
  Instantiates each decoder as a separate DUT plus the format-select mux, drives known input block data with specific texel indices, and checks output values (RGBA5652 in CACHE_MODE=0, UQ1.8 in CACHE_MODE=1) against expected constants.
  Uses embedded test vectors (no external file dependencies).

## Notes

- See INT-032 (Texture Cache Architecture) for the RGBA5652 and UQ1.8 format definitions, conversion tables from each source format, Q4.12 promotion formulas for both cache modes, and the 3-bit `tex_format` encoding table.
  The `fp_types_pkg.sv` package (`spi_gpu/src/fp_types_pkg.sv`) centralizes the Q4.12 type definitions (`q4_12_t`) and the named promotion functions (e.g., `promote_unorm8_to_q412`, `promote_uq18_to_q412`) that implement the INT-032 formulas in RTL.
  If Step 4 or Step 5 promotion output differs from the INT-032 formula, verify the `fp_types_pkg.sv` function implementation against INT-032 before updating test vectors.
- See `doc/verification/test_strategy.md` for the Verilator simulation framework, coverage goals, and test execution procedures.
- Run this test with: `cd spi_gpu && make test-texture-decoder`.
- REQ-003.01 coverage is jointly satisfied by VER-005 (unit test for the decode path in isolation) and VER-012 (golden image integration test exercising the full texture sampling pipeline including cache, rasterizer, and framebuffer output).
- The `texture_decoder_tb` testbench exercises only combinational decoder logic and the format-select mux; it does not test the texture cache fill FSM or SDRAM burst protocol (those are covered by VER-012 and future cache-specific VER documents).
- The `tex_format` field is 3 bits wide, encoding 7 formats (BC1=0, BC2=1, BC3=2, BC4=3, RGB565=4, RGBA8888=5, R8=6) as defined in INT-032.
  The testbench format-select mux test (step 10) must exercise all valid `tex_format` encodings.
