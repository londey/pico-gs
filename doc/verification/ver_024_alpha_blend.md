# VER-024: Alpha Blend Modes Golden Image Test

## Verification Method

**Test:** Digital twin golden image test that renders triangles using all four alpha blend modes over a checkerboard background and compares the output pixel-exactly against an approved golden image.

## Verifies Requirements

- REQ-005.03 (Alpha Blending)

## Verified Design Units

- UNIT-003 (Register File) — RENDER_MODE.ALPHA_BLEND field decode; FB_CACHE_CTRL.FLUSH_TRIGGER blocking-write semantics
- UNIT-006 (Pixel Pipeline) — RGB565→Q4.12 promotion via `fb_promote.sv`
- UNIT-010 (Color Combiner) — CC pass 2 blend equation with DST_COLOR source
- UNIT-013 (Color Tile Cache) — DST_COLOR read path; dirty writeback flush before framebuffer readback

## Preconditions

- Digital twin crates compile and pass `cargo test`.
- Golden image `integration/golden/ver_024_alpha_blend.png` has been approved and committed.
- Hex script `integration/scripts/ver_024_alpha_blend.hex` is committed.

## Procedure

### Test Scene

A 256×256 framebuffer with a dark/light grey 4×4 checkerboard background (64-pixel tiles).
Four foreground triangles are drawn, one per quadrant, each using a different ALPHA_BLEND mode.
Every foreground triangle uses Gouraud shading with two opaque red vertices at the top and one fully transparent red vertex at the bottom tip, creating a smooth alpha gradient across the triangle.

| Quadrant | Blend Mode | RENDER_MODE | Expected Visual |
|----------|-----------|-------------|-----------------|
| Top-left | DISABLED (0) | `0x0011` | Solid red overwrite; alpha ignored |
| Top-right | ADD (1) | `0x0091` | `dst + src×α`: bright at top, fading to checkerboard at tip |
| Bottom-left | SUBTRACT (2) | `0x0111` | `dst − src×α`: cyan tint at top (red subtracted from grey), fading to checkerboard at tip |
| Bottom-right | BLEND (3) | `0x0191` | `src×α + dst×(1−α)`: Porter-Duff source-over gradient |

Foreground vertex colors:

| Vertex | Position (per quadrant) | Color (RGBA8888) | Description |
|--------|------------------------|------------------|-------------|
| V0 | top-left of triangle | `0xFF0000FF` | Red, fully opaque |
| V1 | top-right of triangle | `0xFF0000FF` | Red, fully opaque |
| V2 | bottom-center of triangle | `0xFF000000` | Red, fully transparent |

### Phase Sequence

The hex script uses seven phases:

1. **clear** — `MEM_FILL` to black, configure `FB_CONFIG` (256×256), `FB_CONTROL` (scissor), `CC_MODE` (shade passthrough).
2. **checkerboard** — Draw dark grey full-screen rectangle (2 triangles), then 8 light grey 64×64 squares (16 triangles) to form the checkerboard.
3. **blend_disabled** — `RENDER_MODE` with `ALPHA_BLEND=DISABLED`.
   Set COLOR to red opaque, NOKICK V0 and V1; set COLOR to red transparent, KICK V2.
4. **blend_add** — Same triangle geometry in top-right quadrant with `ALPHA_BLEND=ADD`.
5. **blend_subtract** — Bottom-left quadrant with `ALPHA_BLEND=SUBTRACT`.
6. **blend_porter_duff** — Bottom-right quadrant with `ALPHA_BLEND=BLEND`.
7. **flush** — Write `FB_CACHE_CTRL` (address `0x45`) with `FLUSH_TRIGGER=1`.
   This blocking write causes UNIT-003 to stall the SPI command stream until UNIT-013 completes writing all dirty cache lines back to SDRAM.
   The golden image comparison in the next step reads framebuffer data from SDRAM, so all dirty tiles must reach SDRAM before readback begins.
   After the flush completes, all rendered pixel data is guaranteed to be visible in the SDRAM model.

### Blend Equations

All non-DISABLED modes pre-multiply the source color by the fragment alpha before combining with the destination:

- **ADD**: `result = saturate(dst + src × alpha)`
- **SUBTRACT**: `result = saturate(dst − src × alpha)`
- **BLEND**: `result = src × alpha + dst × (1 − alpha)` (Porter-Duff source-over)

The destination pixel is read from the color tile cache (UNIT-013), which supplies the RGB565 value for the current tile.
On a cache miss, the tile is loaded from SDRAM via a 16-word burst read; on a cache hit with the uninit flag set, the tile is lazy-filled with 0x0000 (no SDRAM access).
The RGB565 value is promoted to Q4.12 via MSB-replication (`fb_promote.sv` / `promote_rgb565()`).
Saturation clamps each channel to [0, 0x1000].

### Running the Test

```bash
cargo test -p gs-twin ver_024_alpha_blend
```

Output PNG: `build/dt_out/ver_024_alpha_blend.png`.

## Expected Results

- **Pass Criteria:** Pixel-exact match between the digital twin output and the approved golden image.
  The rendered image should show:
  - A visible dark/light grey checkerboard across the entire framebuffer.
  - Top-left: solid red triangle completely covering the checkerboard (DISABLED ignores alpha).
  - Top-right: bright triangle at the top (red additive contribution) fading to the unmodified checkerboard at the transparent bottom tip.
  - Bottom-left: cyan-tinted triangle at the top (red subtracted from grey leaves green+blue) fading to checkerboard at the bottom tip.
  - Bottom-right: red triangle blending smoothly into the checkerboard via the alpha gradient.

## Test Implementation

- `integration/scripts/ver_024_alpha_blend.hex` — register-write hex script (configures blend via RENDER_MODE.ALPHA_BLEND; CC pass 2 equation template is selected internally by UNIT-010 based on this field).
- `integration/gs-twin/tests/integration.rs` — `ver_024_alpha_blend` test function.
- `integration/golden/ver_024_alpha_blend.png` — approved golden image (must be re-approved after CC pass 2 implementation).
- `twin/components/color-combiner/src/lib.rs` — `gs-color-combiner` digital twin crate (authoritative blend algorithm via CC pass 2 / DST_COLOR source).

## Notes

- This test exercises the digital twin only.
  RTL-vs-twin comparison via Verilator testbench is tracked separately.
- The blend algorithm is implemented as CC pass 2 in UNIT-010 using the `DST_COLOR` source (destination pixel from the color tile cache, UNIT-013).
  The `gs-color-combiner` twin is the authoritative algorithm spec for all blend modes.
- Source is always pre-multiplied by fragment alpha before combining with the destination for ADD and SUBTRACT modes.
- Dithering is disabled (`DITHER_EN=0`) for deterministic output.
- Z-testing is disabled to isolate blend mode correctness from depth buffer behavior.
- **Cache flush semantics:** The `FB_CACHE_CTRL.FLUSH_TRIGGER` write in phase 7 is a blocking register write: UNIT-003 holds the SPI command stream until `flush_done` is asserted by UNIT-013 (REQ-005.09).
  The digital twin models this synchronously; the RTL must hold the command FIFO advance signal deasserted until flush completes.
- **INVALIDATE_TRIGGER scenario (optional):** After the flush and golden comparison, an optional additional scenario may issue `FB_CACHE_CTRL.INVALIDATE_TRIGGER=1` and then re-render the checkerboard background from scratch.
  The first write to each tile after invalidation must trigger a lazy-fill (no SDRAM read, tile initialized to 0x0000) rather than an SDRAM burst read.
  This exercises the color-side analogue of the Z-buffer fast-clear described in REQ-005.08.
- **Self-overlapping blend coherency:** The checkerboard phase and the four blend triangles together cover all pixels, including overlapping regions at quadrant boundaries.
  The cache read-modify-write path (DST_COLOR read from UNIT-013, blend in UNIT-010, write back to UNIT-013) is exercised for every blended pixel.
  No stale-read artifacts are expected because the cache is write-back with immediate read visibility.
