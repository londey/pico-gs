# VER-011: Depth-Tested Overlapping Triangles Golden Image Test

## Verification Method

**Test:** Verified by executing a Verilator golden image simulation that renders two overlapping triangles with known depth values through the full GPU RTL hierarchy and compares the output pixel-exactly against an approved golden image.
The test confirms that the near triangle occludes the far triangle at every overlapping pixel when Z-testing is enabled.

## Verifies Requirements

- REQ-005.02 (Depth Tested Triangle)

## Verified Design Units

- UNIT-003 (Register File)
- UNIT-004 (Triangle Setup)
- UNIT-005 (Rasterizer)
- UNIT-006 (Pixel Pipeline -- early Z-test path)

## Preconditions

- Integration simulation harness (`spi_gpu/tests/harness/`) compiles successfully under Verilator.
- Golden image `spi_gpu/tests/golden/depth_test.ppm` has been approved and committed.
- Z-buffer initialized to `0xFFFF` via a Z-buffer clear pass before rendering (see Z-buffer clear step below).
- Verilator 5.x is installed and available on `$PATH`.
- All RTL sources in the rendering pipeline (`register_file.sv`, `rasterizer.sv`, `pixel_pipeline.sv`, `early_z.sv`) compile without errors under `verilator --lint-only -Wall`.

## Procedure

### Z-Buffer Clear Step

Before rendering, the Z-buffer must be initialized to the maximum depth value (`0xFFFF`) so that all incoming fragments pass the initial depth test.
The clear is performed using the ALWAYS compare mode:

1. Write `RENDER_MODE` (address `0x30`) with:
   - `Z_TEST_EN = 1` (bit 2)
   - `Z_WRITE_EN = 1` (bit 3)
   - `Z_COMPARE = ALWAYS` (3'd6)
   - `COLOR_WRITE_EN = 0` (bit 4 = 0, no color writes during clear)
2. Render a screen-filling triangle (or pair of triangles) with Z = `0xFFFF` at all vertices.
   This writes `0xFFFF` to every Z-buffer location via the ALWAYS compare path, which bypasses comparison and unconditionally writes the depth value.
3. Wait for the clear pass to complete (pipeline idle).

This step also serves as independent verification that the ALWAYS compare mode and Z_WRITE path function correctly.

### Test Scene

The test renders two overlapping flat-colored triangles at different depths.
Triangle A (far) is rendered first; Triangle B (near) is rendered second.
In the overlap region, Triangle B must occlude Triangle A because its Z value is smaller (nearer).

**Triangle A (far, rendered first):**

| Vertex | Screen Position (12.4 fixed) | Primary Color (RGBA8888) | Z Value |
|--------|------------------------------|--------------------------|---------|
| A0 | (80, 100) | `0xFF0000FF` (red, opaque) | `0x8000` |
| A1 | (320, 100) | `0xFF0000FF` (red, opaque) | `0x8000` |
| A2 | (200, 380) | `0xFF0000FF` (red, opaque) | `0x8000` |

**Triangle B (near, rendered second):**

| Vertex | Screen Position (12.4 fixed) | Primary Color (RGBA8888) | Z Value |
|--------|------------------------------|--------------------------|---------|
| B0 | (160, 80) | `0x0000FFFF` (blue, opaque) | `0x4000` |
| B1 | (400, 80) | `0x0000FFFF` (blue, opaque) | `0x4000` |
| B2 | (280, 360) | `0x0000FFFF` (blue, opaque) | `0x4000` |

Both triangles use flat shading (constant Z and constant color across all vertices) to simplify the expected result:
- Pixels covered only by Triangle A are red.
- Pixels covered only by Triangle B are blue.
- Pixels in the overlap region are blue (Triangle B wins because Z=`0x4000` < Z=`0x8000`).
- Background pixels (outside both triangles) are black (SDRAM model default).

Secondary vertex colors (COLOR1) are set to black (`0x000000FF`) for all vertices (not used in this test).

### Harness Command Sequence

The integration harness drives the following register-write sequence into UNIT-003 (Register File):

1. **Z-buffer clear pass** (see Z-Buffer Clear Step above).

2. **Configure render mode for depth-tested rendering:**
   Write `RENDER_MODE` (address `0x30`) with:
   - `GOURAUD_EN = 1` (bit 0, or flat shading -- colors are identical per triangle so interpolation produces the same value)
   - `Z_TEST_EN = 1` (bit 2)
   - `Z_WRITE_EN = 1` (bit 3)
   - `COLOR_WRITE_EN = 1` (bit 4)
   - `Z_COMPARE = LEQUAL` (default comparison function)
   - All other mode bits = 0 (no texturing, no dithering, no alpha blend, no stipple, no culling)

3. **Configure framebuffer:**
   Write `FB_CONFIG` (address `0x40`) with:
   - `fb_color_base` = chosen color buffer base address (SDRAM-aligned).
   - `fb_width_log2 = 9` (surface width = 512 pixels).
   - `fb_height_log2 = 9` (surface height = 512 pixels).
   Write `FB_ZBUFFER` for the Z-buffer base address (separate from color buffer per INT-011).
   The harness framebuffer readback in step 8 must use `WIDTH_LOG2 = 9` for the block-tiled address calculation (INT-011).

4. **Render Triangle A (far):**
   - Write `COLOR` (address `0x00`) with `0x000000FF_FF0000FF` (COLOR1=black, COLOR0=red).
   - Write `VERTEX_NOKICK` (address `0x06`) with A0 position (X=80, Y=100, Z=`0x8000`).
   - Write `COLOR` (address `0x00`) with `0x000000FF_FF0000FF` (COLOR1=black, COLOR0=red).
   - Write `VERTEX_NOKICK` (address `0x06`) with A1 position (X=320, Y=100, Z=`0x8000`).
   - Write `COLOR` (address `0x00`) with `0x000000FF_FF0000FF` (COLOR1=black, COLOR0=red).
   - Write `VERTEX_KICK_012` (address `0x07`) with A2 position (X=200, Y=380, Z=`0x8000`).

5. **Wait for Triangle A to complete** (pipeline idle).

6. **Render Triangle B (near):**
   - Write `COLOR` (address `0x00`) with `0x000000FF_0000FFFF` (COLOR1=black, COLOR0=blue).
   - Write `VERTEX_NOKICK` (address `0x06`) with B0 position (X=160, Y=80, Z=`0x4000`).
   - Write `COLOR` (address `0x00`) with `0x000000FF_0000FFFF` (COLOR1=black, COLOR0=blue).
   - Write `VERTEX_NOKICK` (address `0x06`) with B1 position (X=400, Y=80, Z=`0x4000`).
   - Write `COLOR` (address `0x00`) with `0x000000FF_0000FFFF` (COLOR1=black, COLOR0=blue).
   - Write `VERTEX_KICK_012` (address `0x07`) with B2 position (X=280, Y=360, Z=`0x4000`).

7. **Wait for completion:**
   Run the simulation until the `frag_done` signal (or equivalent pipeline-idle indicator) asserts, indicating all fragments have been processed and written to the behavioral SDRAM model.

8. **Read back framebuffer:**
   The harness reads the simulated framebuffer contents from the behavioral SDRAM model using the 4x4 block-tiled address layout per INT-011, with `WIDTH_LOG2 = 9` matching the `fb_width_log2` written in step 3.
   The pixel data is serialized as a PPM file at `spi_gpu/tests/sim_out/depth_test.ppm`.

9. **Pixel-exact comparison:**
   Compare the simulation output against the approved golden image:
   ```
   diff -q spi_gpu/tests/sim_out/depth_test.ppm spi_gpu/tests/golden/depth_test.ppm
   ```

10. **Overlap region assertion:**
    In the overlap region (pixels covered by both triangles), every pixel must match Triangle B's color (blue converted to RGB565).
    Outside the overlap region, pixels covered by Triangle A must be red (RGB565), and pixels covered by Triangle B must be blue (RGB565).
    This assertion is implicitly verified by the pixel-exact golden image comparison, since the golden image encodes the correct near-wins occlusion behavior.

## Expected Results

- **Pass Criteria:** Pixel-exact match between the simulation output (`spi_gpu/tests/sim_out/depth_test.ppm`) and the approved golden image (`spi_gpu/tests/golden/depth_test.ppm`).
  The near triangle (blue, Z=`0x4000`) occludes the far triangle (red, Z=`0x8000`) at every pixel in the overlap region.
  Pixels outside the overlap show only the triangle that covers them (red or blue), and the background is black.

- **Fail Criteria:** Any pixel differs between the simulation output and the approved golden image.
  Common failure modes include:
  - Far triangle bleeding through in the overlap region (Z-test not comparing correctly).
  - Z-buffer not being cleared to `0xFFFF` before rendering (first triangle fails depth test).
  - Z-write not updating the Z-buffer after Triangle A (Triangle B's LEQUAL test has no stored value to compare against).
  - Incorrect Z interpolation across the triangle surface.
  - ALWAYS compare mode not bypassing the depth comparison during the clear pass.

## Test Implementation

- `spi_gpu/tests/harness/`: Integration simulation harness.
  Instantiates the full GPU RTL hierarchy under Verilator, provides a behavioral SDRAM model, drives register-write command sequences, and reads back the framebuffer as PPM files.
- `spi_gpu/tests/golden/depth_test.ppm`: Approved golden image (created after the initial simulation run is visually inspected and approved).

## Notes

- See `doc/verification/test_strategy.md` (Golden Image Approval Testing section) for the approval workflow: run the simulation, visually inspect the output PPM, copy to the `golden/` directory, and commit.
- The Z-buffer clear step serves dual purpose: it is a precondition for the depth test and also provides independent verification that the ALWAYS compare mode with Z_WRITE=1 correctly writes `0xFFFF` to the entire Z-buffer.
  If the clear fails, Triangle A will not render because the uninitialized Z-buffer may contain values that cause fragments to be discarded.
- Run this test with: `cd spi_gpu && make test-depth-test`.
- Dithering is disabled (`DITHER_EN=0`) for this test to ensure deterministic, fully reproducible output.
- VER-011 provides full-pipeline confirmation of Z-buffer behavior; VER-002 (`tb_early_z`) provides unit-level confirmation.
  Together they jointly satisfy REQ-005.02 per the requirement document's Verification Method section.
- **The Z-buffer read and write paths are owned by the pixel pipeline (UNIT-006)**, not the rasterizer (UNIT-005), after pixel pipeline integration.
  The rasterizer emits fragments via the valid/ready handshake interface; the pixel pipeline's FSM reads the Z-buffer (arbiter port 2), invokes `early_z.sv`, and conditionally writes back updated Z values and color pixels.
  This test exercises the integrated pipeline including arbiter port 2 ownership by UNIT-006.
- **The golden image requires re-approval after pixel pipeline integration.**
  The incremental interpolation redesign (step 1) may shift Z-interpolated values by 1 ULP at some pixels, and the transfer of Z-buffer write ownership from the rasterizer to the pixel pipeline (step 2) changes the timing of Z-buffer updates.
  After integration, re-run the test, visually inspect the output, and re-commit the golden image.
- The background of the framebuffer (pixels outside both triangles) will contain whatever the SDRAM model initializes to (typically zero/black).
  The golden image includes the full 512×512 framebuffer surface, so the background color is part of the pixel-exact comparison.
- The golden image must also be regenerated and re-approved whenever the rasterizer tiled address stride changes (e.g. after wiring `fb_width_log2` to replace a hardcoded constant).
  See `test_strategy.md` for the re-approval workflow.
