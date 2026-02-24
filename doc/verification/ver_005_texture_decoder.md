# VER-005: Texture Decoder Unit Testbench

## Verification Method

**Test:** Verified by executing the `texture_decoder_tb` Verilator simulation testbench against the texture decoder RTL sub-modules of UNIT-006 (Pixel Pipeline).
The testbench drives known input data through each texture format decoder and the texel promotion and stipple modules, then compares decoded RGBA5652 output against software-computed reference values.

## Verifies Requirements

- REQ-003.01 (Textured Triangle)
- REQ-003.03 (Compressed Textures)

## Verified Design Units

- UNIT-006 (Pixel Pipeline — texture decoder sub-modules)

## Preconditions

- Verilator 5.x installed and available on `$PATH`.
- The following RTL source files compile without errors under `verilator --lint-only -Wall`:
  - `spi_gpu/src/render/texture_rgb565.sv`
  - `spi_gpu/src/render/texture_rgba8888.sv`
  - `spi_gpu/src/render/texture_r8.sv`
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

5. **Stipple test: verify fragment discard logic.**
   - When STIPPLE_EN=1 and the pattern bit at index `(y & 7) * 8 + (x & 7)` is 0: verify discard is asserted.
   - When STIPPLE_EN=1 and the pattern bit is 1: verify discard is deasserted (fragment passes).
   - When STIPPLE_EN=0: verify discard is deasserted regardless of pattern bit value.
   Test with multiple (x, y) coordinates and pattern values to cover corner cases.

6. **BC1 decoder (if present in testbench): verify 4-color and 1-bit alpha punch-through modes.**
   - When color0 > color1: verify 4-color palette interpolation (C0, C1, lerp 1/3, lerp 2/3) and all texels opaque (A2=11).
   - When color0 <= color1: verify 3-color plus transparent mode (C0, C1, lerp 1/2, transparent with A2=00).

7. **RGBA5652 encoding format verification.**
   Confirm the RGBA5652 bit layout matches INT-032: R5 in bits [17:13], G6 in bits [12:7], B5 in bits [6:2], A2 in bits [1:0].

## Expected Results

- **Pass Criteria:**
  - All decoded texel values exactly match software-computed reference values for every tested format (RGB565, RGBA8888, R8).
  - texel_promote output values match the INT-032 specified Q4.12 expansion formulas exactly (no rounding tolerance; promotion is combinational bit manipulation).
  - Stipple discard signal matches expected value for all tested (x, y, pattern, enable) combinations.
  - RGBA5652 bit field positions match INT-032 format definition.
  - All test assertions pass with zero failures.

- **Fail Criteria:**
  - Any decoded RGBA5652 texel differs from its expected reference value.
  - Any texel_promote Q4.12 output differs from the expected bit-exact value.
  - Stipple discard is incorrect for any tested input combination.
  - The testbench reports one or more assertion failures.

## Test Implementation

- `spi_gpu/tests/render/texture_decoder_tb.sv`: Verilator unit testbench covering the RGB565, RGBA8888, R8, texel_promote, and stipple modules.
  Instantiates each decoder as a separate DUT, drives known input block data with specific texel indices, and checks output RGBA5652 values against expected constants.
  Uses embedded test vectors (no external file dependencies).

## Notes

- See INT-032 (Texture Cache Architecture) for the RGBA5652 format definition, conversion tables from each source format, and Q4.12 promotion formulas.
- See `doc/verification/test_strategy.md` for the Verilator simulation framework, coverage goals, and test execution procedures.
- Run this test with: `cd spi_gpu && make test-texture-decoder`.
- **BC2, BC3, and BC4 decoders are not yet covered by this testbench.**
  These compressed format decoders should be added in a follow-on VER document or by extending VER-005 once the RTL modules (`texture_bc2.sv`, `texture_bc3.sv`, `texture_bc4.sv`) reach testable status.
- REQ-003.01 coverage is jointly satisfied by VER-005 (unit test for the decode path in isolation) and VER-012 (golden image integration test exercising the full texture sampling pipeline including cache, rasterizer, and framebuffer output).
- The `texture_decoder_tb` testbench exercises only combinational decoder logic; it does not test the texture cache fill FSM or SDRAM burst protocol (those are covered by VER-012 and future cache-specific VER documents).
