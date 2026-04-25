# VER-016: Perspective Road Golden Image Test

## Verification Method

**Test:** Verified by executing a golden image simulation that renders a four-triangle textured road receding into the distance through the full rendering pipeline and comparing the output pixel-exactly against an approved golden image.
The test confirms that perspective-correct texture mapping with INDEXED8_2X2 sampling, Z interpolation across a strong depth gradient, and reverse-Z depth testing all operate correctly in a scene with significant W variation between near and far vertices.

> **Golden image re-approval required.** The current golden image was generated with RGB565 format (and BILINEAR filtering before PR1 collapsed it to NEAREST).
> After PR2 RTL implementation lands (texture format becomes INDEXED8_2X2), re-run this test, visually inspect the output, and re-approve the golden image before marking this test as passing.

## Verifies Requirements

- REQ-003.01 (Textured Triangle — perspective-correct UV interpolation under strong depth gradient)
- REQ-003.09 (Palette Slots)
- REQ-005.02 (Depth Tested Triangle — reverse-Z depth comparison with GEQUAL function)

## Verified Design Units

- UNIT-003 (Register File — FB_CONFIG, FB_CONTROL, TEX0_CFG, PALETTE0, CC_MODE, RENDER_MODE register writes)
- UNIT-005.01 (Triangle Setup — edge function setup for perspective-projected triangles)
- UNIT-005 (Rasterizer — perspective-correct UV interpolation with large W range; per-pixel 1/Q reciprocal)
- UNIT-006 (Pixel Pipeline — early Z-test with GEQUAL compare, pipeline orchestration, MODULATE combiner, framebuffer and Z-buffer writes)
- UNIT-011 (Texture Sampler — INDEXED8_2X2 index cache lookup, palette LUT lookup)
- UNIT-011.03 (Index Cache)
- UNIT-011.06 (Palette LUT)

## Preconditions

- Digital twin library (`gs-twin`) compiles and passes unit tests.
- Integration test harness can write PNG output to `build/dt_out/`.
- For RTL verification: integration simulation harness (`rtl/tb/`) compiles under Verilator; golden image `integration/golden/ver_016_perspective_road.png` has been approved and committed.
- Behavioral SDRAM model correctly implements:
  - Index-cache miss fill FSM: IDLE → FETCH → WRITE_INDEX → IDLE, burst_len=8.
  - Palette load FSM: IDLE → PALETTE_LOAD → IDLE, multiple 32-word bursts covering 4096 bytes.
- Palette slot 0 is pre-loaded by the test command sequence before any draw calls.
- The current golden image predates PR2 (uses RGB565 format) and is expected to fail after PR2 RTL implementation.
  Re-approval is required after PR2 lands.

## Procedure

### Test Texture

The harness generates a 64×64 apparent INDEXED8_2X2 white/black checker pattern with 16×16 apparent-texel squares, stored at SDRAM word address `0xC0000` using 4×4 block-tiled layout (INT-014).
The index array dimensions are 32×32 (each index covers a 2×2 apparent-texel tile).
Palette slot 0 contains: index 0=white (RGBA8888=0xFFFFFFFF, all quadrant colors identical), index 1=black (RGBA8888=0x000000FF, all quadrant colors identical), remaining entries default.
The palette blob (4096 bytes) is stored at a known aligned SDRAM address.
The checker pattern makes perspective foreshortening and UV interpolation errors immediately visible.

### Test Scene

The test renders a road surface as two quad strips (four triangles total) on a 512×512 framebuffer.
The road stretches from near the bottom of the screen to a vanishing point in the upper half, producing a strong depth gradient:

| Region | W (1/depth) | Z (UQ16, reverse-Z) | Screen Y | Description |
| --- | --- | --- | --- | --- |
| Near edge | ~4.4 | `0x389B` | ~503 | Wide road at bottom of screen |
| Far edge | ~51.9 | `0x0265` | ~221 | Narrow road toward horizon |

The W ratio between near and far vertices is approximately 12×, providing strong perspective foreshortening that exercises the per-pixel 1/Q reciprocal module.

The road is split into two strips to keep the V texture coordinate within the Q4.12 representable range (max ±4.0).
Each strip consists of two triangles forming a quad:

- **Strip 0:** Near-left, near-right, far-right, far-left (red vertex color for tri 1, green for tri 2).
- Vertex colors distinguish the two triangles within each strip, providing visual confirmation that the shared edge between triangles is seamless.

Rendering configuration:

- `RENDER_MODE`: `GOURAUD_EN | Z_TEST_EN | Z_WRITE_EN | COLOR_WRITE_EN | Z_COMPARE=GEQUAL` (reverse-Z)
- `CC_MODE`: `MODULATE` (TEX0 × SHADE0)
- `TEX0_CFG`: NEAREST filtering, INDEXED8_2X2, 64×64 apparent texels, repeat wrap, PALETTE_IDX=0

### Command Sequence

1. **Phase `zclear`:**
   - Clear color buffer via `MEM_FILL` (262144 words of zeroes).
   - Clear Z-buffer to `0x0000` via `MEM_FILL` (reverse-Z: 0 = far plane).
   - Configure `FB_CONFIG` with `fb_width_log2=9`, `fb_height_log2=9`, Z-buffer base at word `0x0800`.

2. **Phase `setup`:**
   - Upload 64×64 apparent INDEXED8_2X2 checker texture index array to SDRAM using block-tiled `MEM_FILL` commands.
   - Upload 4096-byte palette blob to SDRAM using `MEM_FILL` commands.
   - Write `PALETTE0` (address `0x12`) with `BASE_ADDR[15:0]` = palette base and `LOAD_TRIGGER[16:16]=1`; wait for the palette load FSM to complete.
   - Configure `FB_CONFIG`, `FB_CONTROL` (scissor 512×512).
   - Configure `TEX0_CFG`: NEAREST, INDEXED8_2X2, 64×64 apparent, repeat wrap, base = index array address, PALETTE_IDX=0.
   - Configure `CC_MODE = MODULATE`, `RENDER_MODE` with Z-test (GEQUAL), Z-write, color-write, Gouraud.

3. **Phase `triangles`:**
   - Submit 4 triangles (2 per strip) with pre-computed perspective-projected screen positions, Z values, Q (1/W) values, and projected S/T texture coordinates.

### Verification

1. **Digital twin (gs-twin):** Parse and execute the hex script phase-by-phase; write color PNG to `build/dt_out/ver_016_perspective_road.png` and Z-buffer PNG to `build/dt_out/ver_016_perspective_road_z.png`.
2. **RTL (Verilator):** Execute the same hex script through the integration harness; read back color and Z framebuffers; pixel-exact comparison against approved golden images.

## Expected Results

- **Pass Criteria:**
  - Pixel-exact match between simulation output and the approved golden image.
  - The checker pattern on the road surface shows correct perspective foreshortening — checker squares appear large near the bottom and small toward the horizon, with straight (not curved) checker lines.
  - The Z-buffer visualization shows a smooth depth gradient from far (dark, near horizon) to near (bright, at bottom).
  - The seam between the two triangles of each strip is invisible — no gaps, overlaps, or color discontinuities along the shared edge.
  - Reverse-Z depth comparison (GEQUAL) correctly writes nearer fragments over farther ones.
  - SDRAM burst requests during index-cache misses use `burst_len=8`, matching UNIT-011.03.

## Test Implementation

- `integration/scripts/ver_016_perspective_road.hex`: Hex command script defining the perspective road scene (must be updated for PR2 to upload the index array + palette and issue PALETTE0 LOAD_TRIGGER).
- `integration/gs-twin/tests/integration.rs`: `ver_016_perspective_road()` — digital twin integration test.
- `integration/gs-twin-cli/src/main.rs`: CLI `render --scene ver_016` entry point.
- `rtl/tb/`: Integration simulation harness (RTL path).
- `integration/golden/ver_016_perspective_road.png`: Approved golden image (RTL path; must be regenerated and re-approved after PR2 RTL implementation).

## Notes

- **Relationship to VER-014:** VER-014 tests perspective-correct texturing on a 3D cube with moderate W variation across faces.
  VER-016 tests a much stronger depth gradient (~12× W ratio) on a road surface, which stresses the per-pixel 1/Q reciprocal module (UNIT-005.05) more aggressively.
- **Relationship to VER-011:** VER-011 tests depth with flat (constant-Z) overlapping triangles.
  VER-016 tests depth with smoothly varying Z across the triangle surface, confirming correct Z interpolation under perspective projection.
- **Reverse-Z convention:** The Z-buffer is cleared to `0x0000` (far plane) and Z_COMPARE is set to GEQUAL, following the reverse-Z convention.
- **Q4.12 range limit:** The road is split into two strips because the V texture coordinate would exceed the Q4.12 representable range (±4.0) if the full road depth were mapped in a single strip.
- **S/T vs U/V:** The hex script provides pre-projected S=U/W and T=V/W texture coordinates at each vertex, along with Q=1/W.
  The rasterizer interpolates S, T, and Q linearly in screen space, then performs per-pixel perspective correction: U=S/Q, V=T/Q (UNIT-005.04).
- **Palette slot must be loaded before first draw call.**
  The PALETTE0 LOAD_TRIGGER write and FSM completion must precede the first VERTEX_KICK in the `triangles` phase.
- The golden image requires re-approval after any change to the perspective correction pipeline (UNIT-005.05), the per-pixel reciprocal module (`raster_recip_q.sv`), the Z interpolation path, the MODULATE combiner (UNIT-010), or the INDEXED8_2X2 sampling path in UNIT-011 (index cache, palette LUT, quadrant extraction).
  Re-approval is required after PR2 RTL implementation lands.
- Dithering is disabled for deterministic output.
