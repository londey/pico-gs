# UNIT-005.02: Derivative Pre-computation

## Purpose

Evaluates initial edge functions and computes per-attribute derivatives at the bounding box origin.
Sub-unit of UNIT-005 (Rasterizer).

## Parent Unit

- UNIT-005 (Rasterizer)

## Implements Requirements

- REQ-002.03 (Rasterization Algorithm) — derivative precomputation for incremental interpolation

## Interfaces

### Internal Interfaces

- Receives A/B edge coefficients and bounding box from UNIT-005.01 (Edge Setup)
- Receives `inv_area` from UNIT-004 (Triangle Setup)
- Outputs derivatives and initial accumulator values to UNIT-005.03 (Attribute Accumulation) and UNIT-005.04 (Iteration FSM)

## Design Description

**FSM states:** ITER_START → INIT_E1 → INIT_E2 (3 cycles)

Evaluates the three edge functions at the bounding box origin using the same shared multiplier pair from UNIT-005.01 (cold path, once per triangle).
Latches the evaluated edge function values into e0/e1/e2 and the row-start registers e0_row/e1_row/e2_row.
Computes per-attribute derivatives (dAttr/dx and dAttr/dy) for all 13 interpolated attributes: color0 R/G/B/A, color1 R/G/B/A, Z, U0, V0, U1, V1, and Q/W.
Derivative computation uses `inv_area` from UNIT-004 and the A/B edge coefficients; the shared multiplier pair is reused in the same 3-cycle window.
Initializes the accumulated attribute value registers at the bounding box origin.

### Outputs

- dAttr/dx, dAttr/dy for all 13 attributes
- Initial attribute accumulator values
- e0/e1/e2 initial values

## Implementation

- `spi_gpu/src/render/rasterizer.sv`: Derivative precomputation logic within the parent rasterizer module.
  Corresponds to the `always_comb` next-state block covering ITER_START/INIT_E1/INIT_E2 states and the associated flat `always_ff` register assignments.

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).
