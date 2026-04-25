# VER-014: Textured Cube Golden Image Test

## Verification Method

**Test:** Verified by executing a Verilator golden image simulation that renders a perspective-projected textured cube (twelve triangles forming six faces) through the full GPU RTL hierarchy and compares the output pixel-exactly against an approved golden image.
The test confirms that perspective-correct UV interpolation, early Z-testing across overlapping geometry, INDEXED8_2X2 index-cache fill across multiple spatial access patterns, and the MODULATE color combiner all operate correctly when the pipeline handles a multi-triangle 3D scene.

> **Golden image re-approval required.** The current golden image predates the INDEXED8_2X2 texture architecture (PR2).
> After PR2 RTL implementation lands, re-run this test, visually inspect the output, and re-approve the golden image before marking this test as passing.

## Verifies Requirements

- REQ-003.01 (Textured Triangle — perspective-correct UV interpolation across all cube faces)
- REQ-003.09 (Palette Slots)
- REQ-005.02 (Depth Tested Triangle — Z-buffer occludes back faces and rear portions of cube geometry)

## Verified Design Units

- UNIT-003 (Register File — TEX0_CFG, PALETTE0, FB_CONFIG, RENDER_MODE register writes)
- UNIT-005.01 (Triangle Setup — edge function setup for twelve triangles with varying orientations)
- UNIT-005 (Rasterizer — perspective-correct UV interpolation across faces with varying depth and projection angle)
- UNIT-006 (Pixel Pipeline — early Z-test, pipeline orchestration, MODULATE combiner)
- UNIT-011 (Texture Sampler — INDEXED8_2X2 index cache lookup across multiple cache fill patterns, palette LUT lookup, UQ1.8→Q4.12 promotion)
- UNIT-011.03 (Index Cache — direct-mapped 8-bit index storage; multiple fill patterns across differently oriented faces)
- UNIT-011.06 (Palette LUT — 2-slot shared palette, SDRAM load FSM)

## Preconditions

- Integration simulation harness (`rtl/tb/`) compiles successfully under Verilator, with a behavioral SDRAM model that correctly implements:
  - Index-cache miss fill FSM: IDLE → FETCH → WRITE_INDEX → IDLE, burst_len=8 (16 bytes per 4×4 8-bit index block).
  - Palette load FSM: IDLE → PALETTE_LOAD → IDLE, multiple 32-word bursts covering 4096 bytes per slot.
- Palette slot 0 is pre-loaded by the test command sequence before any draw calls (see step 1 below).
- A known test texture (16×16 apparent INDEXED8_2X2 checker pattern) is generated programmatically by the harness and pre-loaded into the behavioral SDRAM model.
  Per `test_strategy.md`, large binary assets are generated programmatically and are not committed.
- Golden image `integration/golden/ver_014_textured_cube.png` has been approved and committed.
  The current golden image predates PR2 and is expected to fail after PR2 RTL implementation.
  Re-approval is required after PR2 lands.
- `pixel_pipeline.sv` is the fully integrated module (not a stub): it instantiates the early Z stage, UNIT-011 (Texture Sampler — index cache, palette LUT), MODULATE combiner (UNIT-010), and FB/Z write logic per UNIT-006.
- UNIT-010 (Color Combiner) has reached Stable status (WIP flag removed from `doc/design/unit_010_color_combiner.md`).
- The Z-buffer is initialized to `0xFFFF` via a Z-buffer clear pass before rendering (see Z-Buffer Clear Step below).

## Procedure

### Test Texture

The harness generates a 16×16 apparent INDEXED8_2X2 checker pattern programmatically (no file commit required per `test_strategy.md`):

- **Apparent dimensions:** 16×16 texels (WIDTH_LOG2=4, HEIGHT_LOG2=4).
- **Index array dimensions:** 8×8 index entries (each index covers a 2×2 apparent-texel tile).
  Stored as a 4×4 block-tiled index array in SDRAM per INT-014.
- **Format:** INDEXED8_2X2 (FORMAT=4'd0).
- **Pattern:** 4×4 apparent-texel block checker.
  Even blocks map to palette index 0 (white: RGBA8888=0xFFFFFFFF, all quadrant colors identical); odd blocks map to index 1 (black: RGBA8888=0x000000FF, all quadrant colors identical).
- **Palette slot 0:** index 0=white, index 1=black; remaining 254 entries default to mid-gray.
  Stored as a 4096-byte SDRAM payload at a known aligned address.
- **Base addresses:**
  - Index array: e.g., `0x00040000` written to TEX0_CFG BASE_ADDR.
  - Palette slot 0: e.g., `0x00050000` written to PALETTE0 BASE_ADDR.

### Test Scene

The test renders a unit cube centered at the origin, projected under perspective onto the 512×512 framebuffer.
The cube is defined by eight vertices at ±0.5 on each axis; the camera is placed at (0, 0, 3) looking toward the origin with a 60° vertical field of view.
After perspective division and viewport mapping, each cube face is decomposed into two triangles.
Only the three front-facing faces (positive-X, positive-Y, positive-Z) are expected to be visible; the three back-facing faces are occluded by Z-testing.

The twelve triangles (two per face) are submitted in painter's-order by approximate depth: back faces first, front faces last.
Z values for all vertices are derived from the perspective-projected clip-space W coordinate.
UV coordinates at each vertex map the full [0, 1] range of the apparent checker texture onto each face independently.

The table below lists one representative triangle per face (the other triangle of each face shares two vertices):

| Face | Vertex | Screen X | Screen Y | Z (UQ16) | U | V | Description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| +Z (front) | T0-V0 | 128 | 128 | 0x3800 | 0.0 | 0.0 | Top-left |
| +Z (front) | T0-V1 | 384 | 128 | 0x3800 | 1.0 | 0.0 | Top-right |
| +Z (front) | T0-V2 | 128 | 384 | 0x3800 | 0.0 | 1.0 | Bottom-left |
| +X (right) | T2-V0 | 384 | 128 | 0x3800 | 0.0 | 0.0 | Top-left of face |
| +X (right) | T2-V1 | 448 | 192 | 0x4800 | 1.0 | 0.0 | Top-right (receding) |
| +X (right) | T2-V2 | 384 | 384 | 0x3800 | 0.0 | 1.0 | Bottom-left of face |
| +Y (top) | T4-V0 | 128 | 128 | 0x3800 | 0.0 | 0.0 | Top-left of face |
| +Y (top) | T4-V1 | 384 | 128 | 0x3800 | 1.0 | 0.0 | Top-right of face |
| +Y (top) | T4-V2 | 192 | 64 | 0x4800 | 0.5 | 1.0 | Apex (receding) |

Exact screen coordinates and Z values used in the committed harness source are the authoritative reference; the table above is illustrative.
Vertex colors for all vertices are set to white (`0xFFFFFFFF`, COLOR0; COLOR1=black `0x000000FF`) so the MODULATE combiner produces texture color × 1.0.

### Z-Buffer Clear Step

Before rendering the cube, the Z-buffer must be initialized to the maximum depth value (`0xFFFF`):

1. Write `RENDER_MODE` (address `0x30`) with `Z_TEST_EN=1`, `Z_WRITE_EN=1`, `Z_COMPARE=ALWAYS`, `COLOR_WRITE_EN=0`.
2. Render a screen-filling pair of triangles with Z=`0xFFFF` at all vertices.
3. Wait for the clear pass to complete (pipeline idle).

### Harness Command Sequence

1. **Load palette slot 0 and index array into behavioral SDRAM model:**
   Write the 4096-byte palette payload into the SDRAM model at the palette base address.
   Write the 8×8 index array (block-tiled per INT-014) into the SDRAM model at the texture base address.
   Write `PALETTE0` (address `0x12`) with `BASE_ADDR[15:0]` = palette base and `LOAD_TRIGGER[16:16] = 1`.
   Wait for palette load FSM to complete.

2. **Configure texture unit 0:**
   Write `TEX0_CFG` (address `0x10`) with:
   - `ENABLE = 1` (bit 0)
   - `FORMAT = INDEXED8_2X2` (4'd0, bits [7:4])
   - `FILTER = NEAREST` (2'd0, bits [9:8])
   - `WIDTH_LOG2 = 4` (bits [13:10])
   - `HEIGHT_LOG2 = 4` (bits [17:14])
   - `PALETTE_IDX = 0` (bit [24])
   - `WRAP_U = REPEAT`, `WRAP_V = REPEAT`

3. **Z-buffer clear pass** (see Z-Buffer Clear Step above).

4. **Configure render mode for depth-tested textured rendering:**
   Write `RENDER_MODE` (address `0x30`) with `GOURAUD_EN=1`, `Z_TEST_EN=1`, `Z_WRITE_EN=1`, `COLOR_WRITE_EN=1`, `Z_COMPARE=LEQUAL`, and all other bits = 0.

5. **Configure framebuffer and Z-buffer:**
   Write `FB_CONFIG` (address `0x40`) with `fb_color_base`, `fb_width_log2=9`, `fb_height_log2=9`.
   Write `FB_ZBUFFER` with the Z-buffer base address (separate region per INT-011).

6. **Submit cube triangles:**
   For each of the twelve triangles, in depth order (back faces first):
   - For vertex 0 and vertex 1: write `COLOR`, `ST0_ST1`, `VERTEX_NOKICK`.
   - For vertex 2: write `COLOR`, `ST0_ST1`, then `VERTEX_KICK_012` (or `VERTEX_KICK_021` for faces with opposite winding).

7. **Wait for completion:**
   Run the simulation until the pipeline-idle indicator asserts after the final triangle.

8. **Read back framebuffer:**
   The harness reads the framebuffer from the behavioral SDRAM model using the 4×4 block-tiled layout per INT-011, with `WIDTH_LOG2=9`.
   The pixel data is serialized as a PNG file at `integration/sim_out/ver_014_textured_cube.png`.

9. **Pixel-exact comparison:**

    ```sh
    diff -q integration/sim_out/ver_014_textured_cube.png integration/golden/ver_014_textured_cube.png
    ```

10. **SDRAM burst length assertion:**
    Verify that during index-cache miss fills, the SDRAM burst length equals 8 for INDEXED8_2X2 format (8 words × 2 bytes = 16 bytes for a 4×4 8-bit index block), matching UNIT-011.03.

## Expected Results

- **Pass Criteria:** Pixel-exact match between the simulation output and the approved golden image.
  The rendered image shows the three visible faces of the perspective-projected cube, each displaying the 16×16 apparent checker pattern with visible perspective foreshortening.
  Back faces are not visible (occluded by Z-testing or outside the viewing frustum).
  SDRAM burst requests during index-cache misses use `burst_len=8`, matching UNIT-011.03.

## Test Implementation

- `rtl/tb/`: Integration simulation harness.
  Instantiates the full GPU RTL hierarchy under Verilator, provides a behavioral SDRAM model implementing both the UNIT-011 index-cache miss fill FSM and the palette load FSM, drives register-write command sequences for all twelve cube triangles, and reads back the framebuffer as a PNG file.
- `integration/golden/ver_014_textured_cube.png`: Approved golden image (must be regenerated and re-approved after PR2 RTL implementation).

## Notes

- **Relationship to VER-011:** The Z-buffer clear sequence and depth-tested rendering setup follow the pattern established in VER-011.
  VER-014 extends that pattern by combining texturing with depth testing in a 3D scene.
- **Relationship to VER-012:** The texture setup follows the pattern established in VER-012 (INDEXED8_2X2 checker, palette slot 0 pre-loaded, TEX0_CFG register writes, UNIT-011 cache miss protocol).
  VER-014 extends that pattern to a multi-triangle scene with multiple distinct index-cache fill patterns arising from spatially varied UV access across differently oriented faces.
- **Palette slot must be loaded before first draw call.**
  The PALETTE0 LOAD_TRIGGER write and FSM completion must precede any VERTEX_KICK write.
- **Perspective-correct UV:** UV coordinates are perspective-correct (UNIT-005.05).
  On the fragment bus, `frag_uv0` carries true perspective-correct U,V in Q4.12.
  `frag_q` is not present; `frag_lod` (UQ4.4) is present but not consumed by UNIT-011 (mipmapping dropped).
- **Multiple index-cache fill patterns:** A single-triangle test (VER-012) accesses cache sets in a predictable sweep; the 3D cube with multiple faces at different orientations accesses cache sets in spatially varied patterns, exercising tag matching and set indexing more thoroughly.
- **MODULATE combiner:** All vertex colors are white, so MODULATE produces `texture_color × 1.0 = texture_color`, isolating texture sampling from color combiner arithmetic.
- **Dithering:** Dithering is disabled (`DITHER_EN=0`) for deterministic output.
- **tex_format 4-bit field:** FORMAT=4'd0 encodes INDEXED8_2X2; values 4'd1–4'd15 are reserved.
- **Makefile target:** Run this test with: `cd integration && make test-textured-cube`.
- The golden image must be regenerated and re-approved whenever: PR2 RTL implementation lands; the rasterizer tiled address stride changes; the perspective-correct interpolation logic in UNIT-005 is modified; the derivative precomputation module `raster_deriv.sv` changes; the palette LUT addressing or UNORM8→UQ1.8 promotion in UNIT-011.06 changes; or the COMBINE_MODE=MODULATE pipeline behavior in UNIT-010 changes.
  See `test_strategy.md` for the re-approval workflow.
- **VER-014 together with VER-005** (Texture Palette LUT) and **VER-012** provide supplementary integration coverage of REQ-003.01.
  VER-014 additionally provides supplementary integration coverage of REQ-005.02 alongside VER-011.
