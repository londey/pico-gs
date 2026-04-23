# VER-010: Gouraud Triangle Golden Image Test

## Verification Method

**Test:** Verified by executing a Verilator golden image simulation that renders a Gouraud-shaded triangle through the full GPU RTL hierarchy and compares the output pixel-exactly against an approved golden image.

## Verifies Requirements

- REQ-002.02 (Gouraud Shaded Triangle)

## Verified Design Units

- UNIT-003 (Register File)
- UNIT-005.01 (Triangle Setup)
- UNIT-005 (Rasterizer)
- UNIT-006 (Pixel Pipeline)

## Preconditions

- Integration simulation harness (`rtl/tb/`) compiles successfully under Verilator.
- Golden image `integration/golden/ver_010_gouraud_triangle.png` has been approved and committed.

## Procedure

### Test Scene

The test renders a single Gouraud-shaded triangle with three vertices at known screen coordinates, each with a distinct solid primary color:

| Vertex | Screen Position (12.4 fixed) | Primary Color (RGBA8888) | Description |
|--------|------------------------------|--------------------------|-------------|
| V0 | (256, 40) | `0xFF0000FF` (red, opaque) | Top center |
| V1 | (64, 400) | `0x00FF00FF` (green, opaque) | Bottom left |
| V2 | (448, 400) | `0x0000FFFF` (blue, opaque) | Bottom right |

Secondary vertex colors (COLOR1) are set to black (`0x000000FF`) for all three vertices (not used in this test).
The triangle is large enough to cover a significant portion of the 512x480 viewport, providing thorough coverage of the color interpolation logic across many pixels.

### Harness Command Sequence

The integration harness drives the following register-write sequence into UNIT-003 (Register File) per the SPI register-write protocol defined in INT-010 and INT-012:

1. **Configure framebuffer:**
   Write `FB_CONFIG` (address `0x40`) with:
   - `fb_color_base` = chosen color buffer base address (SDRAM-aligned).
   - `fb_width_log2 = 9` (surface width = 512 pixels).
   - `fb_height_log2 = 9` (surface height = 512 pixels).
   This establishes the surface dimensions used by the rasterizer for scissor bounds and tiled address stride.
   The harness framebuffer readback in step 6 must use these same `fb_width_log2` / `fb_height_log2` values for the block-tiled address calculation (INT-011).

2. **Configure render mode:**
   Write `RENDER_MODE` (address `0x30`) with:
   - `GOURAUD_EN = 1` (bit 0)
   - `Z_TEST_EN = 0` (bit 2)
   - `Z_WRITE_EN = 0` (bit 3)
   - `COLOR_WRITE_EN = 1` (bit 4)
   - All other mode bits = 0 (no texturing, no dithering, no alpha blend, no stipple, no culling)

3. **Submit vertex 0:**
   - Write `COLOR` (address `0x00`) with `0x000000FF_FF0000FF` (COLOR1=black in upper 32 bits, COLOR0=red in lower 32 bits).
   - Write `VERTEX_NOKICK` (address `0x06`) with V0 position (X=256, Y=40, Z=0x0000 packed per register format).

4. **Submit vertex 1:**
   - Write `COLOR` (address `0x00`) with `0x000000FF_00FF00FF` (COLOR1=black, COLOR0=green).
   - Write `VERTEX_NOKICK` (address `0x06`) with V1 position (X=64, Y=400, Z=0x0000).

5. **Submit vertex 2 (with kick):**
   - Write `COLOR` (address `0x00`) with `0x000000FF_0000FFFF` (COLOR1=black, COLOR0=blue).
   - Write `VERTEX_KICK_012` (address `0x07`) with V2 position (X=448, Y=400, Z=0x0000).

6. **Wait for completion:**
   Run the simulation until the `frag_done` signal (or equivalent pipeline-idle indicator) asserts, indicating all fragments have been processed and written to the behavioral SDRAM model.

7. **Read back framebuffer:**
   The harness reads the simulated framebuffer contents from the behavioral SDRAM model using the 4x4 block-tiled address layout per INT-011, with `WIDTH_LOG2 = 9` matching the `fb_width_log2` written in step 1.
   The pixel data is serialized as a PNG file at `integration/sim_out/ver_010_gouraud_triangle.png`.

8. **Pixel-exact comparison:**
   Compare the simulation output against the approved golden image:
   ```
   diff -q integration/sim_out/ver_010_gouraud_triangle.png integration/golden/ver_010_gouraud_triangle.png
   ```

## Expected Results

- **Pass Criteria:** Pixel-exact match between the simulation output (`integration/sim_out/ver_010_gouraud_triangle.png`) and the approved golden image (`integration/golden/ver_010_gouraud_triangle.png`).
  The rendered image should show a triangle with smooth color gradients: red at the top vertex, green at the bottom-left vertex, and blue at the bottom-right vertex, with linearly interpolated colors across the interior.

## Test Implementation

- `rtl/tb/`: Integration simulation harness.
  Instantiates the full GPU RTL hierarchy under Verilator, provides a behavioral SDRAM model, drives register-write command sequences, and reads back the framebuffer as PNG files.
- `integration/golden/ver_010_gouraud_triangle.png`: Approved golden image (created after the initial simulation run is visually inspected and approved).

## Notes

- See `doc/verification/test_strategy.md` (Golden Image Approval Testing section) for the approval workflow: run the simulation, visually inspect the output PNG, copy to the `golden/` directory, and commit.
- Golden image approval workflow: after the harness is implemented and this test first runs successfully, inspect the rendered output visually, copy `integration/sim_out/ver_010_gouraud_triangle.png` to `integration/golden/ver_010_gouraud_triangle.png`, and commit with a message describing the approved image.
- Run this test with: `cd integration && make test-gouraud`.
- The background of the framebuffer (pixels outside the triangle) will contain whatever the SDRAM model initializes to (typically zero/black).
  The golden image includes the full 512×512 framebuffer surface, so the background color is part of the pixel-exact comparison.
- **The golden image requires re-approval after Phase 2 RTL implementation.**
  The rasterizer traversal order changes from scanline order to 4×4 tile-major order (REQ-002.03); fragment emission order affects framebuffer write sequencing and the exact pixel values produced by incremental derivative interpolation.
  Additionally, the rasterizer uses incremental derivative interpolation (not barycentric multiply-accumulate), which may shift interpolated color values by 1 ULP at some pixel locations.
  After Phase 2 RTL implementation is complete, re-run the test, visually inspect the output, and re-commit the golden image before marking this test as passing.
- The golden image must also be regenerated and re-approved whenever the rasterizer tiled address stride changes (e.g. after wiring `fb_width_log2` to replace a hardcoded constant), since pixel positions in the framebuffer may shift.
  The split of the shared reciprocal LUT into dedicated area and per-pixel 1/Q modules (`raster_recip_area.sv`, `raster_recip_q.sv`) and the addition of the setup-iteration overlap FIFO do not affect Gouraud-only rendering (no perspective correction path exercised), so golden image re-approval is not expected for that change alone.
  The conversion of derivative precomputation (UNIT-005.03) from combinational to sequential time-multiplexed computation does not change the computed derivative values, only the timing; golden image re-approval is not expected for that change alone unless the derivative computation fix also corrects rendering bugs (displaced fragments, incorrect vertex colors) that affect the Gouraud interpolation output.
  See `test_strategy.md` for the re-approval workflow.
- Dithering is disabled (`DITHER_EN=0`) for this test to ensure deterministic, fully reproducible output.
  Dithered rendering is tested separately in VER-013.
- Z-testing and Z-writing are disabled to isolate color interpolation correctness from depth buffer behavior.
  Depth-tested rendering is covered by VER-011.
- This test does not exercise texture hardware; the Gouraud path routes directly from the rasterizer through UNIT-006's color combiner stage without invoking UNIT-011 (Texture Sampler).
  UNIT-006's scope in this test is limited to vertex color interpolation, dither, and framebuffer write — no texture hardware is exercised.
- The introduction of `fp_types_pkg.sv` (centralized Q4.12 typedef and constant definitions) is a structural RTL refactoring that does not alter pixel computation for Gouraud-shaded rendering.
  This test does not exercise UV interpolation or texture sampling, so the UV format resolution (Q4.12 on the fragment bus) has no effect on the rendered output.
  Golden image re-approval after the `fp_types_pkg.sv` change is not expected unless synthesis timing or register reset behavior changes.
