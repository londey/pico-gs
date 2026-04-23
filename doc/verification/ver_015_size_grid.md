# VER-015: Triangle Size Grid Golden Image Test

## Verification Method

**Test:** Verified by executing a golden image simulation that renders eight Gouraud-shaded triangles spanning a wide range of sizes (1 px to 128 px per side) through the rendering pipeline and comparing the output pixel-exactly against an approved golden image.
The test confirms that the rasterizer correctly handles triangles from sub-tile scale (smaller than a single 4×4 tile) up to large triangles spanning many tiles, exercising derivative precision, bounding-box clamping, and edge-function evaluation at extreme inv_area values.

## Verifies Requirements

- REQ-002.02 (Gouraud Shaded Triangle — color interpolation across a wide range of triangle sizes)
- REQ-002.03 (Rasterization Algorithm — correct fragment emission for very small and very large triangles)

## Verified Design Units

- UNIT-003 (Register File — FB_CONFIG, FB_CONTROL, RENDER_MODE, CC_MODE register writes)
- UNIT-005.01 (Triangle Setup — edge function setup for triangles of varying size)
- UNIT-005 (Rasterizer — derivative precision with large inv_area for tiny triangles; 4×4 tile traversal for large triangles)
- UNIT-006 (Pixel Pipeline — color write path)

## Preconditions

- Digital twin library (`gs-twin`) compiles and passes unit tests.
- Integration test harness can write PNG output to `build/dt_out/`.
- For RTL verification: integration simulation harness (`rtl/tb/`) compiles under Verilator; golden image `integration/golden/ver_015_size_grid.png` has been approved and committed.

## Procedure

### Test Scene

The test renders eight Gouraud-shaded triangles arranged in a 4×2 grid on a 512×480 framebuffer.
Each triangle has the same color assignment (red at top vertex, blue at bottom-right, green at bottom-left) but a different size, doubling at each step:

| Triangle | Side Length (px) | Grid Position | Notes |
|----------|-----------------|---------------|-------|
| 0 | 1 | Row 0, Col 0 (x=64) | Sub-pixel; tests minimum fragment emission |
| 1 | 2 | Row 0, Col 1 (x=192) | 1–2 fragments expected |
| 2 | 4 | Row 0, Col 2 (x=320) | Fits within a single 4×4 tile |
| 3 | 8 | Row 0, Col 3 (x=448) | Spans ~2 tiles |
| 4 | 16 | Row 1, Col 0 (x=64) | Spans ~4 tiles per axis |
| 5 | 32 | Row 1, Col 1 (x=192) | Spans ~8 tiles per axis |
| 6 | 64 | Row 1, Col 2 (x=320) | Large triangle, many tiles |
| 7 | 128 | Row 1, Col 3 (x=448) | Largest; partially clipped by right edge |

All triangles use:
- `RENDER_MODE`: `GOURAUD_EN | COLOR_WRITE_EN` (no Z-test, no texturing)
- `CC_MODE`: `SHADE_PASSTHROUGH` (shade color passed through without texture modulation)
- Z = 0 at all vertices

### Command Sequence

1. **Clear framebuffer** via `MEM_FILL` (262144 words of zeroes).
2. **Configure framebuffer:** `FB_CONFIG` with `fb_width_log2=9`, `fb_height_log2=9`; `FB_CONTROL` with scissor 512×480.
3. **Configure render mode:** `GOURAUD_EN | COLOR_WRITE_EN`, `CC_MODE = SHADE_PASSTHROUGH`.
4. **Submit 8 triangles:** Each triangle is submitted as 3 vertex writes (2× `VERTEX_NOKICK` + 1× `VERTEX_KICK_012`), with `COLOR` set before each vertex.

### Verification

1. **Digital twin (gs-twin):** Parse and execute the hex script; verify at least one non-background pixel is emitted; write golden PNG to `build/dt_out/ver_015_size_grid.png`.
2. **RTL (Verilator):** Execute the same hex script through the integration harness; read back the framebuffer; pixel-exact comparison against approved golden image.

## Expected Results

- **Pass Criteria:**
  - At least one non-background pixel (non-zero) is present in the rendered framebuffer (digital twin assertion).
  - All eight triangles produce visible Gouraud-shaded output at their expected grid positions.
  - Pixel-exact match between RTL simulation output and the approved golden image.
  - The 1 px triangle (triangle 0) produces at least one fragment — it must not be rejected as degenerate.
  - Triangle 7 (128 px side) is correctly clipped at the right framebuffer edge (x=512).

## Test Implementation

- `integration/scripts/ver_015_size_grid.hex`: Hex command script defining the 8-triangle scene.
- `integration/gs-twin/tests/integration.rs`: `ver_015_size_grid()` — digital twin integration test.
- `integration/gs-twin-cli/src/main.rs`: CLI `render --scene ver_015` entry point.
- `rtl/tb/`: Integration simulation harness (RTL path).
- `integration/golden/ver_015_size_grid.png`: Approved golden image (RTL path).

## Notes

- This test specifically targets the rasterizer's behavior at size extremes.
  VER-001 procedure step 3 notes that "test cases should include small triangles (e.g., 4×4 pixels or smaller) to verify derivative precision with large inv_area values" — VER-015 provides that coverage at the golden-image integration level.
- Triangle sizes double geometrically (1, 2, 4, 8, 16, 32, 64, 128) to cover both sub-tile and multi-tile regimes with a small number of primitives.
- Vertex positions use Q12.4 sub-pixel precision; the smallest triangle (1 px) has vertices offset by 0.5 px from center, exercising sub-pixel vertex placement.
- The golden image requires re-approval after any change to the rasterizer's derivative precomputation (UNIT-005.03), edge-function evaluation, or 4×4 tile traversal logic (UNIT-005.05).
- Dithering is disabled for deterministic output.
- Z-testing is disabled to isolate rasterizer size-dependent behavior from depth buffer interaction.
