# VER-012: Textured Triangle Golden Image Test

## Verification Method

**Test:** Verified by executing a Verilator golden image simulation that renders a textured triangle through the full GPU RTL hierarchy -- including the texture cache, texture decoder, and behavioral SDRAM model implementing the INT-032 cache miss handling protocol -- and compares the output pixel-exactly against an approved golden image.
The test confirms that UV coordinates are perspective-correct interpolated, the texture cache correctly fetches and decompresses texture data from SDRAM on cache miss, and the final rendered pixels match the expected checker pattern on the triangle surface.

## Verifies Requirements

- REQ-003.01 (Textured Triangle)

## Verified Design Units

- UNIT-003 (Register File -- TEX0_BASE, TEX0_FMT, UV0_UV1 register writes)
- UNIT-005 (Rasterizer -- UV interpolation across triangle surface)
- UNIT-006 (Pixel Pipeline -- texture cache lookup, cache miss fill FSM, texture decoder, RGBA5652 promotion)

## Preconditions

- Integration simulation harness (`spi_gpu/tests/harness/`) compiles successfully under Verilator, with a behavioral SDRAM model that correctly implements the INT-032 Cache Miss Handling Protocol (IDLE -> FETCH -> DECOMPRESS -> WRITE_BANKS -> IDLE FSM, with format-dependent burst lengths).
- A known test texture (16x16 RGB565 checker pattern) is generated programmatically by the harness and pre-loaded into the behavioral SDRAM model at the address specified in TEX0_BASE.
  Per `test_strategy.md`, large binary assets (textures for VER-012) are generated programmatically by the test harness and are not committed.
- Golden image `spi_gpu/tests/golden/textured_triangle.ppm` has been approved and committed.
  This image must be re-approved after the pixel pipeline integration (UNIT-006 stub becomes functional) and after the `tex_format` field widening to 3 bits (step 5 of the pixel pipeline integration change), because the format-select mux path changes even for RGB565.
- Verilator 5.x is installed and available on `$PATH`.
- All RTL sources in the rendering pipeline (`register_file.sv`, `rasterizer.sv`, `pixel_pipeline.sv`, `texture_cache.sv`, `texture_rgb565.sv`) compile without errors under `verilator --lint-only -Wall`.
- `pixel_pipeline.sv` is the fully integrated module (not a stub): it instantiates the texture cache, format-select mux connecting all six decoders, color combiner, and FB/Z write logic per UNIT-006.

## Procedure

### Test Texture

The harness generates a 16x16 RGB565 checker pattern programmatically (no file commit required per `test_strategy.md`):

- **Dimensions:** 16x16 pixels (WIDTH_LOG2=4, HEIGHT_LOG2=4).
- **Format:** RGB565 (FORMAT=4, uncompressed).
- **Pattern:** 4x4 block checker.
  Even blocks (where `(block_x + block_y) % 2 == 0`) are white (`0xFFFF`); odd blocks are black (`0x0000`).
  This yields a visually distinctive pattern that makes UV mapping errors immediately visible.
- **Layout:** Stored in SDRAM using the 4x4 block-tiled layout defined in INT-014.
- **Base address:** A known aligned address (e.g., `0x00040000`) written to TEX0_BASE.

### Test Scene

The test renders a single textured triangle with three vertices at known screen coordinates.
Each vertex has UV coordinates that map to specific regions of the 16x16 checker texture.

| Vertex | Screen Position (12.4 fixed) | UV Coordinates (U, V) | Description |
|--------|------------------------------|-----------------------|-------------|
| V0 | (320, 60) | (0.5, 0.0) | Top center |
| V1 | (100, 380) | (0.0, 1.0) | Bottom left |
| V2 | (540, 380) | (1.0, 1.0) | Bottom right |

The triangle covers a large sub-region of the 640x480 framebuffer.
The UV coordinates span the full [0,1] range of the texture, ensuring the entire checker pattern is visible on the triangle surface.

### Harness Command Sequence

The integration harness drives the following register-write sequence into UNIT-003 (Register File):

1. **Load test texture into behavioral SDRAM model:**
   Generate the 16x16 RGB565 checker pattern and write it into the SDRAM model at the chosen base address using the 4x4 block-tiled layout (INT-014).

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

3. **Configure render mode:**
   Write `RENDER_MODE` (address `0x30`) with:
   - `GOURAUD_EN = 0` (bit 0, flat shading)
   - `Z_TEST_EN = 0` (bit 2, no depth test)
   - `Z_WRITE_EN = 0` (bit 3, no depth write)
   - `COLOR_WRITE_EN = 1` (bit 4)
   - `TEX0_EN` via TEX0_FMT (texture unit 0 enabled above)
   - All other mode bits = 0 (no dithering, no alpha blend, no stipple, no culling)

4. **Configure framebuffer:**
   Write `FB_CONFIG` (address `0x40`) with:
   - `fb_color_base` = chosen color buffer base address (SDRAM-aligned).
   - `fb_width_log2 = 9` (surface width = 512 pixels).
   - `fb_height_log2 = 9` (surface height = 512 pixels).
   The harness framebuffer readback in step 9 must use `WIDTH_LOG2 = 9` for the block-tiled address calculation (INT-011).

5. **Submit vertex 0:**
   - Write `COLOR` (address `0x00`) with `0x000000FF_FFFFFFFF` (COLOR1=black, COLOR0=white opaque -- modulated with texture).
   - Write `UV0_UV1` (address `0x01`) with UV0 = (0.5, 0.0) packed per register format.
   - Write `VERTEX_NOKICK` (address `0x06`) with V0 position (X=320, Y=60, Z=`0x0000`).

6. **Submit vertex 1:**
   - Write `COLOR` (address `0x00`) with `0x000000FF_FFFFFFFF` (COLOR1=black, COLOR0=white opaque).
   - Write `UV0_UV1` (address `0x01`) with UV0 = (0.0, 1.0).
   - Write `VERTEX_NOKICK` (address `0x06`) with V1 position (X=100, Y=380, Z=`0x0000`).

7. **Submit vertex 2 (with kick):**
   - Write `COLOR` (address `0x00`) with `0x000000FF_FFFFFFFF` (COLOR1=black, COLOR0=white opaque).
   - Write `UV0_UV1` (address `0x01`) with UV0 = (1.0, 1.0).
   - Write `VERTEX_KICK_012` (address `0x07`) with V2 position (X=540, Y=380, Z=`0x0000`).

8. **Wait for completion:**
   Run the simulation until the `frag_done` signal (or equivalent pipeline-idle indicator) asserts, indicating all fragments have been processed and written to the behavioral SDRAM model.

9. **Read back framebuffer:**
   The harness reads the simulated framebuffer contents from the behavioral SDRAM model using the 4x4 block-tiled address layout per INT-011, with `WIDTH_LOG2 = 9` matching the `fb_width_log2` written in step 4.
   The pixel data is serialized as a PPM file at `spi_gpu/tests/sim_out/textured_triangle.ppm`.

10. **Pixel-exact comparison:**
    Compare the simulation output against the approved golden image:
    ```
    diff -q spi_gpu/tests/sim_out/textured_triangle.ppm spi_gpu/tests/golden/textured_triangle.ppm
    ```

11. **SDRAM burst length assertion:**
    Verify that during texture cache miss fills, the SDRAM burst length issued by the cache fill FSM matches the INT-032 specification for RGB565 format: `burst_len=16` (32 bytes for 16 x 16-bit pixels in a 4x4 block).
    The harness should log or assert on every burst read request, confirming the burst length field equals 16.

## Expected Results

- **Pass Criteria:** Pixel-exact match between the simulation output (`spi_gpu/tests/sim_out/textured_triangle.ppm`) and the approved golden image (`spi_gpu/tests/golden/textured_triangle.ppm`).
  The rendered image shows a triangle with the 16x16 checker pattern mapped onto its surface via perspective-correct UV interpolation.
  The checker pattern should appear uniform and undistorted -- no affine warping artifacts should be visible (straight checker lines remain straight across the triangle).
  SDRAM burst requests during cache misses use `burst_len=16` for RGB565 format, matching INT-032.

- **Fail Criteria:** Any pixel differs between the simulation output and the approved golden image.
  Common failure modes include:
  - Texture appears as solid color (indicating cache miss was not handled, or texture was not loaded into SDRAM model).
  - Checker pattern is distorted or warped (indicating affine rather than perspective-correct UV interpolation).
  - Incorrect texel colors (indicating RGB565 decoder error or RGBA5652 promotion error).
  - Cache fill FSM issues incorrect burst length (not `burst_len=16` for RGB565).
  - Texture appears shifted or mirrored (indicating incorrect UV wrapping or 4x4 block addressing).
  - Background bleeds into texture (indicating incorrect cache tag matching or set indexing).

## Test Implementation

- `spi_gpu/tests/harness/`: Integration simulation harness.
  Instantiates the full GPU RTL hierarchy under Verilator, provides a behavioral SDRAM model implementing the INT-032 cache miss fill FSM (IDLE -> FETCH -> DECOMPRESS -> WRITE_BANKS -> IDLE), drives register-write command sequences, and reads back the framebuffer as PPM files.
- `spi_gpu/tests/golden/textured_triangle.ppm`: Approved golden image (created after the initial simulation run is visually inspected and approved).

## Notes

- **INT-032 Cache Miss Handling Protocol:** The behavioral SDRAM model must faithfully implement the cache miss fill FSM defined in INT-032.
  For RGB565 format, the burst length is 16 (32 bytes = 16 x 16-bit uncompressed texels in a 4x4 block).
  The fill FSM transitions through IDLE -> FETCH -> DECOMPRESS -> WRITE_BANKS -> IDLE.
  Burst lengths for other formats are documented in INT-032: BC1/BC4=4, BC2/BC3/R8=8, RGB565=16, RGBA8888=32.
- **tex_format 3-bit field:** After the pixel pipeline integration, the FORMAT field in TEXn_FMT is 3 bits wide (bits [4:2]), supporting all seven texture formats (BC1=0 through R8=6) as defined in INT-032.
  The RGB565 encoding (FORMAT=4) is unchanged in value; only the field width changes from 2 bits to 3 bits.
  The format-select mux in the integrated pixel pipeline connects all six format decoders; RGB565 continues to be decoded by `texture_rgb565.sv`.
- **test_strategy.md:** Per the Test Data Management section, the test texture is generated programmatically by the harness and is not committed as a binary asset.
  See the Golden Image Approval Testing section for the approval workflow.
- **Makefile target:** Run this test with: `cd spi_gpu && make test-textured`.
- **Perspective-correct UV:** The UV coordinates are interpolated using perspective-correct interpolation (U/W, V/W, 1/W).
  With the checker pattern, any affine warping would be visible as curved checker lines -- the test implicitly verifies perspective correctness by requiring pixel-exact match with the golden image.
- **Vertex color modulation:** All vertex colors are set to white (`0xFFFFFFFF`) so the MODULATE combiner mode produces `texture_color x 1.0 = texture_color`.
  This isolates texture sampling correctness from color blending behavior.
- **Dithering:** Dithering is disabled (`DITHER_EN=0`) for this test to ensure deterministic, fully reproducible output.
- **VER-012 together with VER-005** (Texture Decoder Unit Testbench) jointly satisfies REQ-003.01 per the requirement document's Verification Method section.
  VER-005 verifies individual format decoders at the unit level; VER-012 verifies the full texture sampling path through the integrated pipeline.
- The background of the framebuffer (pixels outside the triangle) will contain whatever the SDRAM model initializes to (typically zero/black).
  The golden image includes the full 512×512 framebuffer surface, so the background color is part of the pixel-exact comparison.
- The golden image must be regenerated and re-approved whenever the rasterizer tiled address stride changes (e.g. after wiring `fb_width_log2` to replace a hardcoded constant), after the incremental interpolation redesign (UNIT-005 step 1 of the pixel pipeline integration change), or after any change to the format-select mux path in UNIT-006.
  See `test_strategy.md` for the re-approval workflow.
