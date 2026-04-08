# VER-024: Alpha Blend Modes Golden Image Test

## Verification Method

**Test:** Digital twin golden image test that renders triangles using all four alpha blend modes over a checkerboard background and compares the output pixel-exactly against an approved golden image.

## Verifies Requirements

- REQ-005.03 (Alpha Blending)

## Verified Design Units

- UNIT-003 (Register File) — RENDER_MODE.ALPHA_BLEND field decode
- UNIT-006 (Pixel Pipeline) — alpha blend stage, framebuffer readback + RGB565→Q4.12 promotion

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

The hex script uses six phases:

1. **clear** — `MEM_FILL` to black, configure `FB_CONFIG` (256×256), `FB_CONTROL` (scissor), `CC_MODE` (shade passthrough).
2. **checkerboard** — Draw dark grey full-screen rectangle (2 triangles), then 8 light grey 64×64 squares (16 triangles) to form the checkerboard.
3. **blend_disabled** — `RENDER_MODE` with `ALPHA_BLEND=DISABLED`.
   Set COLOR to red opaque, NOKICK V0 and V1; set COLOR to red transparent, KICK V2.
4. **blend_add** — Same triangle geometry in top-right quadrant with `ALPHA_BLEND=ADD`.
5. **blend_subtract** — Bottom-left quadrant with `ALPHA_BLEND=SUBTRACT`.
6. **blend_porter_duff** — Bottom-right quadrant with `ALPHA_BLEND=BLEND`.

### Blend Equations

All non-DISABLED modes pre-multiply the source color by the fragment alpha before combining with the destination:

- **ADD**: `result = saturate(dst + src × alpha)`
- **SUBTRACT**: `result = saturate(dst − src × alpha)`
- **BLEND**: `result = src × alpha + dst × (1 − alpha)` (Porter-Duff source-over)

The destination pixel is read from the framebuffer (RGB565) and promoted to Q4.12 via MSB-replication (`fb_promote.sv` / `promote_rgb565()`).
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

- **Fail Criteria:** Any pixel differs between the twin output and the approved golden image.
  Common failure modes include incorrect blend mode selection, missing alpha pre-multiplication in ADD/SUBTRACT, incorrect RGB565→Q4.12 promotion, or incorrect saturation logic.

## Test Implementation

- `integration/scripts/ver_024_alpha_blend.hex` — register-write hex script.
- `integration/gs-twin/tests/integration.rs` — `ver_024_alpha_blend` test function.
- `integration/golden/ver_024_alpha_blend.png` — approved golden image.
- `components/alpha-blend/twin/src/lib.rs` — `gs-alpha-blend` digital twin crate (authoritative blend algorithm).
- `components/alpha-blend/rtl/src/alpha_blend.sv` — RTL implementation (must match twin).

## Notes

- This test exercises the digital twin only.
  RTL-vs-twin comparison via Verilator testbench is tracked separately.
- The alpha blend RTL (`alpha_blend.sv`) predates the twin implementation and does not yet pre-multiply source by alpha for ADD/SUBTRACT modes.
  The twin (this test's reference) is the authoritative algorithm spec; the RTL must be updated to match.
- REQ-005.03 wording ("add the source fragment color to the destination") does not explicitly mention pre-multiplying by alpha for ADD/SUBTRACT.
  The requirement text should be updated to reflect the implemented behavior: source is always scaled by fragment alpha before combining with the destination.
- Dithering is disabled (`DITHER_EN=0`) for deterministic output.
- Z-testing is disabled to isolate blend mode correctness from depth buffer behavior.
