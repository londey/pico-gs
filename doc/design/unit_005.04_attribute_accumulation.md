# UNIT-005.04: Attribute Accumulation

## Purpose

Maintains per-attribute accumulators and produces interpolated fragment values via incremental addition.
Sub-unit of UNIT-005 (Rasterizer).

## Implements Requirements

- REQ-002.02 (Gouraud Shaded Triangle) — color interpolation
- REQ-002.03 (Rasterization Algorithm) — incremental attribute interpolation
- REQ-003.01 (Textured Triangle) — UV coordinate interpolation
- REQ-004.02 (Extended Precision Fragment Processing) — RGBA output promoted to Q4.12 accumulator format
- REQ-005.02 (Depth Tested Triangle) — Z interpolation

## Interfaces

### Internal Interfaces

- Receives dAttr/dx, dAttr/dy (32-bit each), and initial accumulator values from UNIT-005.03 (Derivative Pre-computation)
- Receives step commands (step-X, step-Y, row-reload) from UNIT-005.05 (Iteration FSM)
- Outputs interpolated raw attribute values (32-bit each) to UNIT-005.05 for perspective correction and fragment emission

## Design Description

**Active in:** EDGE_TEST and ITER_NEXT states (inner loop, per pixel/tile step)

Maintains 14 attribute accumulators in 32-bit wide registers (see UNIT-005.03 for attribute list and formats).
When stepping right in X within a tile, adds dAttr/dx to each accumulator.
When advancing to a new tile row in Y, reloads each accumulator from its row-start register and adds dAttr/dy to the row-start register.
No multiplies are required; all accumulation is performed by addition.

### Accumulator Width

All 14 accumulators are 32 bits wide.
The upper 16 bits hold the primary fixed-point value; the lower 16 bits are guard bits that accumulate rounding error across steps without loss.
See UNIT-005.03 for per-attribute formats.

### Output Extraction and Clamping

Accumulator outputs are extracted and promoted before being passed to UNIT-005.05 for fragment emission:

| Attribute group | Extraction | Fragment bus format |
|---|---|---|
| color0 R, G, B, A | acc[31:16] → Q4.12; clamp to [0, 255]; output as UNORM8 | UNORM8 (8-bit per channel) |
| color1 R, G, B, A | acc[31:16] → Q4.12; clamp to [0, 255]; output as UNORM8 | UNORM8 (8-bit per channel) |
| Z | acc[31:16] → UQ16.0 | 16-bit unsigned |
| Q/W | acc[31:16] → Q3.12 | Q3.12 signed 16-bit |
| S0, T0, S1, T1 | acc[31:16] → Q4.12 | Q4.12 signed 16-bit |

Color clamping is applied after extraction: accumulated colors that overflow the UNORM8 range (due to vertex attributes at the triangle boundary) are saturated to 0 or 255 before output.
S/T projected texture coordinates are passed to UNIT-005.05 as Q4.12 values for the 3-cycle perspective correction pipeline; they are not directly output to the fragment bus.

## Implementation

- `rtl/components/rasterizer/src/raster_attr_accum.sv`: Attribute accumulators, derivative registers, step logic, output extraction and clamping.

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).

Key verification points for this sub-unit:

- Step across a rasterized triangle and confirm accumulated values at each fragment match analytic values within Q4.12 rounding tolerance for all 14 attributes.
- Verify color clamping: drive a triangle with colors that exceed UNORM8 range at intermediate steps; confirm output is saturated to 0 or 255.
- Verify row-start reload: advance to a new tile row and confirm accumulators correctly reload from row-start registers, not from the prior pixel's value.
- Verify that S/T outputs are in Q4.12 and correctly represent the projected (not corrected) texture coordinates — perspective correction is applied downstream in UNIT-005.05.
