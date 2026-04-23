# VER-004: Color Combiner Unit Testbench

## Verification Method

**Test:** Verified by executing the `color_combiner_tb` Verilator simulation testbench against the color combiner RTL (UNIT-010).
The testbench drives controlled fragment inputs and combiner mode configurations through the three-pass time-multiplexed pipeline, then compares combined output colors against a software reference model within Q4.12 rounding tolerance.
Pass-2 blend mode cases supply a simulated DST_COLOR value in place of the color tile buffer to exercise the blend equations in isolation.

## Verifies Requirements

- REQ-004.01 (Color Combiner)

## Verified Design Units

- UNIT-010 (Color Combiner)

## Preconditions

- The testbench provides a simulated DST_COLOR input vector for pass-2 blend test cases (the color tile buffer is not instantiated in the unit testbench; DST_COLOR is driven directly).

## Procedure

1. **CC_MODE register configures all three combiner passes.**
   Write a CC_MODE value with distinct pass 0 selectors in [31:0], pass 1 selectors in [63:32], and pass 2 selectors in [95:64] per INT-010 encoding.
   Drive a fragment through the pipeline and verify that all three passes apply their respective `(A - B) * C + D` equations using the configured input selectors.

2. **TEX_COLOR0 and TEX_COLOR1 input sourcing.**
   Set TEX_COLOR0 and TEX_COLOR1 to known distinct Q4.12 RGBA values.
   Configure cycle 0 to pass through TEX0 (A=TEX0, B=ZERO, C=ONE, D=ZERO) and verify the output matches TEX_COLOR0.
   Repeat with TEX1 as the A source and verify the output matches TEX_COLOR1.

3. **SHADE0 and SHADE1 input sourcing.**
   Set SHADE0 and SHADE1 to known distinct Q4.12 RGBA values.
   Configure cycle 0 to pass through SHADE0 and verify the output matches SHADE0.
   Repeat with SHADE1 as the A source and verify the output matches SHADE1.

4. **CONST0 and CONST1 loading from CONST_COLOR register.**
   Write CONST_COLOR with CONST0 in [31:0] and CONST1 in [63:32] as RGBA8888 UNORM8 values.
   Configure the combiner to pass through CONST0 and verify the output matches the expected Q4.12 promoted value.
   Repeat for CONST1.
   Verify that UNORM8-to-Q4.12 promotion uses the correct MSB replication formula: `{3'b0, unorm8, unorm8[7:4]}`.

5. **COMBINED source propagation across all three passes.**
   Configure pass 0 to pass through SHADE0 (A=SHADE0, B=ZERO, C=ONE, D=ZERO).
   Configure pass 1 to pass through COMBINED (A=COMBINED, B=ZERO, C=ONE, D=ZERO).
   Configure pass 2 to pass through COMBINED (A=COMBINED, B=ZERO, C=ONE, D=ZERO).
   Drive a fragment with a known SHADE0 value and verify that the final output equals SHADE0, confirming COMBINED propagates from pass 0 through pass 1 into pass 2.

6. **MODULATE mode: TEX0 * SHADE0.**
   Set TEX_COLOR0 to Q4.12(0.5) and SHADE0 to Q4.12(0.5) for all channels.
   Configure cycle 0 as modulate: A=TEX0, B=ZERO, C=SHADE0, D=ZERO.
   Configure cycle 1 as passthrough.
   Verify the output equals Q4.12(0.25) within rounding tolerance of +/-1 LSB per channel.

7. **DECAL mode: TEX0 passes through unchanged.**
   Set TEX_COLOR0 to a known non-trivial Q4.12 RGBA value.
   Configure cycle 0 as decal: A=TEX0, B=ZERO, C=ONE, D=ZERO.
   Configure cycle 1 as passthrough.
   Verify the output exactly matches TEX_COLOR0 (C=ONE, B=D=ZERO produces identity).

8. **LIGHTMAP mode: TEX0 * TEX1.**
   Set TEX_COLOR0 and TEX_COLOR1 to known Q4.12 values.
   Configure cycle 0: A=TEX0, B=ZERO, C=TEX1, D=ZERO (or equivalent using the RGB C selector for TEX1).
   Configure cycle 1 as passthrough.
   Verify the output matches `TEX0 * TEX1` within Q4.12 rounding tolerance of +/-1 LSB per channel.

9. **MODULATE_ADD mode: two-stage specular composition.**
   Configure cycle 0 as modulate: A=TEX0, B=ZERO, C=SHADE0, D=ZERO.
   Configure cycle 1 as add specular: A=COMBINED, B=ZERO, C=ONE, D=SHADE1.
   Set TEX0, SHADE0, and SHADE1 to known values.
   Verify the final output matches `(TEX0 * SHADE0) + SHADE1` within Q4.12 rounding tolerance, with saturation applied if the sum exceeds 1.0.

10. **FOG mode: blends combined color toward CONST1 based on fog factor.**
    Configure cycle 0 to produce a known lit/textured color (e.g., TEX0 * SHADE0).
    Configure cycle 1 as fog: A=COMBINED, B=CONST1, C=SHADE0_ALPHA, D=CONST1, which computes `lerp(COMBINED, CONST1, SHADE0.A)`.
    Set SHADE0.A (fog factor) to Q4.12(0.5), CONST1 (fog color) to a known value.
    Verify the output is the midpoint between the cycle 0 result and CONST1, within Q4.12 rounding tolerance of +/-1 LSB per channel.

11. **Per-component operation (R, G, B, A independently).**
    Set TEX_COLOR0 with distinct R, G, B, A values (e.g., R=0.25, G=0.5, B=0.75, A=1.0).
    Set SHADE0 with distinct per-channel values.
    Configure modulate mode and verify that each output channel reflects its own independent `TEX0_ch * SHADE0_ch` product.
    No channel value should leak into or influence another channel.

12. **Single-stage pass-through configuration.**
    Configure cycle 1 with A=COMBINED, B=ZERO, C=ONE, D=ZERO (the documented pass-through).
    Configure cycle 0 to produce a known output.
    Verify the final output equals the cycle 0 output exactly, confirming that the pass-through cycle 1 is a no-op.

13. **Q4.12 saturation: overflow clamps to 1.0.**
    Configure all three passes with A=ONE, B=ZERO, C=ONE, D=ONE for pass 0 (producing `1.0 * 1.0 + 1.0 = 2.0`); configure passes 1 and 2 as passthrough.
    Verify the output is clamped to Q4.12(1.0) = 0x1000 for all channels.

14. **Q4.12 saturation: underflow clamps to 0.0.**
    Configure a subtraction in pass 0 that produces a negative intermediate (e.g., A=ZERO, B=ONE, C=ONE, D=ZERO → `(0 - 1) * 1 + 0 = -1.0`); configure passes 1 and 2 as passthrough.
    Verify that the output is clamped to Q4.12(0.0) = 0x0000 for all channels (UNORM [0, 1.0] saturation range).

15. **Pass-2 ADD blend mode.**
    Configure passes 0 and 1 as passthrough.
    Set RENDER_MODE.ALPHA_BLEND = ADD (001).
    Drive a known COMBINED value (pass 0/1 output) and a known DST_COLOR value such that their sum does not overflow.
    Verify pass-2 output equals `saturate(COMBINED + DST_COLOR)` within +/-1 LSB per channel.
    Repeat with values that overflow 1.0 and verify saturation clamps to Q4.12(1.0).

16. **Pass-2 SUBTRACT blend mode.**
    Configure passes 0 and 1 as passthrough.
    Set RENDER_MODE.ALPHA_BLEND = SUBTRACT (010).
    Drive a known COMBINED value and a DST_COLOR value.
    Verify pass-2 output equals `saturate(COMBINED - DST_COLOR)` within +/-1 LSB per channel.
    Verify underflow clamps to Q4.12(0.0).

17. **Pass-2 BLEND (Porter-Duff source-over).**
    Configure passes 0 and 1 as passthrough.
    Set RENDER_MODE.ALPHA_BLEND = BLEND (011).
    Drive COMBINED with alpha = Q4.12(0.5) and a distinct DST_COLOR value.
    Verify pass-2 output equals `COMBINED * 0.5 + DST_COLOR * 0.5` within +/-1 LSB per channel.
    Repeat with alpha = 0.0 (output = DST_COLOR) and alpha = 1.0 (output = COMBINED).

18. **DST_COLOR promotion from RGB565 to Q4.12.**
    Apply a known RGB565 value as DST_COLOR input (simulating a tile buffer read).
    Configure a pass to read DST_COLOR (A=DST_COLOR, B=ZERO, C=ONE, D=ZERO).
    Verify Q4.12 output matches the expected MSB-replication promotion:
    R5 → `{3'b0, R5, R5[4:1], 3'b0}`, G6 → `{3'b0, G6, G6[5:2], 2'b0}`, B5 → same as R5, A = ONE.

## Expected Results

- **Pass Criteria:**
  - All combiner mode configurations (modulate, decal, lightmap, modulate_add, fog) produce outputs matching the reference `(A - B) * C + D` equation within Q4.12 rounding tolerance of +/-1 LSB per channel.
  - COMBINED propagates correctly: pass 1 COMBINED equals pass 0 output; pass 2 COMBINED equals pass 1 output.
  - CONST0 and CONST1 are correctly promoted from RGBA8888 UNORM8 to Q4.12.
  - DST_COLOR is correctly promoted from RGB565 to Q4.12 using MSB replication.
  - Pass-2 ADD, SUBTRACT, and BLEND modes each produce output matching the reference equation within +/-1 LSB per channel.
  - All operations apply independently per component (R, G, B, A).
  - Pass-through (pass 2 = identity) produces output equal to pass 1.
  - Overflow saturates to Q4.12(1.0); underflow saturates to Q4.12(0.0).
  - Fragment position (x, y) and depth (z) pass through unchanged.
  - All test assertions pass with zero failures.

## Test Implementation

- `rtl/components/color-combiner/tests/color_combiner_tb.sv`: Verilator unit testbench for the color combiner module.
  Drives fragment inputs with known Q4.12 RGBA values, configures CC_MODE for various combiner presets, and checks combined output colors against reference values with Q4.12 rounding tolerance.

## Notes

- See `doc/verification/test_strategy.md` for the Verilator simulation framework, coverage goals, and test execution procedures.
- Run this test with: `cd integration && make test-color-combiner`.
- The color combiner is instantiated inside `pixel_pipeline.sv` (UNIT-006) and receives its `cc_mode` and `const_color` inputs directly from the register file (UNIT-003) outputs.
  VER-004 tests the combiner in isolation; end-to-end combiner behavior through the full pipeline including the color tile buffer is verified by VER-013 (color-combined output) and VER-024 (alpha blend modes).
- The color combiner operates at the unified 100 MHz `clk_core` domain with a 4-cycle/fragment throughput target.
  The testbench uses a matching 100 MHz clock and drives fragments at the 4-cycle rate.
- Q4.12 rounding tolerance of +/-1 LSB per channel accounts for the truncation inherent in `(a * b) >> 12` fixed-point multiplication.
- The Q4.12 arithmetic constants ONE (0x1000) and ZERO (0x0000) used in the testbench are sourced from `fp_types_pkg.sv` (`rtl/pkg/fp_types_pkg.sv`), which centralizes all fixed-point type definitions and constants for the render pipeline.
  When configuring pass-through or identity combiner modes (C=ONE, B=ZERO, D=ZERO), the testbench must use the constant values defined in `fp_types_pkg.sv` to remain consistent with the RTL under test.
- Pass-2 blend test cases (tests 15–18) drive DST_COLOR as a direct testbench input; integration with the actual color tile buffer is covered by VER-024.
