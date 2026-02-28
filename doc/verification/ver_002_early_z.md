# VER-002: Early Z-Test Unit Testbench

## Verification Method

**Test:** Verified by executing the `tb_early_z` Verilator simulation testbench against the early Z-test RTL sub-module of the pixel pipeline (UNIT-006).
The testbench drives fragment depth inputs and Z-buffer values through the `early_z.sv` combinational logic, verifying depth range clipping, all Z comparison functions, bypass conditions, and the Z-buffer clear pattern.

## Verifies Requirements

- REQ-005.02 (Depth Tested Triangle)

## Verified Design Units

- UNIT-006 (Pixel Pipeline) -- specifically the `early_z.sv` sub-module

## Preconditions

- Verilator 5.x installed and available on `$PATH`.
- `spi_gpu/src/render/early_z.sv` compiles without errors under `verilator --lint-only -Wall`.
- `spi_gpu/src/render/pixel_pipeline.sv` compiles without errors under `verilator --lint-only -Wall` (`early_z.sv` is a sub-module of UNIT-006 and shares its port declarations with the pipeline FSM).
  This precondition does not require the full pixel pipeline to be instantiated in the testbench; it ensures the interface definitions are consistent before isolating `early_z.sv` for unit testing.

## Procedure

1. **Depth range test.**
   Configure Z_RANGE_MIN and Z_RANGE_MAX to a restricted range (e.g., [0x0100, 0xFF00]).
   Drive fragment Z values below the minimum, at the minimum boundary, within the range, at the maximum boundary, and above the maximum.
   Verify that `range_pass` is asserted only for fragments within the inclusive [Z_RANGE_MIN, Z_RANGE_MAX] interval.
   Then set Z_RANGE_MIN=0x0000 and Z_RANGE_MAX=0xFFFF (full range, effectively disabled) and verify all fragments pass.

2. **Z-test bypass (Z_TEST_EN=0).**
   Set Z_TEST_EN=0 with any Z_COMPARE function.
   Verify that `z_bypass` is asserted and `z_test_pass` is 1 regardless of fragment and Z-buffer depth values.
   This confirms that depth testing can be fully disabled.

3. **Z-test bypass (Z_COMPARE=ALWAYS).**
   Set Z_TEST_EN=1 and Z_COMPARE=ALWAYS (3'b110).
   Verify that `z_bypass` is asserted and `z_test_pass` is 1 regardless of fragment and Z-buffer depth values.
   This is the mechanism used for Z-buffer clear: when combined with Z_WRITE=1, every fragment unconditionally writes its Z value.

4. **LEQUAL comparison (Z_TEST=1, Z_WRITE=1 scenario).**
   Set Z_TEST_EN=1, Z_COMPARE=LEQUAL.
   Drive fragment Z values that are less than, equal to, and greater than the Z-buffer value.
   Verify that `z_test_pass` is asserted when fragment_z <= zbuffer_z, and deasserted when fragment_z > zbuffer_z.
   This is the normal depth test + write configuration: passing fragments update the Z-buffer.

5. **LEQUAL comparison (Z_TEST=1, Z_WRITE=0 scenario -- read-only depth mask).**
   The `early_z.sv` module itself does not control Z_WRITE; the Z_WRITE enable is applied downstream by the pixel pipeline when deciding whether to issue a Z-buffer write.
   This test verifies the same LEQUAL comparison as step 4.
   The Z_WRITE=0 behavior (depth test without Z-buffer update) is validated at the pixel pipeline integration level, but the comparison logic exercised here is identical.

6. **All comparison functions.**
   With Z_TEST_EN=1, iterate through all eight Z_COMPARE encodings (LESS, LEQUAL, EQUAL, GEQUAL, GREATER, NOTEQUAL, ALWAYS, NEVER).
   For each function, drive fragment/zbuffer pairs that should pass and pairs that should fail.
   Verify `z_test_pass` matches the expected outcome for every pair.

7. **Z-buffer clear via ALWAYS compare mode.**
   Set Z_TEST_EN=1, Z_COMPARE=ALWAYS.
   Drive fragment_z=0xFFFF with any zbuffer_z value.
   Verify that `z_test_pass` is 1 (fragment always passes).
   In the full pipeline, this combined with Z_WRITE=1 causes Z=0xFFFF to be written across all pixels, initializing the Z-buffer to maximum depth.

## Expected Results

- **Pass Criteria:**
  - Depth range test: `range_pass` is 0 for fragment Z values outside [Z_RANGE_MIN, Z_RANGE_MAX] and 1 for values within the inclusive range.
  - Full-range configuration (MIN=0x0000, MAX=0xFFFF): all fragments pass the range test.
  - Z-test bypass: `z_bypass`=1 and `z_test_pass`=1 when Z_TEST_EN=0 or Z_COMPARE=ALWAYS.
  - Active Z-test: `z_bypass`=0 when Z_TEST_EN=1 and Z_COMPARE is not ALWAYS.
  - All eight comparison functions produce correct pass/fail results for every test vector.
  - ALWAYS mode with fragment_z=0xFFFF passes unconditionally (Z-buffer clear pattern).
  - All test assertions pass with zero failures reported by the testbench.

- **Fail Criteria:**
  - Any `range_pass`, `z_test_pass`, or `z_bypass` output differs from its expected value for any test vector.
  - The testbench reports one or more assertion failures.

## Test Implementation

- `spi_gpu/tests/render/tb_early_z.sv`: Verilator unit testbench for the `early_z.sv` module.
  Drives fragment depth and Z-buffer inputs through the depth range clipper and Z comparison logic, checking `range_pass`, `z_test_pass`, and `z_bypass` outputs against expected values for all comparison functions, bypass conditions, and boundary cases.

## Notes

- See `doc/verification/test_strategy.md` for the Verilator simulation framework, coverage goals, and test execution procedures.
- Run this test with: `cd spi_gpu && make test-early-z`.
- The `early_z.sv` module is combinational logic; the testbench uses `#1` delays between stimulus changes rather than a clock.
- Z_WRITE control is not part of `early_z.sv` -- it is applied by the enclosing pixel pipeline (UNIT-006) FSM when deciding whether to issue a Z-buffer write to SDRAM via arbiter port 2.
  The pixel pipeline (not the rasterizer) owns arbiter ports 1 (framebuffer write) and 2 (Z-buffer read/write).
  The Z_WRITE=0 (read-only depth mask) and Z_WRITE=1 (normal depth write) behaviors are validated at the pipeline integration level by VER-011 (golden image depth test).
- REQ-005.02 coverage is jointly satisfied by VER-002 (this unit test covering Z comparison logic) and VER-011 (golden image integration test covering end-to-end depth-tested rendering).
