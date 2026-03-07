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

**FSM states:** ITER_START → INIT_E1 → INIT_E2 → DERIV_0 … DERIV_13 (3 + 14 = 17 cycles)

The derivative precomputation operates in two phases:

**Phase 1 — Edge evaluation (3 cycles, ITER_START → INIT_E1 → INIT_E2):**
Evaluates the three edge functions at the bounding box origin using the 2 MULT18X18D blocks shared with UNIT-005.01 (cold path, once per triangle).
Latches the evaluated edge function values into e0/e1/e2 and the row-start registers e0_row/e1_row/e2_row.

**Phase 2 — Sequential derivative computation (14 cycles, DERIV_0 → DERIV_13):**
Computes per-attribute derivatives (dAttr/dx and dAttr/dy) for all 14 interpolated attributes, one attribute per cycle, using 2 shared MULT18X18D blocks time-multiplexed across the 14 attributes.
Each cycle computes one attribute's dx and dy derivatives simultaneously through the 2 multipliers.

For each attribute `f` at vertices v0, v1, v2, the unscaled derivative terms are precomputed combinationally:

```
raw_dx = (f1 - f0) * A01 + (f2 - f0) * A02
raw_dy = (f1 - f0) * B01 + (f2 - f0) * B02
```

The 2 shared MULT18X18D blocks then perform the `inv_area` scaling:

```
df/dx = raw_dx * inv_area    (multiplier 0)
df/dy = raw_dy * inv_area    (multiplier 1)
```

A 4-bit attribute index counter selects which attribute's `raw_dx`/`raw_dy` feeds the multipliers each cycle.
The `inv_area` (UQ4.14) input from UNIT-005.01 (received via the setup-iteration overlap FIFO) is held constant across all 14 cycles.
Each cycle's multiplier output is latched into the corresponding derivative register.

The 2 MULT18X18D blocks are the same pair used for edge C-coefficient computation in UNIT-005.01 and edge evaluation in Phase 1; they are time-shared across setup, edge evaluation, and derivative computation (DD-036).

Initializes the accumulated attribute value registers at the bounding box origin after all derivatives are computed.

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
  Corresponds to the `always_comb` next-state block covering ITER_START/INIT_E1/INIT_E2/DERIV_0–DERIV_13 states and the associated flat `always_ff` register assignments.
- `spi_gpu/src/render/raster_deriv.sv`: Sequential time-multiplexed derivative precomputation module.
  Contains the 4-bit attribute index counter, raw_dx/raw_dy mux tree, and shared MULT18X18D instantiation for inv_area scaling (DD-036).

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).

Key verification points for this sub-unit:

- For a known triangle, confirm dAttr/dx and dAttr/dy for all 14 attributes match expected values derived from vertex attributes and the internally computed inv_area, within Q4.28 rounding tolerance.
- Verify that S/T projected coordinates (not U/V) are used as inputs to derivative computation — the perspective correction step in UNIT-005.04 converts these to true U, V per pixel.
- Confirm initial accumulator values at the bounding box origin are correctly seeded from vertex attribute evaluation.
