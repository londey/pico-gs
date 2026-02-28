# VER-010: Gouraud Triangle Golden Image Test

## Verification Method

**Test:** Verified by executing a Verilator golden image simulation that renders a Gouraud-shaded triangle through the full GPU RTL hierarchy and compares the output pixel-exactly against an approved golden image.

## Verifies Requirements

- REQ-002.02 (Gouraud Shaded Triangle)

## Verified Design Units

- UNIT-003 (Register File)
- UNIT-004 (Triangle Setup)
- UNIT-005 (Rasterizer)
- UNIT-006 (Pixel Pipeline)

## Preconditions

- Integration simulation harness (`spi_gpu/tests/harness/`) compiles successfully under Verilator.
- Golden image `spi_gpu/tests/golden/gouraud_triangle.ppm` has been approved and committed.
- Verilator 5.x is installed and available on `$PATH`.
- All RTL sources in the rendering pipeline (`register_file.sv`, `rasterizer.sv`, `pixel_pipeline.sv`) compile without errors under `verilator --lint-only -Wall`.

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

The integration harness drives the following register-write sequence into UNIT-003 (Register File), replicating the register writes that a `RenderMeshPatch` command produces per INT-021:

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
   The pixel data is serialized as a PPM file at `spi_gpu/tests/sim_out/gouraud_triangle.ppm`.

8. **Pixel-exact comparison:**
   Compare the simulation output against the approved golden image:
   ```
   diff -q spi_gpu/tests/sim_out/gouraud_triangle.ppm spi_gpu/tests/golden/gouraud_triangle.ppm
   ```

## Expected Results

- **Pass Criteria:** Pixel-exact match between the simulation output (`spi_gpu/tests/sim_out/gouraud_triangle.ppm`) and the approved golden image (`spi_gpu/tests/golden/gouraud_triangle.ppm`).
  The rendered image should show a triangle with smooth color gradients: red at the top vertex, green at the bottom-left vertex, and blue at the bottom-right vertex, with linearly interpolated colors across the interior.

- **Fail Criteria:** Any pixel differs between the simulation output and the approved golden image.
  Common failure modes include incorrect incremental interpolation (incorrect derivative step values or accumulation), incorrect RGB888-to-RGB565 conversion, off-by-one edge walking, or incorrect edge function setup.

## Test Implementation

- `spi_gpu/tests/harness/`: Integration simulation harness.
  Instantiates the full GPU RTL hierarchy under Verilator, provides a behavioral SDRAM model, drives register-write command sequences, and reads back the framebuffer as PPM files.
- `spi_gpu/tests/golden/gouraud_triangle.ppm`: Approved golden image (created after the initial simulation run is visually inspected and approved).

## Notes

- See `doc/verification/test_strategy.md` (Golden Image Approval Testing section) for the approval workflow: run the simulation, visually inspect the output PPM, copy to the `golden/` directory, and commit.
- Golden image approval workflow: after the harness is implemented and this test first runs successfully, inspect the rendered output visually, copy `spi_gpu/tests/sim_out/gouraud_triangle.ppm` to `spi_gpu/tests/golden/gouraud_triangle.ppm`, and commit with a message describing the approved image.
- Run this test with: `cd spi_gpu && make test-gouraud`.
- The background of the framebuffer (pixels outside the triangle) will contain whatever the SDRAM model initializes to (typically zero/black).
  The golden image includes the full 512×512 framebuffer surface, so the background color is part of the pixel-exact comparison.
- **The golden image requires re-approval after pixel pipeline integration.**
  Two changes affect pixel values: (1) the rasterizer now uses incremental derivative interpolation instead of the barycentric multiply-accumulate method, which may shift interpolated color values by 1 ULP at some pixel locations; (2) the `GOURAUD_EN=1` flag written in the harness command sequence is now functionally active in the pixel pipeline (UNIT-006), whereas it previously had no effect on the stub pipeline.
  After integration, re-run the test, visually inspect the output, and re-commit the golden image.
- The golden image must also be regenerated and re-approved whenever the rasterizer tiled address stride changes (e.g. after wiring `fb_width_log2` to replace a hardcoded constant), since pixel positions in the framebuffer may shift.
  See `test_strategy.md` for the re-approval workflow.
- Dithering is disabled (`DITHER_EN=0`) for this test to ensure deterministic, fully reproducible output.
  Dithered rendering is tested separately in VER-013.
- Z-testing and Z-writing are disabled to isolate color interpolation correctness from depth buffer behavior.
  Depth-tested rendering is covered by VER-011.
