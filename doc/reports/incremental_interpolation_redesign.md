# Incremental Interpolation Redesign Proposal

Status: Proposal (for future `/syskit-impact` analysis)
Date: 2026-02-25

## Problem Statement

The rasterizer (UNIT-005) uses per-pixel barycentric weight computation to interpolate vertex attributes (color, depth, UV).
This requires 15 dedicated 18x18 DSP multipliers in the per-pixel hot path:
- 3 multipliers for barycentric weights: `w = (e >> shift) * inv_area`
- 9 multipliers for RGB interpolation: `sum_c = w0*c0 + w1*c1 + w2*c2` (3 channels x 3 vertices)
- 3 multipliers for Z interpolation: `sum_z = w0*z0 + w1*z1 + w2*z2`

The current workaround (AREA_SETUP register with barrel shifter, implemented 2026-02-25) provides adequate precision for most triangle sizes, but has inherent limitations:
- The 16-bit `inv_area` field has only 7-8 bits of effective precision for screen-filling triangles
- The barrel shifter trades spatial resolution for `inv_area` precision
- Adding more interpolated attributes (UV0, UV1, secondary color) would require additional DSP multipliers per attribute set

The ECP5-25K has 28 DSP slices (56 MULT18X18D).
The rasterizer alone uses ~9 slices (17 multipliers).
The full pipeline budget (REQ-011.02) is 16 slices, leaving only 7 for texture filtering, color combiner, and alpha blending.

## Proposed Solution: Incremental Attribute Interpolation

Replace per-pixel barycentric multiply-accumulate with per-pixel addition using precomputed attribute derivatives.

### Mathematical Basis

For any linearly interpolated attribute `C` (color channel, depth, UV coordinate):

```
C(x, y) = w0(x,y)*c0 + w1(x,y)*c1 + w2(x,y)*c2
```

Since barycentric weights are linear in screen space:
```
dC/dx = (c0*A0 + c1*A1 + c2*A2) / (2*area)
dC/dy = (c0*B0 + c1*B1 + c2*B2) / (2*area)
```

Where `A_i`, `B_i` are the edge function coefficients (already computed during triangle setup).

At each pixel, instead of computing 3 multiplies + 2 adds per attribute:
```
C(x+1, y) = C(x, y) + dC_dx      // horizontal step: 1 addition
C(x, y+1) = C_row(y) + dC_dy     // vertical step: 1 addition (at row start)
```

### Setup Phase Changes (once per triangle)

Compute attribute derivatives during triangle setup.
Each derivative requires:
1. Three 11x8 multiplies: `c_i * A_i` (reuse existing shared multiplier pair)
2. One summation of 3 products
3. One division by `2*area` (new: requires divider or reciprocal LUT)

For RGB + Z: 4 attributes x 2 derivatives (dx, dy) = 8 derivative computations.
For full attribute set (2x RGB + Z + 2x UV): 9 attributes x 2 = 18 derivative computations.

Each derivative computation uses 2 cycles on the shared multiplier pair (3 products in 2 cycles using both multipliers), plus 1 cycle for the division.
Total setup overhead: ~27 extra cycles (negligible vs SPI latency of ~72+ cycles per triangle).

### Per-Pixel Changes

| Aspect | Current | Proposed |
|--------|---------|----------|
| Multipliers per pixel | 15 (3 bary + 9 color + 3 Z) | 0 |
| Additions per pixel | 3 (edge increment in ITER_NEXT) | 3 (edges) + 4 (RGBZ) = 7 |
| DSP blocks freed | — | 15 (all per-pixel multipliers) |
| Cycles per pixel | No change (additions fit in existing pipeline stages) | No change |

### DSP Budget Impact

| Pipeline Stage | Current DSP | Proposed DSP | Change |
|----------------|-------------|--------------|--------|
| Rasterizer setup (shared) | 2 | 2 | 0 |
| Rasterizer per-pixel | 15 | 0 | -15 |
| Reciprocal unit (new) | 0 | 1-2 | +1-2 |
| **Rasterizer total** | **17** | **3-4** | **-13 to -14** |
| Texture bilinear (2 samplers) | 8-16 | 8-16 | 0 |
| Color combiner | 2 | 2 | 0 |
| Alpha blending | 3 | 3 | 0 |
| **Full pipeline** | **30-38** | **16-25** | **-13 to -14** |

With this change, the full pipeline fits within the 16-slice budget (REQ-011.02) without requiring 9x9 mode optimization for downstream stages.

### Precision Considerations

- **Fixed-point format**: Derivatives should use Q8.16 or wider (24-bit) to avoid accumulation drift across large triangles.
  At 640 pixels wide, a Q8.16 derivative accumulates at most 640 additions.
  Worst-case drift: 640 * 0.5 ULP = 320 ULP at Q0.16 ≈ 0.005 in [0,1] range.
  This is imperceptible (<0.5% of 255 = 1.3 levels).
- **Row reset**: At each new scanline, reset from the row-start accumulator (not incremental from previous row) to prevent vertical drift.
  The rasterizer already does this for edge functions.
- **Division precision**: The setup-time division `1/(2*area)` needs ~16 bits of precision.
  Options: Newton-Raphson reciprocal (2-3 cycles, 1 multiplier), lookup table (1 cycle, 1 EBR block), or host-computed (0 hardware, use AREA_SETUP register).

### Implementation Approach

**Phase 1**: Keep AREA_SETUP register + barrel shifter as fallback.
Add incremental color derivatives computed during setup.
Use incremental path for color interpolation, keep barycentric for Z (Z precision matters more).

**Phase 2**: Extend to Z interpolation.
Remove barycentric weight multipliers entirely.
Add UV derivative computation for texture coordinate interpolation.

**Phase 3**: Remove AREA_SETUP register and barrel shifter (no longer needed).
Clean up `inv_area` and `area_shift` ports.

### Affected Specifications

| Document | Impact |
|----------|--------|
| UNIT-004 (Triangle Setup) | Add derivative computation to setup pipeline |
| UNIT-005 (Rasterizer) | Replace per-pixel multiply with per-pixel addition |
| INT-010 (Register Map) | Potentially remove AREA_SETUP register (Phase 3) |
| REQ-011.02 (Resource Constraints) | DSP budget becomes achievable without 9x9 mode |

### Risks

1. **Floating-point accumulation**: Incremental addition can drift for very large triangles.
   Mitigation: row-start reset, Q8.16 or wider format.
2. **Subpixel precision**: Edge-aligned triangles may show seams if derivative rounding differs between adjacent triangles.
   Mitigation: shared edge vertices produce identical derivatives for shared edges.
3. **Setup latency**: 27 extra cycles per triangle.
   Mitigation: completely hidden by SPI command latency (~72+ cycles minimum).
4. **Division hardware**: Requires reciprocal unit or lookup table.
   Mitigation: reuse host-computed inv_area from AREA_SETUP register (Phase 1).

## Recommendation

This redesign should be scheduled after the current test harness milestone (VER-010 through VER-013) is complete.
The barrel shifter workaround is adequate for golden image testing.
The incremental approach should be implemented before the DSP budget becomes binding (i.e., before texture filtering and color combiner are activated in the pipeline).
