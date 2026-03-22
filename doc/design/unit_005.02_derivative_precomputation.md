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

**FSM states:** ITER_START → INIT_E1 → INIT_E2 → 7 derivative cycles → FINISHING (3 + 7 + 1 = 11 cycles from parent FSM perspective; `raster_deriv` uses 7 running + 1 finishing = 8 internal cycles)

The derivative precomputation operates in two phases:

**Phase 1 — Edge evaluation (3 cycles, ITER_START → INIT_E1 → INIT_E2):**
Evaluates the three edge functions at the bounding box origin using 2 MULT18X18D blocks shared with UNIT-005.01 (cold path, once per triangle).
Latches the evaluated edge function values into e0/e1/e2 and the row-start registers e0_row/e1_row/e2_row.

**Phase 2 — Sequential derivative computation (8 cycles, `raster_deriv` module):**
Computes per-attribute derivatives (dAttr/dx and dAttr/dy) for all 14 interpolated attributes, two attributes per cycle, using 4 dedicated MULT18X18D blocks.
A 3-bit attribute-pair index counter (0–6) selects which pair of attributes feeds the multipliers each cycle.
The 7 running cycles cover attribute pairs 0–1, 2–3, …, 12–13; the 8th cycle (FINISHING) registers the final outputs and asserts `deriv_done`.

The computation is restructured to keep DSP operands within 18×18 bits:

```
scaled_delta = (f_i - f_0) * inv_area      (4 × MULT18X18D, signed 17-bit × unsigned 18-bit)
raw_dx = scaled_delta_1 * A01 + scaled_delta_2 * A02   (shift-add in LUTs, 36×11)
raw_dy = scaled_delta_1 * B01 + scaled_delta_2 * B02   (shift-add in LUTs, 36×11)
```

The vertex deltas `(f_i - f_0)` are 17-bit signed (fits Q4.12 or promoted UNORM8).
The `inv_area` (UQ4.14) input from UNIT-005.01 is held constant across all 7 cycles.
Each DSP multiply is performed by a `raster_dsp_mul` helper that computes `|a| * b` as 18×18 unsigned (1 MULT18X18D) then restores the sign in LUTs.

Edge coefficient application (36×11 bit) and initial value computation (32×11 bit) use shift-and-add functions that synthesize to LUT logic only, avoiding DSP inference by Yosys `mul2dsp`.

The 4 MULT18X18D blocks are dedicated to `raster_deriv` (not shared with UNIT-005.01).
UNIT-005.01 edge evaluation in Phase 1 uses the parent rasterizer's own multiplier resources.

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

- `components/rasterizer/rtl/rasterizer.sv`: Derivative precomputation logic within the parent rasterizer module.
  Corresponds to the `always_comb` next-state block covering ITER_START/INIT_E1/INIT_E2/DERIV_0–DERIV_13 states and the associated flat `always_ff` register assignments.
- `components/rasterizer/rtl/raster_deriv.sv`: Sequential time-multiplexed derivative precomputation module.
  Contains a `raster_dsp_mul` helper (signed 17×unsigned 18 via 1 MULT18X18D), 4 DSP instances for `delta × inv_area`, shift-and-add functions for LUT-only edge and init multiplies, and a 3-bit attribute-pair counter processing 2 attributes per cycle (7 running + 1 finishing = 8 cycles).

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).

Key verification points for this sub-unit:

- For a known triangle, confirm dAttr/dx and dAttr/dy for all 14 attributes match expected values derived from vertex attributes and the internally computed inv_area, within Q4.28 rounding tolerance.
- Verify that S/T projected coordinates (not U/V) are used as inputs to derivative computation — the perspective correction step in UNIT-005.04 converts these to true U, V per pixel.
- Confirm initial accumulator values at the bounding box origin are correctly seeded from vertex attribute evaluation.
