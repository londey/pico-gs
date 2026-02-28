# VER-014: Textured Cube Golden Image Test

## Verification Method

**Test:** Verified by executing a Verilator golden image simulation that renders a perspective-projected textured cube (twelve triangles forming six faces) through the full GPU RTL hierarchy and compares the output pixel-exactly against an approved golden image.
The test confirms that perspective-correct UV interpolation, early Z-testing across overlapping geometry, texture cache fill across multiple spatial access patterns, and the MODULATE color combiner all operate correctly when the pipeline handles a multi-triangle 3D scene.

## Verifies Requirements

- REQ-003.01 (Textured Triangle — perspective-correct UV interpolation across all cube faces)
- REQ-005.02 (Depth Tested Triangle — Z-buffer occludes back faces and rear portions of cube geometry)

## Verified Design Units

- UNIT-003 (Register File — TEX0_BASE, TEX0_FMT, FB_CONFIG, FB_ZBUFFER, RENDER_MODE register writes)
- UNIT-004 (Triangle Setup — edge function setup for twelve triangles with varying orientations)
- UNIT-005 (Rasterizer — perspective-correct UV interpolation across faces with varying depth and projection angle)
- UNIT-006 (Pixel Pipeline — early Z-test, texture cache lookup across multiple cache fill patterns, texture decoder, RGBA5652 promotion, MODULATE combiner)

## Preconditions

- Integration simulation harness (`spi_gpu/tests/harness/`) compiles successfully under Verilator, with a behavioral SDRAM model that correctly implements the INT-032 Cache Miss Handling Protocol (IDLE → FETCH → DECOMPRESS → WRITE_BANKS → IDLE FSM, with format-dependent burst lengths).
- A known test texture (16×16 RGB565 checker pattern) is generated programmatically by the harness and pre-loaded into the behavioral SDRAM model at the address specified in TEX0_BASE.
  Per `test_strategy.md`, large binary assets are generated programmatically by the test harness and are not committed.
- Golden image `spi_gpu/tests/golden/textured_cube.ppm` has been approved and committed.
  This image must be re-approved after the pixel pipeline integration, after the incremental interpolation redesign (UNIT-005), and after the `tex_format` field widening to 3 bits (INT-010), because UV interpolation, format-select mux path, and COMBINE_MODE are all functionally active for the first time.
- Verilator 5.x is installed and available on `$PATH`.
- All RTL sources in the rendering pipeline (`register_file.sv`, `triangle_setup.sv`, `rasterizer.sv`, `pixel_pipeline.sv`, `texture_cache.sv`, `texture_rgb565.sv`, `early_z.sv`) compile without errors under `verilator --lint-only -Wall`.
- `pixel_pipeline.sv` is the fully integrated module (not a stub): it instantiates the early Z stage, texture cache, format-select mux connecting all six decoders, MODULATE combiner (UNIT-010), and FB/Z write logic per UNIT-006.
- UNIT-010 (Color Combiner) has reached Stable status (WIP flag removed from `doc/design/unit_010_color_combiner.md`).
- The Z-buffer is initialized to `0xFFFF` via a Z-buffer clear pass before rendering (see Z-Buffer Clear Step below).

## Procedure

### Test Texture

The harness generates a 16×16 RGB565 checker pattern programmatically (no file commit required per `test_strategy.md`):

- **Dimensions:** 16×16 pixels (WIDTH_LOG2=4, HEIGHT_LOG2=4).
- **Format:** RGB565 (FORMAT=4, uncompressed).
- **Pattern:** 4×4 block checker.
  Even blocks (where `(block_x + block_y) % 2 == 0`) are white (`0xFFFF`); odd blocks are black (`0x0000`).
  This yields a visually distinctive pattern that makes UV mapping errors and perspective-correct interpolation failures immediately visible.
- **Layout:** Stored in SDRAM using the 4×4 block-tiled layout defined in INT-014.
- **Base address:** A known aligned address (e.g., `0x00040000`) written to TEX0_BASE.

### Test Scene

The test renders a unit cube centered at the origin, projected under perspective onto the 512×512 framebuffer.
The cube is defined by eight vertices at ±0.5 on each axis; the camera is placed at (0, 0, 3) looking toward the origin with a 60° vertical field of view.
After perspective division and viewport mapping (to a 512×512 surface), each cube face is decomposed into two triangles.
Only the three front-facing faces (positive-X, positive-Y, positive-Z) are expected to be visible; the three back-facing faces are occluded by Z-testing.

The twelve triangles (two per face) are submitted in painter's-order by approximate depth: back faces first, front faces last.
Z values for all vertices are derived from the perspective-projected clip-space W coordinate (depth range [0, 1], mapped to UQ16 as specified in INT-011).
UV coordinates at each vertex map the full [0, 1] range of the checker texture onto each face independently, so the checker pattern appears once per face.

The table below lists one representative triangle per face (the other triangle of each face shares two vertices):

| Face | Vertex | Screen X | Screen Y | Z (UQ16) | U    | V    | Description                       |
|------|--------|----------|----------|----------|------|------|-----------------------------------|
| +Z (front) | T0-V0 | 128 | 128 | 0x3800 | 0.0 | 0.0 | Top-left                         |
| +Z (front) | T0-V1 | 384 | 128 | 0x3800 | 1.0 | 0.0 | Top-right                        |
| +Z (front) | T0-V2 | 128 | 384 | 0x3800 | 0.0 | 1.0 | Bottom-left                      |
| +X (right) | T2-V0 | 384 | 128 | 0x3800 | 0.0 | 0.0 | Top-left of face                 |
| +X (right) | T2-V1 | 448 | 192 | 0x4800 | 1.0 | 0.0 | Top-right (receding into depth)  |
| +X (right) | T2-V2 | 384 | 384 | 0x3800 | 0.0 | 1.0 | Bottom-left of face              |
| +Y (top)   | T4-V0 | 128 | 128 | 0x3800 | 0.0 | 0.0 | Top-left of face                 |
| +Y (top)   | T4-V1 | 384 | 128 | 0x3800 | 1.0 | 0.0 | Top-right of face                |
| +Y (top)   | T4-V2 | 192 |  64 | 0x4800 | 0.5 | 1.0 | Apex (receding into depth)       |

Exact screen coordinates and Z values used in the committed harness source are the authoritative reference; the table above is illustrative.
Vertex positions are provided to VERTEX_NOKICK / VERTEX_KICK_012 / VERTEX_KICK_021 in all-integer Q12.4 fixed-point format (subpixel precision).

Vertex colors for all vertices are set to white (`0xFFFFFFFF`, COLOR0; COLOR1=black `0x000000FF`) so the MODULATE combiner produces texture color × 1.0, isolating texture sampling correctness from color arithmetic.

### Z-Buffer Clear Step

Before rendering the cube, the Z-buffer must be initialized to the maximum depth value (`0xFFFF`):

1. Write `RENDER_MODE` (address `0x30`) with:
   - `Z_TEST_EN = 1` (bit 2)
   - `Z_WRITE_EN = 1` (bit 3)
   - `Z_COMPARE = ALWAYS` (3'd6)
   - `COLOR_WRITE_EN = 0` (bit 4 = 0, no color writes during clear)
2. Render a screen-filling pair of triangles with Z = `0xFFFF` at all vertices (covering the full 512×512 surface).
3. Wait for the clear pass to complete (pipeline idle).

This matches the Z-buffer clear pattern established in VER-011.

### Harness Command Sequence

The integration harness drives the following register-write sequence into UNIT-003 (Register File):

1. **Load test texture into behavioral SDRAM model:**
   Generate the 16×16 RGB565 checker pattern and write it into the SDRAM model at the chosen base address using the 4×4 block-tiled layout (INT-014).

2. **Configure texture unit 0:**
   - Write `TEX0_BASE` (address `0x10`) with the texture base address (e.g., `0x00040000`, 4K aligned).
   - Write `TEX0_FMT` (address `0x11`) with:
     - `ENABLE = 1` (bit 0)
     - `FORMAT = RGB565` (4 << 2, bits [4:2]; 3-bit field per INT-010 post-integration)
     - `WIDTH_LOG2 = 4` (4 << 8, bits [11:8])
     - `HEIGHT_LOG2 = 4` (4 << 12, bits [15:12])
     - `SWIZZLE = 0` (identity, bits [19:16])
     - `FILTER = NEAREST` (0, bits [7:6])
     - `MIP_LEVELS = 1` (1 << 20, bits [23:20])

3. **Z-buffer clear pass** (see Z-Buffer Clear Step above).

4. **Configure render mode for depth-tested textured rendering:**
   Write `RENDER_MODE` (address `0x30`) with:
   - `GOURAUD_EN = 1` (bit 0; vertex colors are uniform white so Gouraud produces identical output to flat shading)
   - `Z_TEST_EN = 1` (bit 2)
   - `Z_WRITE_EN = 1` (bit 3)
   - `COLOR_WRITE_EN = 1` (bit 4)
   - `Z_COMPARE = LEQUAL` (default comparison function)
   - `TEX0_EN` via TEX0_FMT (texture unit 0 enabled above)
   - `COMBINE_MODE = MODULATE` (TEX0 × SHADE0; this field is functionally active after pixel pipeline integration)
   - All other mode bits = 0 (no dithering, no alpha blend, no stipple, no culling)

5. **Configure framebuffer and Z-buffer:**
   Write `FB_CONFIG` (address `0x40`) with:
   - `fb_color_base` = chosen color buffer base address (SDRAM-aligned, disjoint from texture and Z-buffer regions).
   - `fb_width_log2 = 9` (surface width = 512 pixels).
   - `fb_height_log2 = 9` (surface height = 512 pixels).
   Write `FB_ZBUFFER` with the Z-buffer base address (separate region per INT-011).
   The harness framebuffer readback uses `WIDTH_LOG2 = 9` for the block-tiled address calculation (INT-011).

6. **Submit cube triangles:**
   For each of the twelve triangles, in depth order (back faces first):
   - For vertex 0 and vertex 1: write `COLOR`, `UV0_UV1`, `VERTEX_NOKICK`.
   - For vertex 2: write `COLOR`, `UV0_UV1`, then `VERTEX_KICK_012` (or `VERTEX_KICK_021` for faces with opposite winding).
   Back-face triangles are submitted first to demonstrate that Z-testing correctly discards their fragments when the front-face triangles are rendered subsequently.

7. **Wait for completion:**
   Run the simulation until the `frag_done` signal (or equivalent pipeline-idle indicator) asserts after the final triangle, indicating all fragments have been processed and written to the behavioral SDRAM model.

8. **Read back framebuffer:**
   The harness reads the simulated framebuffer contents from the behavioral SDRAM model using the 4×4 block-tiled address layout per INT-011, with `WIDTH_LOG2 = 9` matching the `fb_width_log2` written in step 5.
   The pixel data is serialized as a PPM file at `spi_gpu/tests/sim_out/textured_cube.ppm`.

9. **Pixel-exact comparison:**
   Compare the simulation output against the approved golden image:
   ```
   diff -q spi_gpu/tests/sim_out/textured_cube.ppm spi_gpu/tests/golden/textured_cube.ppm
   ```

10. **SDRAM burst length assertion:**
    Verify that during texture cache miss fills, the SDRAM burst length issued by the cache fill FSM equals 16 for RGB565 format (32 bytes for 16 × 16-bit texels in a 4×4 block), matching INT-032.
    The harness logs or asserts on every burst read request, confirming the burst length field equals 16.

## Expected Results

- **Pass Criteria:** Pixel-exact match between the simulation output (`spi_gpu/tests/sim_out/textured_cube.ppm`) and the approved golden image (`spi_gpu/tests/golden/textured_cube.ppm`).
  The rendered image shows the three visible faces of the perspective-projected cube, each displaying the 16×16 checker pattern with visible perspective foreshortening — checker squares appear smaller toward the vanishing point and larger toward the viewer.
  Back faces of the cube are not visible (occluded by Z-testing or outside the viewing frustum).
  SDRAM burst requests during cache misses use `burst_len=16` for RGB565 format, matching INT-032.

- **Fail Criteria:** Any pixel differs between the simulation output and the approved golden image.
  Common failure modes include:
  - Checker pattern appears affinely warped (curved lines), indicating perspective-correct UV interpolation failure.
  - Back faces bleed through front faces in the overlap region, indicating Z-test not functioning.
  - Z-buffer not cleared to `0xFFFF` before rendering, causing the first triangle to fail the depth test.
  - Texture appears as solid color, indicating cache miss not handled or texture not loaded into SDRAM model.
  - Incorrect texel colors, indicating RGB565 decoder error or RGBA5652 promotion error.
  - Cache fill FSM issues incorrect burst length (not `burst_len=16` for RGB565).
  - Texture appears shifted or mirrored, indicating incorrect UV wrapping or 4×4 block addressing error.
  - Seams or discontinuities between the two triangles of a face, indicating triangle-setup edge case at shared edges.

## Test Implementation

- `spi_gpu/tests/harness/`: Integration simulation harness.
  Instantiates the full GPU RTL hierarchy under Verilator, provides a behavioral SDRAM model implementing the INT-032 cache miss fill FSM (IDLE → FETCH → DECOMPRESS → WRITE_BANKS → IDLE), drives register-write command sequences for all twelve cube triangles, and reads back the framebuffer as a PPM file.
- `spi_gpu/tests/golden/textured_cube.ppm`: Approved golden image (created after the initial simulation run is visually inspected and approved).

## Notes

- **Relationship to VER-011:** The Z-buffer clear sequence and depth-tested rendering setup follow the pattern established in VER-011 (depth-tested overlapping flat triangles).
  VER-014 extends that pattern by combining texturing with depth testing in a 3D scene.
  Reviewers should confirm the Z-buffer clear sequence is identical to VER-011's clear pass.
- **Relationship to VER-012:** The texture setup (16×16 RGB565 checker pattern, INT-014 tiled layout, TEX0_BASE/TEX0_FMT register writes, INT-032 cache miss protocol) follows the pattern established in VER-012 (textured triangle).
  VER-014 extends that pattern to a multi-triangle scene with multiple distinct texture cache fill patterns arising from spatially varied UV access across differently oriented faces.
- **Perspective-correct UV:** UV coordinates are interpolated using perspective-correct interpolation (U/W, V/W, 1/W) as specified in UNIT-005.
  The checker pattern on a perspective-projected cube face exhibits clear foreshortening — this makes affine warping artifacts immediately visible in the golden image comparison.
  VER-012 verifies the same interpolation path on a single flat triangle; VER-014 provides additional coverage under projection angles that produce stronger W variation across the triangle surface.
- **Multiple cache fill patterns:** A single-triangle test (VER-012) accesses texture cache sets in a predictable sweep; a 3D cube with multiple faces at different orientations accesses cache sets in spatially varied patterns.
  This exercises cache tag matching, set indexing, and eviction behavior more thoroughly than VER-012 alone.
- **MODULATE combiner:** All vertex colors are white (`0xFFFFFFFF`), so the MODULATE combiner (`TEX0 × SHADE0`) produces `texture_color × 1.0 = texture_color`.
  This isolates texture sampling correctness from color combiner arithmetic.
- **Winding and back-face submission:** Back-face triangles are submitted first in depth order to validate that depth testing correctly discards their fragments when front-face triangles are rendered subsequently.
  The test does not enable hardware back-face culling — occlusion must be achieved entirely through Z-testing.
- **Dithering:** Dithering is disabled (`DITHER_EN=0`) for deterministic, reproducible output.
- **tex_format 3-bit field:** After the pixel pipeline integration, the FORMAT field in TEXn_FMT is 3 bits wide (bits [4:2]), supporting all seven texture formats (BC1=0 through R8=6) as defined in INT-032.
  The RGB565 encoding (FORMAT=4) is unchanged in value; only the field width changes from 2 bits to 3 bits.
- **Makefile target:** Run this test with: `cd spi_gpu && make test-textured-cube`.
- **Golden image approval:** Per `test_strategy.md`, run the simulation, visually inspect the output PPM, copy it to `spi_gpu/tests/golden/textured_cube.ppm`, and commit.
  The golden image must be regenerated and re-approved whenever the rasterizer tiled address stride changes, the perspective-correct interpolation logic is modified (UNIT-005 incremental interpolation redesign), the format-select mux path in UNIT-006 changes, or the COMBINE_MODE=MODULATE pipeline behavior changes in UNIT-010.
- **VER-014 together with VER-005** (Texture Decoder Unit Testbench) and **VER-012** (Textured Triangle) provide supplementary integration coverage of REQ-003.01.
  VER-014 additionally provides supplementary integration coverage of REQ-005.02 alongside VER-011.
