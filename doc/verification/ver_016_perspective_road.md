# VER-016: Perspective Road Golden Image Test

## Verification Method

**Test:** Verified by executing a golden image simulation that renders a four-triangle textured road receding into the distance through the full rendering pipeline and comparing the output pixel-exactly against an approved golden image.
The test confirms that perspective-correct texture mapping, Z interpolation across a strong depth gradient, and reverse-Z depth testing all operate correctly in a scene with significant W variation between near and far vertices.

## Verifies Requirements

- REQ-003.01 (Textured Triangle — perspective-correct UV interpolation under strong depth gradient)
- REQ-005.02 (Depth Tested Triangle — reverse-Z depth comparison with GEQUAL function)

## Verified Design Units

- UNIT-003 (Register File — FB_CONFIG, FB_CONTROL, TEX0_CFG, CC_MODE, RENDER_MODE register writes)
- UNIT-004 (Triangle Setup — edge function setup for perspective-projected triangles)
- UNIT-005 (Rasterizer — perspective-correct UV interpolation with large W range; per-pixel 1/Q reciprocal; LOD derivation from CLZ on Q)
- UNIT-006 (Pixel Pipeline — early Z-test with GEQUAL compare, texture cache lookup, RGB565 decoder, MODULATE combiner, framebuffer and Z-buffer writes)

## Preconditions

- Digital twin library (`gs-twin`) compiles and passes unit tests.
- Integration test harness can write PNG output to `build/dt_out/`.
- For RTL verification: integration simulation harness (`integration/harness/`) compiles under Verilator; golden image `integration/golden/ver_016_perspective_road.ppm` has been approved and committed.
- Behavioral SDRAM model correctly implements the INT-032 Cache Miss Handling Protocol.

## Procedure

### Test Texture

The harness generates a 64×64 RGB565 white/black checker pattern with 16×16 squares, stored at SDRAM word address `0xC0000` using 4×4 block-tiled layout (INT-014).
The checker pattern makes perspective foreshortening and UV interpolation errors immediately visible — affine warping produces curved checker lines instead of straight ones.

### Test Scene

The test renders a road surface as two quad strips (four triangles total) on a 512×512 framebuffer.
The road stretches from near the bottom of the screen to a vanishing point in the upper half, producing a strong depth gradient:

| Region | W (1/depth) | Z (UQ16, reverse-Z) | Screen Y | Description |
|--------|-------------|---------------------|----------|-------------|
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
- `TEX0_CFG`: bilinear filtering, RGB565, 64×64, repeat wrap

### Command Sequence

1. **Phase `zclear`:**
   - Clear color buffer via `MEM_FILL` (262144 words of zeroes).
   - Clear Z-buffer to `0x0000` via `MEM_FILL` (reverse-Z: 0 = far plane).
   - Configure `FB_CONFIG` with `fb_width_log2=9`, `fb_height_log2=9`, Z-buffer base at word `0x0800`.

2. **Phase `setup`:**
   - Upload 64×64 checker texture to SDRAM using block-tiled `MEM_FILL` commands.
   - Configure `FB_CONFIG`, `FB_CONTROL` (scissor 512×512).
   - Configure `TEX0_CFG`: bilinear, RGB565, 64×64, repeat wrap, base=`0x0C00`.
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

- **Fail Criteria:**
  - Checker lines appear curved or warped, indicating affine UV interpolation instead of perspective-correct.
  - Z-buffer shows discontinuities or banding, indicating incorrect Z interpolation across the depth gradient.
  - Visible seam between triangles of the same strip.
  - Texture appears solid or garbled, indicating cache miss handling failure or incorrect UV addressing.
  - Any pixel differs between RTL output and the approved golden image.

## Test Implementation

- `integration/scripts/ver_016_perspective_road.hex`: Hex command script defining the perspective road scene.
- `integration/gs-twin/tests/integration.rs`: `ver_016_perspective_road()` — digital twin integration test.
- `integration/gs-twin-cli/src/main.rs`: CLI `render --scene ver_016` entry point.
- `integration/harness/`: Integration simulation harness (RTL path).
- `integration/golden/ver_016_perspective_road.ppm`: Approved golden image (RTL path).

## Notes

- **Relationship to VER-014:** VER-014 tests perspective-correct texturing on a 3D cube with moderate W variation across faces.
  VER-016 tests a much stronger depth gradient (~12× W ratio) on a road surface, which stresses the per-pixel 1/Q reciprocal module (UNIT-005.04) more aggressively.
- **Relationship to VER-011:** VER-011 tests depth with flat (constant-Z) overlapping triangles.
  VER-016 tests depth with smoothly varying Z across the triangle surface, confirming correct Z interpolation under perspective projection.
- **Reverse-Z convention:** The Z-buffer is cleared to `0x0000` (far plane) and Z_COMPARE is set to GEQUAL, following the reverse-Z convention where closer objects have larger Z values.
  This matches the Z-buffer clear and compare setup described in UNIT-006.
- **Q4.12 range limit:** The road is split into two strips because the V texture coordinate would exceed the Q4.12 representable range (±4.0) if the full road depth were mapped in a single strip.
  This is a real-world constraint for scenes with strong perspective foreshortening.
- **S/T vs U/V:** The hex script provides pre-projected S=U/W and T=V/W texture coordinates at each vertex, along with Q=1/W.
  The rasterizer interpolates S, T, and Q linearly in screen space, then performs per-pixel perspective correction: U=S/Q, V=T/Q (UNIT-005.04).
- The golden image requires re-approval after any change to the perspective correction pipeline (UNIT-005.04), the per-pixel reciprocal module (`raster_recip_q.sv`), the Z interpolation path, or the MODULATE combiner (UNIT-010).
- Dithering is disabled for deterministic output.
