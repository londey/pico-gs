# UNIT-005.03: Attribute Accumulation

## Purpose

Maintains per-attribute accumulators and produces interpolated fragment values via incremental addition.
Sub-unit of UNIT-005 (Rasterizer).

## Parent Unit

- UNIT-005 (Rasterizer)

## Implements Requirements

- REQ-002.02 (Gouraud Shaded Triangle) — color interpolation
- REQ-002.03 (Rasterization Algorithm) — incremental attribute interpolation
- REQ-003.01 (Textured Triangle) — UV coordinate interpolation
- REQ-005.02 (Depth Tested Triangle) — Z interpolation

## Interfaces

### Internal Interfaces

- Receives dAttr/dx, dAttr/dy, and initial accumulator values from UNIT-005.02 (Derivative Pre-computation)
- Receives step commands (step-X, step-Y) from UNIT-005.04 (Iteration FSM)
- Outputs interpolated attribute values to the fragment output bus toward UNIT-006 (Pixel Pipeline)

## Design Description

**Active in:** INTERPOLATE state (inner loop, per inside pixel)

Maintains 13 attribute accumulators (color0, color1, Z, UV0, UV1, Q/W).
When stepping right in X (within a scanline), adds dAttr/dx to each accumulator.
When advancing to a new row in Y, adds dAttr/dy to each accumulator (and reloads the row-start register).
No multiplies are required; all accumulation is performed by addition.
Outputs interpolated attribute values to the fragment output bus at each inside pixel.

UV components are output as Q4.12 by extracting bits [31:16] of the Q4.28 accumulator (discarding the 16 guard bits).
Color components are promoted from 8-bit UNORM to Q4.12 for the fragment output bus (see UNIT-006, Stage 3).

## Implementation

- `spi_gpu/src/render/rasterizer.sv`: Attribute accumulation logic within the parent rasterizer module.
  Corresponds to the `always_comb` next-state block for attribute stepping and the associated flat `always_ff` register assignments.

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).
