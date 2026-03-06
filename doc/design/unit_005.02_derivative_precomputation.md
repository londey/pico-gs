# UNIT-005.02: Derivative Pre-computation

## Purpose

Evaluates initial edge functions and computes per-attribute derivatives at the bounding box origin.
Sub-unit of UNIT-005 (Rasterizer).

## Implements Requirements

- REQ-002.03 (Rasterization Algorithm) — derivative precomputation for incremental interpolation

## Interfaces

### Internal Interfaces

- Receives A/B/C edge coefficients and bounding box from UNIT-005.01 (Edge Setup)
- Receives `inv_area` (UQ4.14) from UNIT-005.01 via the setup-iteration overlap FIFO (internally computed; not from UNIT-004)
- Outputs derivatives and initial accumulator values to UNIT-005.03 (Attribute Accumulation) and UNIT-005.04 (Iteration FSM)

## Design Description

**FSM states:** ITER_START → INIT_E1 → INIT_E2 (3 cycles)

Evaluates the three edge functions at the bounding box origin using the 2 MULT18X18D blocks shared with UNIT-005.01 (cold path, once per triangle).
Latches the evaluated edge function values into e0/e1/e2 and the row-start registers e0_row/e1_row/e2_row.

Computes per-attribute derivatives (dAttr/dx and dAttr/dy) for all 14 interpolated attributes using `inv_area` (UQ4.14) from UNIT-005.01 (received via the setup-iteration overlap FIFO) and the A/B edge coefficients.
For each attribute `f` at vertices v0, v1, v2:

```
df/dx = ((f1 - f0) * A01 + (f2 - f0) * A02) * inv_area
df/dy = ((f1 - f0) * B01 + (f2 - f0) * B02) * inv_area
```

The shared multiplier pair is reused in the same 3-cycle ITER_START/INIT_E1/INIT_E2 window.
Initializes the accumulated attribute value registers at the bounding box origin.

### 14 Interpolated Attributes

| # | Attribute | Vertex input format | Derivative format | Notes |
|---|---|---|---|---|
| 1–4 | color0 R, G, B, A | UNORM8 | Q4.28 (guard bits in low 16) | Gouraud VER_COLOR0 |
| 5–8 | color1 R, G, B, A | UNORM8 | Q4.28 (guard bits in low 16) | Gouraud VER_COLOR1 |
| 9 | Z depth | UQ16.0 | UQ16.16 (guard bits in low 16) | Depth buffer value |
| 10 | Q/W | Q3.12 | Q3.28 (guard bits in low 16) | Perspective-correct denominator |
| 11 | S0 = U0/W | Q4.12 | Q4.28 (guard bits in low 16) | Projected texture coord, unit 0 |
| 12 | T0 = V0/W | Q4.12 | Q4.28 (guard bits in low 16) | Projected texture coord, unit 0 |
| 13 | S1 = U1/W | Q4.12 | Q4.28 (guard bits in low 16) | Projected texture coord, unit 1 |
| 14 | T1 = V1/W | Q4.12 | Q4.28 (guard bits in low 16) | Projected texture coord, unit 1 |

All derivatives are maintained in 32-bit wide format with 16 guard bits below the primary fixed-point representation.
This gives Q4.28 for UV/Q/Z and Q4.28 for colors (with the UNORM8 value promoted by the 16 guard bits before derivative computation).

### Outputs

- dAttr/dx, dAttr/dy for all 14 attributes (32-bit each)
- Initial attribute accumulator values at the bounding box origin
- e0/e1/e2 initial values
- e0_row/e1_row/e2_row row-start values

## Implementation

- `spi_gpu/src/render/rasterizer.sv`: Derivative precomputation logic within the parent rasterizer module.
  Corresponds to the `always_comb` next-state block covering ITER_START/INIT_E1/INIT_E2 states and the associated flat `always_ff` register assignments.
- `spi_gpu/src/render/raster_deriv.sv`: Purely combinational derivative precomputation.

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).

Key verification points for this sub-unit:

- For a known triangle, confirm dAttr/dx and dAttr/dy for all 14 attributes match expected values derived from vertex attributes and the internally computed inv_area, within Q4.28 rounding tolerance.
- Verify that S/T projected coordinates (not U/V) are used as inputs to derivative computation — the perspective correction step in UNIT-005.04 converts these to true U, V per pixel.
- Confirm initial accumulator values at the bounding box origin are correctly seeded from vertex attribute evaluation.
