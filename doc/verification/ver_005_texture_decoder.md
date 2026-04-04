# VER-005: Texture Decoder Unit Testbench

## Verification Method

**Test:** Verified by executing the `texture_decoder_tb` Verilator simulation testbench against the texture decoder RTL sub-modules of UNIT-011.04 (Block Decompressor).
The testbench drives known input data through each texture format decoder and the texel promotion and stipple modules, then compares decoded texel output (UQ1.8 format, 36 bits per texel) against software-computed reference values.

## Verifies Requirements

- REQ-003.01 (Textured Triangle)
- REQ-003.03 (Compressed Textures)
- REQ-003.06 (BC2 Texture Decoding)
- REQ-003.07 (BC3 Texture Decoding)
- REQ-003.08 (BC4 Texture Decoding)

## Verified Design Units

- UNIT-011.04 (Block Decompressor — texture format decoder sub-modules and texel promotion)

## Preconditions

- Verilator 5.x installed and available on `$PATH`.
- The following RTL source files compile without errors under `verilator --lint-only -Wall`:
  - `components/texture/detail/block-decoder/rtl/texture_rgb565.sv`
  - `components/texture/detail/block-decoder/rtl/texture_rgba8888.sv`
  - `components/texture/detail/block-decoder/rtl/texture_r8.sv`
  - `components/texture/detail/block-decoder/rtl/texture_bc2.sv`
  - `components/texture/detail/block-decoder/rtl/texture_bc3.sv`
  - `components/texture/detail/block-decoder/rtl/texture_bc4.sv`
  - `components/texture/detail/block-decoder/rtl/texel_promote.sv`
  - `components/stipple/rtl/stipple.sv`
- Test vector data is embedded directly in the testbench source (no external vector files required).

## Procedure

1. **RGB565 decoder: verify 4x4 block decode to UQ1.8.**
   Provide a 4x4 block of 16 known RGB565 pixels covering boundary values (all-zeros, all-ones, pure red, pure green, pure blue).
   For each of the 16 texel indices, verify the decoded UQ1.8 output matches the expected value with A=opaque (9'h100).
   Confirm the bit mapping: UQ1.8 layout is R9 in bits [35:27], G9 in bits [26:18], B9 in bits [17:9], A9 in bits [8:0].

2. **RGBA8888 decoder: verify expansion to UQ1.8 precision.**
   Provide a 4x4 block of 16 RGBA8888 values with distinct per-channel values.
   Verify expansion produces correct UQ1.8 results: each 8-bit channel maps to `{1'b0, channel8}`.
   Test boundary values including fully transparent (A8=0x00 producing A=9'h000) and fully opaque (A8=0xFF producing A=9'h0FF).

3. **R8 decoder: verify single-channel replication and alpha.**
   Provide 16 single-channel R8 values including 0x00, 0xFF, and intermediate values.
   Verify that R is replicated to G and B channels as UQ1.8: `{1'b0, R8}`.
   Verify A=9'h100 (opaque) for all texels.

4. **texel_promote: verify UQ1.8 → Q4.12 conversion across boundary patterns.**
   Drive boundary 9-bit UQ1.8 channel values through the promotion logic:
   - channel=0x000 (0.0) produces Q4.12=0x0000.
   - channel=0x100 (256/256 = 1.0) produces Q4.12=0x1000.
   - channel=0x080 (128/256 = 0.5) produces Q4.12=0x0800.
   - channel=0x1FF (511/512, maximum UQ1.8) produces Q4.12=0x1FF8.
   Verify the promotion is a combinational left-shift-by-3 with zero-pad as defined in INT-032: `{3'b000, channel_9bit, 3'b000}`.
   Verify all four RGBA channels are promoted independently with the same formula.
   If Step 4 output differs from the INT-032 formula, verify `fp_types_pkg.sv` against INT-032 before updating test vectors.

5. **Stipple test: verify fragment discard logic.**
   - When STIPPLE_EN=1 and the pattern bit at index `(y & 7) * 8 + (x & 7)` is 0: verify discard is asserted.
   - When STIPPLE_EN=1 and the pattern bit is 1: verify discard is deasserted (fragment passes).
   - When STIPPLE_EN=0: verify discard is deasserted regardless of pattern bit value.
   Test with multiple (x, y) coordinates and pattern values to cover corner cases.

6. **BC1 decoder (if present in testbench): verify 4-color and 1-bit alpha punch-through modes.**
   - When color0 > color1: verify 4-color palette interpolation (C0, C1, lerp 1/3, lerp 2/3) using shift+add reciprocal-multiply (DD-039), and all texels opaque.
   - When color0 <= color1: verify 3-color plus transparent mode (C0, C1, lerp 1/2, transparent).
   Verify endpoints are expanded to 8-bit before interpolation and output is 36-bit UQ1.8.

7. **BC2 decoder: verify explicit 4-bit alpha and BC1-style color block.**
   Provide a known 16-byte BC2 block where the 8-byte alpha section contains explicit 4-bit alpha values for all 16 texels and the 8-byte color section contains a standard BC1 color block.
   For each texel, verify alpha expansion and BC1 color decoding using shift+add interpolation (DD-039).
   Verify alpha and color channels are UQ1.8 values matching expected 36-bit output.

8. **BC3 decoder: verify interpolated 8-bit alpha and BC1-style color block.**
   Provide a known 16-byte BC3 block.
   When alpha0 > alpha1: verify the 8-alpha interpolation table (alpha0, alpha1, and 6 interpolated values using shift+add) is applied correctly for each texel index.
   When alpha0 <= alpha1: verify the 6-alpha plus black-and-white table (alpha0, alpha1, 4 interpolated, 0x00, 0xFF).
   Verify that the BC1 color section is decoded correctly for R, G, B channels in both cases.

9. **BC4 decoder: verify single-channel alpha-as-red replication.**
    Provide a known 8-byte BC4 block (single channel, same bit layout as the alpha section of BC3).
    Verify the 8-value interpolation table is applied using shift+add formulas (DD-039) for the red channel.
    Verify that the decoded red value is replicated to G and B channels and that A is opaque for all texels.

10. **BC5 decoder: verify two-channel RG output.**
    Provide a known 16-byte BC5 block constructed as two independent BC3-style 8-byte single-channel blocks (first block for red, second for green).
    Verify that the red channel is decoded from the first block using the BC3 alpha interpolation algorithm and shift+add formulas (DD-039).
    Verify that the green channel is decoded from the second block independently using the same algorithm.
    Verify that B = 9'h000 for all 16 texels.
    Verify that A = 9'h100 (opaque) for all 16 texels.
    Test with a block where red0 > red1 (8-value interpolation table) and a block where red0 <= red1 (6-value table plus 0x00 and 0xFF).

11. **Format-select mux wiring (integration path).**
    For each of the eight `tex_format` encodings (0=BC1 through 7=R8, per INT-032), drive the format select input to the decoder mux and verify that the correct decoder module output is propagated to the mux output.
    Decoder outputs for non-selected formats must not affect the result.
    The `tex_format` input is 4 bits wide (per INT-032, DD-041).

12. **Cache format bit layout verification.**
    Confirm UQ1.8 bit layout matches INT-032: R9 in bits [35:27], G9 in bits [26:18], B9 in bits [17:9], A9 in bits [8:0].

## Expected Results

- **Pass Criteria:**
  - All decoded texel values exactly match software-computed reference values for every tested format (RGB565, RGBA8888, R8, BC1, BC2, BC3, BC4, BC5) in UQ1.8 output format.
  - texel_promote output values match the INT-032 specified Q4.12 expansion formula exactly for UQ1.8 promotion (step 4) (no rounding tolerance; promotion is combinational bit manipulation).
  - Stipple discard signal matches expected value for all tested (x, y, pattern, enable) combinations.
  - Cache format bit field positions match INT-032 UQ1.8 format definition.
  - Format-select mux routes the correct decoder output for all eight `tex_format` encodings.
  - All test assertions pass with zero failures.

- **Fail Criteria:**
  - Any decoded texel differs from its expected reference value for any format.
  - Any texel_promote Q4.12 output differs from the expected bit-exact value.
  - Stipple discard is incorrect for any tested input combination.
  - Format-select mux produces incorrect output for any `tex_format` encoding.
  - The testbench reports one or more assertion failures.

## Test Implementation

- `components/texture/rtl/tests/texture_decoder_tb.sv`: Verilator unit testbench covering the RGB565, RGBA8888, R8, BC1, BC2, BC3, BC4, BC5, texel_promote, stipple, and format-select mux.
  Instantiates each decoder as a separate DUT plus the format-select mux, drives known input block data with specific texel indices, and checks output values (UQ1.8 format) against expected constants.
  Uses embedded test vectors (no external file dependencies).

## Notes

- See INT-032 (Texture Cache Architecture) for the UQ1.8 format definition, conversion tables from each source format, the Q4.12 promotion formula, and the 4-bit `tex_format` encoding table.
  The `fp_types_pkg.sv` package (`shared/fp_types_pkg.sv`) centralizes the Q4.12 type definitions (`q4_12_t`) and the named promotion functions (e.g., `promote_uq18_to_q412`) that implement the INT-032 formula in RTL.
  If Step 4 promotion output differs from the INT-032 formula, verify the `fp_types_pkg.sv` function implementation against INT-032 before updating test vectors.
- `texel_promote.sv` belongs to UNIT-011.04 (Block Decompressor); it implements the UQ1.8 → Q4.12 promotion step that forms the output contract of UNIT-011.
- See `doc/verification/test_strategy.md` for the Verilator simulation framework, coverage goals, and test execution procedures.
- Run this test with: `cd integration && make test-texture-decoder`.
- REQ-003.01 coverage is jointly satisfied by VER-005 (unit test for the decode path in isolation) and VER-012 (golden image integration test exercising the full texture sampling pipeline including cache, rasterizer, and framebuffer output).
- The `texture_decoder_tb` testbench exercises only combinational decoder logic and the format-select mux; it does not test the texture cache fill FSM or SDRAM burst protocol (those are covered by VER-012 and future cache-specific VER documents).
- The `tex_format` field is 4 bits wide, encoding 8 formats (BC1=0, BC2=1, BC3=2, BC4=3, BC5=4, RGB565=5, RGBA8888=6, R8=7) as defined in INT-032 (DD-041).
  The testbench format-select mux test (step 11) must exercise all valid `tex_format` encodings.
