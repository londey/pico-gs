# VER-012: Textured Triangle Golden Image Test

## Verification Method

**Test:** Verified by executing a Verilator golden image simulation that renders a textured triangle through the full GPU RTL hierarchy — including the INDEXED8_2X2 index cache (UNIT-011.03), palette LUT (UNIT-011.06), and behavioral SDRAM model implementing the UNIT-011 index-cache miss fill FSM and palette load FSM — and compares the output pixel-exactly against an approved golden image.
The test confirms that UV coordinates are perspective-correct interpolated, the quadrant `{v[0], u[0]}` selects the correct palette sub-entry, the index cache correctly fetches index blocks from SDRAM on miss, and the final rendered pixels match the expected checker pattern on the triangle surface.

> **Golden image re-approval required.** The current golden image predates the INDEXED8_2X2 texture architecture (PR2).
> After PR2 RTL implementation lands, re-run this test, visually inspect the output, and re-approve the golden image before marking this test as passing.

## Verifies Requirements

- REQ-003.01 (Textured Triangle)
- REQ-003.09 (Palette Slots)

## Verified Design Units

- UNIT-003 (Register File — TEX0_CFG, PALETTE0 register writes)
- UNIT-005 (Rasterizer — UV interpolation across triangle surface)
- UNIT-006 (Pixel Pipeline — pipeline orchestration, fragment dispatch)
- UNIT-011 (Texture Sampler — index cache lookup, cache miss fill FSM, palette LUT lookup, UQ1.8→Q4.12 promotion)
- UNIT-011.01 (UV Coordinate Processing — quadrant extraction, index-resolution coordinate output)
- UNIT-011.03 (Index Cache — direct-mapped 8-bit index storage, 32-set × 16 indices/line)
- UNIT-011.06 (Palette LUT — 2-slot shared palette, SDRAM load FSM, UNORM8→UQ1.8 promotion)

## Preconditions

- Integration simulation harness (`rtl/tb/`) compiles successfully under Verilator, with a behavioral SDRAM model that correctly implements:
  - Index-cache miss fill FSM: IDLE → FETCH → WRITE_INDEX → IDLE, burst_len=8 (8 words × 2 bytes = 16 bytes for a 4×4 8-bit index block).
  - Palette load FSM: IDLE → PALETTE_LOAD → IDLE, up to 32-word bursts, covering the full 4096-byte palette payload (256 entries × 4 RGBA8888 colors).
- Palette slot 0 is pre-loaded by the test command sequence before any draw calls (see step 1 below).
- A known test texture (16×16 INDEXED8_2X2 checker pattern, index array + palette) is generated programmatically by the harness and pre-loaded into the behavioral SDRAM model.
  Per `test_strategy.md`, large binary assets are generated programmatically and are not committed.
- Golden image `integration/golden/ver_012_textured_triangle.png` has been approved and committed.
  The current golden image was generated with RGB565 format and is expected to fail after PR2 RTL implementation.
  Re-approval is required after PR2 lands.
- `pixel_pipeline.sv` is the fully integrated module (not a stub): it instantiates UNIT-011 (Texture Sampler) for index cache lookup and palette LUT lookup, along with color combiner and FB/Z write logic per UNIT-006.

## Procedure

### Test Texture

The harness generates a 16×16 INDEXED8_2X2 checker pattern programmatically (no file commit required per `test_strategy.md`):

- **Apparent dimensions:** 16×16 texels (WIDTH_LOG2=4, HEIGHT_LOG2=4).
- **Index array dimensions:** 8×8 index entries (each index covers a 2×2 apparent-texel tile).
  Stored as a 4×4 block-tiled index array in SDRAM per INT-014.
- **Format:** INDEXED8_2X2 (FORMAT=4'd0, per INT-010).
- **Pattern:** 4×4 apparent-texel block checker.
  Even apparent-texel blocks have all sub-entries (NW/NE/SW/SE) set to white (RGBA=0xFFFFFFFF); odd apparent-texel blocks are black (RGBA=0x000000FF).
  The corresponding 8-bit indices in the index array point to the matching white or black palette entries.
- **Palette:** Slot 0 contains two entries at minimum — index 0=white (RGBA8888=0xFFFFFFFF) with all four quadrant colors identical, and index 1=black (RGBA8888=0x000000FF) with all four quadrant colors identical.
  The remaining 254 palette entries are set to a known default (e.g., mid-gray).
  Palette is stored as a 4096-byte SDRAM payload at a known aligned address.
- **Base addresses:**
  - Index array: a known aligned address (e.g., `0x00040000`) written to TEX0_CFG BASE_ADDR.
  - Palette slot 0: a known aligned address (e.g., `0x00050000`) written to PALETTE0 BASE_ADDR.

### Test Scene

The test renders a single textured triangle with three vertices at known screen coordinates.
Each vertex has UV coordinates that map to specific regions of the 16×16 apparent checker texture.

| Vertex | Screen Position (Q12.4) | UV Coordinates (U, V) — Q4.12 on fragment bus | Description |
| --- | --- | --- | --- |
| V0 | (320, 60) | (0.5, 0.0) | Top center |
| V1 | (100, 380) | (0.0, 1.0) | Bottom left |
| V2 | (540, 380) | (1.0, 1.0) | Bottom right |

The triangle covers a large sub-region of the 640×480 framebuffer.
The UV coordinates span the full [0, 1] range of the apparent texture, ensuring the entire checker pattern is visible on the triangle surface.

### Harness Command Sequence

The integration harness drives the following register-write sequence into UNIT-003 (Register File):

1. **Load palette slot 0 and index array into behavioral SDRAM model:**
   Write the 4096-byte palette payload into the SDRAM model at the palette base address.
   Write the 8×8 index array (block-tiled per INT-014) into the SDRAM model at the texture base address.
   Write `PALETTE0` (address `0x12`) with:
   - `BASE_ADDR[15:0]` = palette slot 0 base address (×512 byte granularity).
   - `LOAD_TRIGGER[16:16] = 1` (self-clearing; triggers palette load FSM in UNIT-011).
   Wait for the palette load FSM to complete (SDRAM model signals completion after 4096-byte burst).

2. **Configure texture unit 0:**
   Write `TEX0_CFG` (address `0x10`) with:
   - `ENABLE = 1` (bit 0)
   - `FORMAT = INDEXED8_2X2` (4'd0, bits [7:4])
   - `FILTER = NEAREST` (2'd0, bits [9:8])
   - `WIDTH_LOG2 = 4` (bits [13:10], apparent texture width = 16)
   - `HEIGHT_LOG2 = 4` (bits [17:14], apparent texture height = 16)
   - `PALETTE_IDX = 0` (bit [24], selects palette slot 0)
   - `WRAP_U = REPEAT`, `WRAP_V = REPEAT`

3. **Configure render mode:**
   Write `RENDER_MODE` (address `0x30`) with:
   - `GOURAUD_EN = 0` (bit 0, flat shading)
   - `Z_TEST_EN = 0` (bit 2, no depth test)
   - `Z_WRITE_EN = 0` (bit 3, no depth write)
   - `COLOR_WRITE_EN = 1` (bit 4)
   - All other mode bits = 0 (no dithering, no alpha blend, no stipple, no culling)

4. **Configure framebuffer:**
   Write `FB_CONFIG` (address `0x40`) with:
   - `fb_color_base` = chosen color buffer base address (SDRAM-aligned).
   - `fb_width_log2 = 9` (surface width = 512 pixels).
   - `fb_height_log2 = 9` (surface height = 512 pixels).

5. **Submit vertex 0:**
   - Write `COLOR` (address `0x00`) with `0x000000FF_FFFFFFFF` (COLOR1=black, COLOR0=white opaque).
   - Write `ST0_ST1` (address `0x01`) with UV0 = (0.5, 0.0) packed per register format.
   - Write `VERTEX_NOKICK` (address `0x06`) with V0 position (X=320, Y=60, Z=`0x0000`).

6. **Submit vertex 1:**
   - Write `COLOR` (address `0x00`) with `0x000000FF_FFFFFFFF`.
   - Write `ST0_ST1` (address `0x01`) with UV0 = (0.0, 1.0).
   - Write `VERTEX_NOKICK` (address `0x06`) with V1 position (X=100, Y=380, Z=`0x0000`).

7. **Submit vertex 2 (with kick):**
   - Write `COLOR` (address `0x00`) with `0x000000FF_FFFFFFFF`.
   - Write `ST0_ST1` (address `0x01`) with UV0 = (1.0, 1.0).
   - Write `VERTEX_KICK_012` (address `0x07`) with V2 position (X=540, Y=380, Z=`0x0000`).

8. **Wait for completion:**
   Run the simulation until the pipeline-idle indicator asserts, indicating all fragments have been processed and written to the behavioral SDRAM model.

9. **Read back framebuffer:**
   The harness reads the simulated framebuffer contents from the behavioral SDRAM model using the 4×4 block-tiled address layout per INT-011, with `WIDTH_LOG2 = 9` matching the `fb_width_log2` written in step 4.
   The pixel data is serialized as a PNG file at `integration/sim_out/ver_012_textured_triangle.png`.

10. **Pixel-exact comparison:**
    Compare the simulation output against the approved golden image:

    ```sh
    diff -q integration/sim_out/ver_012_textured_triangle.png integration/golden/ver_012_textured_triangle.png
    ```

11. **SDRAM burst length assertion:**
    Verify that during index-cache miss fills, the SDRAM burst length issued by the cache fill FSM equals 8 (8 words × 2 bytes = 16 bytes for a 4×4 8-bit index block), matching UNIT-011.03.

## Expected Results

- **Pass Criteria:** Pixel-exact match between the simulation output and the approved golden image.
  The rendered image shows a triangle with the 16×16 apparent checker pattern mapped onto its surface via perspective-correct UV interpolation.
  The checker pattern should appear uniform and undistorted — no affine warping artifacts should be visible.
  SDRAM burst requests during index-cache misses use `burst_len=8`, matching UNIT-011.03.
  The palette load step completes before the first draw call.

## Test Implementation

- `rtl/tb/`: Integration simulation harness.
  Instantiates the full GPU RTL hierarchy under Verilator, provides a behavioral SDRAM model implementing both the UNIT-011 index-cache miss fill FSM and the palette load FSM, drives register-write command sequences, and reads back the framebuffer as PNG files.
- `integration/golden/ver_012_textured_triangle.png`: Approved golden image (must be regenerated and re-approved after PR2 RTL implementation).

## Notes

- **UNIT-011 Index-Cache Miss Fill Protocol:** The behavioral SDRAM model must implement the index-cache fill FSM (IDLE → FETCH → WRITE_INDEX → IDLE).
  Burst length is 8 words (16 bytes for 16 × 8-bit index values in a 4×4 apparent-texel block at half resolution).
- **UNIT-011 Palette Load Protocol:** The behavioral SDRAM model must implement the palette load FSM (IDLE → PALETTE_LOAD → IDLE).
  The full 4096-byte palette payload requires approximately 128 sequential 32-word bursts.
- **Palette slot must be loaded before first draw call.** Firmware (and the test command sequence) must issue the PALETTE0 LOAD_TRIGGER write and wait for the load to complete before any texture sampling occurs.
  There is no hardware fault for sampling from an unloaded slot.
- **tex_format 4-bit field:** FORMAT=4'd0 encodes INDEXED8_2X2.
  Values 4'd1–4'd15 are reserved.
  The 4-bit field width is retained for ABI stability per INT-010.
- **test_strategy.md:** Per the Test Data Management section, the test texture is generated programmatically by the harness and is not committed as a binary asset.
  See the Golden Image Approval Testing section for the approval workflow.
- **Makefile target:** Run this test with: `cd integration && make test-textured`.
- **Perspective-correct UV:** UV coordinates are perspective-correct (U/W, V/W divisions are performed inside the rasterizer per UNIT-005.05).
  `frag_uv0` and `frag_uv1` carry fully corrected U,V values in Q4.12; UNIT-011 uses them directly for index cache lookup and quadrant extraction without further division.
- **Vertex color modulation:** All vertex colors are set to white so the MODULATE combiner produces `texture_color × 1.0 = texture_color`, isolating texture sampling correctness from color blending.
- **Dithering:** Dithering is disabled (`DITHER_EN=0`) for deterministic, reproducible output.
- **VER-012 together with VER-005** (Texture Palette LUT Unit Testbench) jointly satisfies REQ-003.01 per the requirement document's Verification Method section.
  VER-005 verifies the palette LUT and index cache in isolation; VER-012 verifies the full texture sampling path through the integrated pipeline.
- The golden image must be regenerated and re-approved after: PR2 RTL implementation (INDEXED8_2X2 format replaces RGB565); rasterizer tiled address stride changes; perspective-correct interpolation changes in UNIT-005; any change to the palette LUT addressing or UNORM8→UQ1.8 promotion in UNIT-011.06.
  See `test_strategy.md` for the re-approval workflow.
