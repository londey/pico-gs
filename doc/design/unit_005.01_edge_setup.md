# UNIT-005.01: Edge Setup

## Purpose

Computes edge function coefficients, bounding box, and the internal triangle area reciprocal for a triangle.
Sub-unit of UNIT-005 (Rasterizer).

## Parent Unit

- UNIT-005 (Rasterizer)

## Implements Requirements

- REQ-002.03 (Rasterization Algorithm) — edge function coefficient computation and internal reciprocal computation

## Interfaces

### Internal Interfaces

- Receives triangle vertex positions from UNIT-004 (Triangle Setup) via the parent UNIT-005 input interface
- Outputs edge coefficients, bounding box, and `inv_area` to UNIT-005.02 (Derivative Pre-computation)
- Shares the reciprocal LUT module (`raster_recip_lut.sv`) with UNIT-005.04 for per-pixel 1/Q computation

## Design Description

**FSM states:** SETUP → SETUP_2 → SETUP_3 (3 cycles)

Computes edge function coefficients A (11-bit), B (11-bit), and C (21-bit) for each of the three triangle edges, and computes the pixel bounding box from the three vertex positions.
Edge C coefficients are produced using 2 dedicated MULT18X18D blocks, serialized over 3 cycles.
The bounding box is clamped to the configured surface dimensions (FB_CONFIG.WIDTH_LOG2, FB_CONFIG.HEIGHT_LOG2).

### Reciprocal LUT Computation

The signed triangle area is computed from vertex positions as:

```
area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
```

`inv_area` (Q3.12) is derived from this area value using the shared reciprocal LUT module:

1. Apply CLZ to the absolute value of the area to determine the normalization shift.
2. Index the 256-entry LUT with the top 8 bits of the CLZ-normalized mantissa to obtain a coarse reciprocal.
3. Apply 1 MULT18X18D linear interpolation between adjacent LUT entries using the remaining mantissa bits to refine the reciprocal.
4. Re-apply the sign and normalization shift to produce the final Q3.12 `inv_area`.

The same reciprocal LUT module instance is reused by UNIT-005.04 during traversal to compute 1/Q per pixel (see UNIT-005.04).

### DSP Usage

| Usage | MULT18X18D count |
|---|---|
| Edge C coefficient computation | 2 |
| Reciprocal LUT linear interpolation | 1 |
| **Sub-unit total** | **3** |

### Outputs

- A and B coefficients for all three edges
- C coefficients for all three edges
- Clamped bounding box min/max
- `inv_area` (Q3.12) — internally computed triangle area reciprocal

## Implementation

- `spi_gpu/src/render/rasterizer.sv`: Edge setup logic within the parent rasterizer module.
  Corresponds to the `always_comb` next-state block covering SETUP/SETUP_2/SETUP_3 states and the associated flat `always_ff` register assignments.
- `spi_gpu/src/render/raster_recip_lut.sv`: 256-entry reciprocal LUT with CLZ normalization and 1 MULT18X18D linear interpolation; instantiated once in `rasterizer.sv` and shared between this sub-unit and UNIT-005.04.

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).

Key verification points for this sub-unit:

- For a known triangle, confirm A and B coefficients match the analytic edge normal vectors.
- Verify bounding box clamping respects FB_CONFIG.WIDTH_LOG2 and FB_CONFIG.HEIGHT_LOG2.
- For known area values (including powers of two, non-powers, and values near LUT boundaries), confirm `inv_area` from the LUT matches the analytic reciprocal within Q3.12 rounding tolerance.
- Verify degenerate triangle (zero area) handling — the reciprocal LUT must produce a defined (saturated or zero) output and the rasterizer must not emit fragments.
