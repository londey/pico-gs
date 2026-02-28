# VER-003: Register File Unit Testbench

## Verification Method

**Test:** Verified by executing the `tb_register_file` and `register_file_v10_tb` Verilator simulation testbenches against the register file RTL (UNIT-003).
The testbenches drive register read/write sequences, vertex submission flows, and special-function triggers through the command interface, then check all output signals against expected values.

## Verifies Requirements

- REQ-001.01 (Basic Host Communication)
- REQ-001.02 (Memory Upload Interface)
- REQ-001.05 (Vertex Submission Protocol)

## Verified Design Units

- UNIT-003 (Register File)

## Preconditions

- Verilator 5.x installed and available on `$PATH`.
- `spi_gpu/src/spi/register_file.sv` compiles without errors under `verilator --lint-only -Wall`.

## Procedure

1. **Vertex submission (VERTEX_KICK_012).**
   Write COLOR (0x00) with a known RGBA value, write UV0_UV1 (0x01) with known UV coordinates, then write VERTEX_KICK_012 (0x07) with packed X/Y/Z/Q position data.
   Repeat for three vertices to fill the vertex ring buffer.
   Verify that `tri_valid` is asserted for exactly one cycle on the third vertex write.
   Verify that `tri_x`, `tri_y`, `tri_z`, `tri_q`, `tri_color0`, `tri_color1`, `tri_uv0`, and `tri_uv1` outputs carry the correct per-vertex values matching what was written.

2. **Strip submission (VERTEX_NOKICK then VERTEX_KICK_012).**
   Write VERTEX_NOKICK (0x06) for vertex 0, then VERTEX_NOKICK for vertex 1, then VERTEX_KICK_012 (0x07) for vertex 2.
   Verify that `tri_valid` is never asserted during the two VERTEX_NOKICK writes and is asserted for exactly one cycle on the VERTEX_KICK_012 write.
   Verify that all three vertices appear correctly on the `tri_*` output buses.

3. **VERTEX_KICK_021 winding order reversal.**
   Submit three vertices using VERTEX_KICK_021 (0x08) for the third vertex instead of VERTEX_KICK_012.
   Verify that `tri_valid` is asserted for one cycle and the output vertex order is (v0, v2, v1) -- that is, the second and third vertex positions are swapped relative to submission order.

4. **Color latching across vertex writes.**
   Write a distinct COLOR value before each of the three vertex writes.
   After the triangle is kicked, verify that each vertex's `tri_color0` output reflects the COLOR value that was active when that specific vertex was submitted, not the final COLOR value.

5. **Register read-back.**
   For each of the following registers, write a known non-zero value then read back via `cmd_rdata`:
   - COLOR (0x00)
   - CC_MODE (0x18)
   - FB_CONFIG (0x40)
   - CONST_COLOR (0x19)
   - RENDER_MODE (0x30)
   - Z_RANGE (0x31)
   Verify that the read value matches the written value exactly.

6. **ID register.**
   Read address 0x7F.
   Verify that `cmd_rdata` returns the constant value `0x00000A00_00006702`.

7. **MEM_FILL one-cycle trigger.**
   Write MEM_FILL (0x44) with packed base address, fill value, and word count fields.
   Verify that `mem_fill_trigger` is asserted for exactly one clock cycle.
   Verify that `mem_fill_base`, `mem_fill_value`, and `mem_fill_count` outputs match the written values (base=[15:0], value=[31:16], count=[51:32]).
   On the next clock cycle, verify that `mem_fill_trigger` is deasserted.

8. **RENDER_MODE decode (all mode_* outputs).**
   Write RENDER_MODE (0x30) with specific bit patterns and verify that each decoded output matches:
   - `mode_gouraud` = RENDER_MODE[0]
   - `mode_z_test` = RENDER_MODE[2]
   - `mode_z_write` = RENDER_MODE[3]
   - `mode_color_write` = RENDER_MODE[4]
   - `mode_cull` = RENDER_MODE[6:5]
   - `mode_alpha_blend` = RENDER_MODE[9:7]
   - `mode_dither_en` = RENDER_MODE[10]
   - `mode_dither_pattern` = RENDER_MODE[12:11]
   - `mode_z_compare` = RENDER_MODE[15:13]
   - `mode_stipple_en` = RENDER_MODE[16]
   - `mode_alpha_test` = RENDER_MODE[18:17]
   - `mode_alpha_ref` = RENDER_MODE[26:19]
   Test with at least two distinct RENDER_MODE values to exercise both 0 and 1 states of each field.

9. **RENDER_MODE, Z_RANGE, and STIPPLE_PATTERN reset values.**
   After asserting reset (`rst_n` low then high), read back the registers and verify:
   - RENDER_MODE reset value is `0x00` (all mode flags disabled).
   - Z_RANGE reset value has Z_RANGE_MIN=0x0000 and Z_RANGE_MAX=0xFFFF.
   - STIPPLE_PATTERN reset value is `0xFFFFFFFF_FFFFFFFF` (all bits set).

10. **FB_CONFIG writes.**
    Write FB_CONFIG (0x40) with known values for `fb_color_base` [15:0], `fb_z_base` [31:16], `fb_width_log2` [35:32], and `fb_height_log2` [39:36].
    Verify that the corresponding outputs match the written fields exactly.

11. **FB_CONTROL writes.**
    Write FB_CONTROL (0x43) with known scissor rectangle values.
    Verify that `scissor_x` [9:0], `scissor_y` [19:10], `scissor_width` [29:20], and `scissor_height` [39:30] outputs match the written fields.

12. **CC_MODE write and passthrough.**
    Write CC_MODE (0x18) with a two-stage combiner configuration (cycle 0 in [31:0], cycle 1 in [63:32]).
    Verify that the `cc_mode` output passes through the full 64-bit written value combinationally.

13. **CONST_COLOR write and passthrough.**
    Write CONST_COLOR (0x19) with CONST0 in [31:0] and CONST1/fog color in [63:32].
    Verify that the `const_color` output matches the written value.

14. **TEXn_CFG cache invalidation signal.**
    Write TEX0_CFG (0x10) and verify that the texture cache invalidation signal for sampler 0 is asserted for one cycle.
    Write TEX1_CFG (0x11) and verify that the texture cache invalidation signal for sampler 1 is asserted for one cycle.

15. **FB_DISPLAY vsync-blocking behavior.**
    Write FB_DISPLAY (0x41) while `vblank` is deasserted.
    Verify that the SPI pipeline blocks (does not accept further commands) until the next vsync event (`vblank` assertion).
    After vsync occurs, verify that `fb_display_addr`, `fb_lut_addr`, `fb_display_width_log2`, `fb_line_double`, and `color_grade_enable` outputs are updated atomically to the written values.

16. **Cycle counter reset on vsync edge.**
    Allow `cycle_counter` to increment for several clock cycles, then assert `vblank` (rising edge from 0 to 1).
    Verify that `cycle_counter` resets to 0 on the rising edge of vblank.

17. **Cycle counter increment and saturation.**
    Verify that `cycle_counter` increments by 1 on each `clk_core` cycle when no vsync edge is present.
    Force the counter near its maximum value (0xFFFFFFFE), advance clocks, and verify that the counter saturates at 0xFFFFFFFF and does not wrap to 0.

18. **PERF_TIMESTAMP write pulse and read.**
    Write PERF_TIMESTAMP (0x50) with a 23-bit SDRAM word address in DATA[22:0].
    Verify that `ts_mem_wr` is asserted for exactly one cycle with `ts_mem_addr` matching the written address and `ts_mem_data` matching the current `cycle_counter` value.
    Read PERF_TIMESTAMP back and verify that `cmd_rdata` returns `{32'd0, cycle_counter}` (the live instantaneous counter value).

19. **Reset: all registers return to defaults.**
    Write non-default values to all writable registers.
    Assert reset (`rst_n` low for multiple cycles, then high).
    Read back all registers and verify they have returned to their documented default values.

## Expected Results

- **Pass Criteria:**
  - Vertex submission produces a one-cycle `tri_valid` pulse with correct vertex data for VERTEX_KICK_012, VERTEX_KICK_021, and strip (VERTEX_NOKICK + VERTEX_KICK) flows.
  - VERTEX_KICK_021 swaps vertex indices 1 and 2 relative to VERTEX_KICK_012.
  - Per-vertex color latching is correct: each vertex retains the COLOR value active at submission time.
  - All readable registers return the last written value on read-back.
  - ID register returns `0x00000A00_00006702`.
  - `mem_fill_trigger` is a one-cycle pulse with correct base/value/count fields.
  - All `mode_*` outputs correctly decode the corresponding RENDER_MODE bit fields.
  - Reset values: RENDER_MODE=0, Z_RANGE_MIN=0x0000, Z_RANGE_MAX=0xFFFF, STIPPLE_PATTERN=0xFFFFFFFF_FFFFFFFF.
  - FB_CONFIG, FB_CONTROL, CC_MODE, CONST_COLOR outputs match written values.
  - TEXn_CFG writes assert the cache invalidation signal for the correct sampler.
  - FB_DISPLAY write blocks until vsync, then updates outputs atomically.
  - Cycle counter resets on vsync rising edge, increments each cycle, and saturates at 0xFFFFFFFF.
  - PERF_TIMESTAMP write asserts `ts_mem_wr` with correct address and counter snapshot; read returns the live counter.
  - Full reset restores all registers to documented defaults.
  - All test assertions pass with zero failures.

- **Fail Criteria:**
  - Any `tri_valid` pulse, vertex output, register read-back, mode decode, trigger pulse, counter behavior, or reset value differs from its expected value.
  - The testbench reports one or more assertion failures.

## Test Implementation

- `spi_gpu/tests/spi/tb_register_file.sv`: Primary Verilator unit testbench for the register file module.
  Covers register read/write, vertex kick, ID register, and basic functional verification.
- `spi_gpu/tests/spi/register_file_v10_tb.sv`: Extended testbench covering vertex submission flows, MEM_FILL trigger, RENDER_MODE decode, CC_MODE passthrough, FB_CONFIG, and FB_CONTROL field extraction.

## Notes

- See `doc/verification/test_strategy.md` for the Verilator simulation framework, coverage goals, and test execution procedures.
- Run this test with: `cd spi_gpu && make test-register-file`.
- VER-003 covers the union of test cases from both `tb_register_file.sv` and `register_file_v10_tb.sv`.
- The register file is clocked at the unified 100 MHz `clk_core` domain.
- FB_DISPLAY blocking behavior involves interaction with the display controller's vblank signal; the testbench must provide a stimulus model for vblank timing.
- The PERF_TIMESTAMP fire-and-forget behavior (back-to-back writes overwrite the pending request) is documented in UNIT-003 but may require integration-level verification beyond the unit testbench scope.
- Steps 10 and 15 verify that the register file correctly extracts and outputs `fb_width_log2`, `fb_height_log2`, `fb_display_width_log2`, and `fb_line_double` fields.
  VER-003 does not cover downstream consumption of these signals.
  Coverage of the rasterizer's use of `fb_width_log2` and `fb_height_log2` is provided by VER-001.
  Coverage of the display controller's use of `fb_display_width_log2` and `fb_line_double` is provided by VER-010 through VER-013.
- The unit tests in VER-003 verify that all register outputs decode and pass through correctly in isolation.
  These outputs — including `mode_gouraud`, `mode_cull`, `mode_alpha_blend`, `mode_dither_en`, `mode_dither_pattern`, `mode_stipple_en`, `mode_alpha_test`, `mode_alpha_ref`, `tri_uv0`, `tri_uv1`, `tri_q`, `tri_color1`, `cc_mode`, `const_color`, `tex0_cfg`, `tex1_cfg` — all have live downstream consumers in UNIT-006 (Pixel Pipeline) and UNIT-010 (Color Combiner) after pixel pipeline integration.
  The unit-level register file tests remain valid and unchanged; however, golden image tests VER-010 through VER-014 may require re-approval after integration because previously-inert register values now affect rendered output.
