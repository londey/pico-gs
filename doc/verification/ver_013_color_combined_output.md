# VER-013: Color-Combined Output Golden Image Test

## Verification Method

**Test:** Verified by executing a Verilator golden image simulation that renders a textured, vertex-shaded triangle through the full GPU RTL hierarchy — including the INDEXED8_2X2 index cache (UNIT-011.03), palette LUT (UNIT-011.06), color combiner (UNIT-010), and behavioral SDRAM model — and compares the output pixel-exactly against an approved golden image.
The test confirms that the color combiner correctly evaluates the MODULATE equation `TEX0 * SHADE0` in cycle 0, passes the result through cycle 1 unchanged, and produces a final pixel color equal to the per-component product of the sampled palette color and the interpolated vertex color.

> **Golden image re-approval required.** The current golden image predates the INDEXED8_2X2 texture architecture (PR2).
> After PR2 RTL implementation lands, re-run this test, visually inspect the output, and re-approve the golden image before marking this test as passing.

## Verifies Requirements

- REQ-004.01 (Color Combiner)
- REQ-003.09 (Palette Slots)

## Verified Design Units

- UNIT-003 (Register File — CC_MODE, CONST_COLOR, TEX0_CFG, PALETTE0 register writes)
- UNIT-006 (Pixel Pipeline — pipeline orchestration; receives Q4.12 texel data from UNIT-011 and dispatches to color combiner)
- UNIT-010 (Color Combiner — two-stage pipeline)
- UNIT-011 (Texture Sampler — INDEXED8_2X2 index cache lookup, palette LUT lookup, UQ1.8→Q4.12 promotion feeding combiner)

## Preconditions

- UNIT-010 (Color Combiner) has reached Stable status: the WIP flag has been removed from `doc/design/unit_010_color_combiner.md`, indicating that combiner equation pipeline timing and register decoding are finalized.
- `pixel_pipeline.sv` is the fully integrated module (not a stub): it instantiates UNIT-010 (Color Combiner) with live connections to `cc_mode` and `const_color` from the register file, along with UNIT-011 (Texture Sampler) providing Q4.12 texel data, and FB/Z write logic per UNIT-006.
- Integration simulation harness (`rtl/tb/`) compiles successfully under Verilator, with a behavioral SDRAM model that correctly implements:
  - Index-cache miss fill FSM: IDLE → FETCH → WRITE_INDEX → IDLE, burst_len=8.
  - Palette load FSM: IDLE → PALETTE_LOAD → IDLE, multiple 32-word bursts covering 4096 bytes.
- Palette slot 0 is pre-loaded before any draw calls (see step 1 below).
- Golden image `integration/golden/ver_013_color_combined.png` has been approved and committed.
  The current golden image predates PR2 and is expected to fail after PR2 RTL implementation.
  Re-approval is required after PR2 lands.

## Procedure

### Test Scene

The test renders a single triangle that is both textured and vertex-shaded, with the color combiner configured in MODULATE mode.
The MODULATE equation multiplies the sampled palette color by the interpolated vertex color per component, producing a tinted texture output.

**Texture:** A 16×16 INDEXED8_2X2 checker pattern (same apparent dimensions as VER-012), generated programmatically by the harness:

- **Apparent dimensions:** 16×16 texels (WIDTH_LOG2=4, HEIGHT_LOG2=4).
- **Index array dimensions:** 8×8 index entries.
- **Format:** INDEXED8_2X2 (FORMAT=4'd0).
- **Pattern:** 4×4 apparent-texel block checker.
  Even blocks map to palette index 0 (white: RGBA8888=0xFFFFFFFF, all quadrant colors identical); odd blocks map to index 1 (mid-gray: RGBA8888=0x808080FF, approximately 50% intensity, all quadrant colors identical).
  Using white and mid-gray ensures that the MODULATE product is non-zero for all texels, making vertex color tinting visible across the entire triangle.
- **Base addresses:**
  - Index array: a known aligned address (e.g., `0x00040000`) written to TEX0_CFG BASE_ADDR.
  - Palette slot 0: a known aligned address (e.g., `0x00050000`) written to PALETTE0 BASE_ADDR.

**Vertex data:**

| Vertex | Screen Position (Q12.4) | Primary Color (RGBA8888) | UV Coordinates (U, V) — Q4.12 on fragment bus | Description |
| --- | --- | --- | --- | --- |
| V0 | (320, 60) | `0xFF0000FF` (red, opaque) | (0.5, 0.0) | Top center |
| V1 | (100, 380) | `0x00FF00FF` (green, opaque) | (0.0, 1.0) | Bottom left |
| V2 | (540, 380) | `0x0000FFFF` (blue, opaque) | (1.0, 1.0) | Bottom right |

Secondary vertex colors (COLOR1) are set to black (`0x000000FF`) for all three vertices.
The Gouraud-interpolated vertex colors produce a smooth red-green-blue gradient across the triangle surface.
When multiplied by the checker texture via MODULATE, the output is a color-tinted checker pattern: white checker squares show the full vertex gradient, while mid-gray squares show the gradient at approximately half intensity.

### CC_MODE Register Encoding

The color combiner is configured via the CC_MODE register (address `0x18`) for the MODULATE preset.
Per REQ-004.01 FR-009-2 and UNIT-010, the two-stage combiner evaluates `(A - B) * C + D` in each cycle:

**Cycle 0 (MODULATE):**

- A = TEX_COLOR0 (CC_TEX0)
- B = ZERO (CC_ZERO)
- C = SHADE0 (CC_SHADE0)
- D = ZERO (CC_ZERO)
- Equation: `(TEX0 - ZERO) * SHADE0 + ZERO = TEX0 * SHADE0`

**Cycle 1 (pass-through):**

- A = COMBINED (cycle 0 output)
- B = ZERO
- C = ONE
- D = ZERO
- Equation: `(COMBINED - ZERO) * ONE + ZERO = COMBINED`

Per INT-010 source select encoding, the single-cycle encoding for MODULATE is:

- `CC_A_SOURCE[19:16] = 0x0` (TEX_COLOR0)
- `CC_B_SOURCE[23:20] = 0x7` (ZERO)
- `CC_C_SOURCE[27:24] = 0x2` (VER_COLOR0 / SHADE0)
- `CC_D_SOURCE[31:28] = 0x7` (ZERO)
- Alpha selectors: same encoding in bits [15:0].

**CONST_COLOR (address `0x19`):** Not required for MODULATE mode.
Write as `0x0000000000000000` (default).

### Harness Command Sequence

The integration harness drives the following register-write sequence into UNIT-003 (Register File):

1. **Load palette slot 0 and index array into behavioral SDRAM model:**
   Write the 4096-byte palette payload (index 0=white, index 1=mid-gray, remainder=default) into the SDRAM model at the palette base address.
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

3. **Configure color combiner:**
   Write `CC_MODE` (address `0x18`) with the MODULATE preset encoding as described above.
   For the single-cycle register layout per INT-010: `0x0000000000720020` (A=TEX0, B=ZERO, C=VER0, D=ZERO, with matching alpha selectors).
   Encode cycle 1 as pass-through in bits [63:32] per the finalized UNIT-010 two-cycle register layout.

4. **Configure render mode:**
   Write `RENDER_MODE` (address `0x30`) with:
   - `GOURAUD_EN = 1` (bit 0, Gouraud shading for vertex color interpolation)
   - `Z_TEST_EN = 0` (bit 2)
   - `Z_WRITE_EN = 0` (bit 3)
   - `COLOR_WRITE_EN = 1` (bit 4)
   - All other mode bits = 0

5. **Configure framebuffer:**
   Write `FB_CONFIG` (address `0x40`) with:
   - `fb_color_base` = chosen color buffer base address (SDRAM-aligned).
   - `fb_width_log2 = 9` (surface width = 512 pixels).
   - `fb_height_log2 = 9` (surface height = 512 pixels).

6. **Submit vertex 0:**
   - Write `COLOR` (address `0x00`) with `0x000000FF_FF0000FF` (COLOR1=black, COLOR0=red).
   - Write `ST0_ST1` (address `0x01`) with UV0 = (0.5, 0.0) packed per register format.
   - Write `VERTEX_NOKICK` (address `0x06`) with V0 position (X=320, Y=60, Z=`0x0000`).

7. **Submit vertex 1:**
   - Write `COLOR` (address `0x00`) with `0x000000FF_00FF00FF` (COLOR1=black, COLOR0=green).
   - Write `ST0_ST1` (address `0x01`) with UV0 = (0.0, 1.0).
   - Write `VERTEX_NOKICK` (address `0x06`) with V1 position (X=100, Y=380, Z=`0x0000`).

8. **Submit vertex 2 (with kick):**
   - Write `COLOR` (address `0x00`) with `0x000000FF_0000FFFF` (COLOR1=black, COLOR0=blue).
   - Write `ST0_ST1` (address `0x01`) with UV0 = (1.0, 1.0).
   - Write `VERTEX_KICK_012` (address `0x07`) with V2 position (X=540, Y=380, Z=`0x0000`).

9. **Wait for completion:**
   Run the simulation until the pipeline-idle indicator asserts.

10. **Read back framebuffer:**
    The harness reads the framebuffer from the behavioral SDRAM model using the 4×4 block-tiled layout per INT-011, with `WIDTH_LOG2 = 9`.
    The pixel data is serialized as a PNG file at `integration/sim_out/ver_013_color_combined.png`.

11. **Pixel-exact comparison:**
    Compare the simulation output against the approved golden image:

    ```sh
    diff -q integration/sim_out/ver_013_color_combined.png integration/golden/ver_013_color_combined.png
    ```

## Expected Results

- **Pass Criteria:** Pixel-exact match between the simulation output and the approved golden image.
  The rendered image shows a triangle with a checker pattern modulated by the Gouraud vertex color gradient.
  Output color at each pixel equals `texture_color * vertex_color` (per-component MODULATE), producing a color-tinted checker pattern.
  The red-green-blue vertex gradient is visible across both white and mid-gray checker regions; mid-gray regions are at approximately half intensity.
  The color combiner correctly evaluates `(TEX0 - ZERO) * SHADE0 + ZERO` in cycle 0 and passes the result through cycle 1 unchanged.

## Test Implementation

- `rtl/tb/`: Integration simulation harness.
  Instantiates the full GPU RTL hierarchy under Verilator, provides a behavioral SDRAM model implementing the UNIT-011 index-cache miss fill FSM and palette load FSM, drives register-write command sequences, and reads back the framebuffer as PNG files.
- `integration/golden/ver_013_color_combined.png`: Approved golden image (must be regenerated and re-approved after PR2 RTL implementation).

## Notes

- **CC_MODE bit encoding:** The exact CC_MODE encoding for the two-cycle MODULATE + pass-through configuration is determined by the finalized UNIT-010 register decode logic.
  Verify the encoding value `0x0000000000720020` against the UNIT-010 implementation before approving the golden image.
- See `doc/verification/test_strategy.md` (Golden Image Approval Testing section) for the approval workflow: run the simulation, visually inspect the output PNG, copy to the `golden/` directory, and commit.
- **Makefile target:** Run this test with: `cd integration && make test-color-combined`.
- **Relationship to VER-012:** VER-012 tests texture sampling in isolation (vertex colors are white, so MODULATE produces `texture * 1.0 = texture`).
  VER-013 exercises the same texture path but with non-trivial vertex colors, confirming that the color combiner correctly multiplies the two input sources.
- **Palette slot must be loaded before first draw call.**
  The PALETTE0 LOAD_TRIGGER write and FSM completion must precede the first VERTEX_KICK register write in the command sequence.
- **Dithering:** Dithering is disabled (`DITHER_EN=0`) for deterministic, reproducible output.
- **Z-testing:** Z-testing and Z-writing are disabled to isolate color combiner correctness from depth buffer behavior.
- **VER-013 together with VER-004** (Color Combiner Unit Testbench) jointly satisfy REQ-004.01.
  VER-004 verifies individual combiner modes and arithmetic at the unit level; VER-013 verifies MODULATE mode through the full integrated pipeline including INDEXED8_2X2 texture sampling and vertex color interpolation.
- The background of the framebuffer (pixels outside the triangle) will contain whatever the SDRAM model initializes to (typically zero/black).
  The golden image includes the full 512×512 framebuffer surface, so the background color is part of the pixel-exact comparison.
- The golden image must be regenerated and re-approved whenever: PR2 RTL implementation lands; the rasterizer tiled address stride changes; perspective-correct interpolation changes in UNIT-005; UNIT-010 combiner arithmetic changes; the palette LUT addressing or UNORM8→UQ1.8 promotion in UNIT-011.06 changes.
  See `test_strategy.md` for the re-approval workflow.
- **Q4.12 arithmetic constants:** The color combiner ONE (0x1000) and ZERO (0x0000) constants are centralized in `fp_types_pkg.sv`.
  If those constant values change, VER-013 pixel output changes and the golden image must be re-approved.
