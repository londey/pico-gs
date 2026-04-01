# UNIT-005.02: Edge Setup

## Purpose

Computes edge function coefficients, bounding box, and the internal triangle area reciprocal for a triangle.
Sub-unit of UNIT-005 (Rasterizer).

## Implements Requirements

- REQ-002.03 (Rasterization Algorithm) — edge function coefficient computation and internal reciprocal computation

## Interfaces

### Internal Interfaces

- Receives triangle vertex positions from UNIT-005.01 (Triangle Setup) via the parent UNIT-005 input interface
- Outputs edge coefficients, bounding box, and `inv_area` to the setup-iteration overlap FIFO, which feeds UNIT-005.03 (Derivative Pre-computation)
- Uses a dedicated triangle setup reciprocal module (`raster_recip_area.sv`) with its own DP16KD; UNIT-005.05 uses a separate dedicated per-pixel reciprocal module (`raster_recip_q.sv`)

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

`inv_area` (UQ4.14, 18-bit unsigned after denormalization) is derived from this area value using the dedicated triangle setup reciprocal module (`raster_recip_area.sv`):

1. Apply CLZ to the 22-bit magnitude of the signed area to determine the normalization shift.
2. Index the 512-entry DP16KD (36×512 mode) with the 9-bit CLZ-normalized mantissa (from normalized[29:21]) to obtain a 36-bit entry packing UQ1.17 reciprocal seed + UQ0.17 delta.
3. Apply 1 MULT18X18D linear interpolation using the delta and remaining mantissa bits to refine the reciprocal in a single read.
4. Re-apply the normalization shift to produce UQ4.14 `inv_area`.
5. (Optional, compile-time parameter) Apply one Newton-Raphson refinement iteration using 1 additional MULT18X18D, adding 2-3 extra cycles of latency.

This module is latency-tolerant as it runs once per triangle during setup.
UNIT-005.05 uses a separate dedicated per-pixel reciprocal module (`raster_recip_q.sv`) for 1/Q computation (see UNIT-005.05).

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
- `inv_area` (UQ4.14, 18-bit) — internally computed triangle area reciprocal

## Implementation

- `components/rasterizer/rtl/src/rasterizer.sv`: Edge setup logic within the parent rasterizer module.
  Corresponds to the `always_comb` next-state block covering SETUP/SETUP_2/SETUP_3 states and the associated flat `always_ff` register assignments.
- `components/rasterizer/rtl/src/raster_recip_area.sv`: Dedicated triangle setup reciprocal module — 1 DP16KD (36×512), CLZ normalization on signed 22-bit magnitude, UQ4.14 output, optional Newton-Raphson refinement.

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).

Key verification points for this sub-unit:

- For a known triangle, confirm A and B coefficients match the analytic edge normal vectors.
- Verify bounding box clamping respects FB_CONFIG.WIDTH_LOG2 and FB_CONFIG.HEIGHT_LOG2.
- For known area values (including powers of two, non-powers, and values near LUT boundaries), confirm `inv_area` from `raster_recip_area.sv` matches the analytic reciprocal within UQ4.14 rounding tolerance.
- Verify degenerate triangle (zero area) handling — the reciprocal LUT must produce a defined (saturated or zero) output and the rasterizer must not emit fragments.
