# UNIT-005.04: Iteration FSM

## Purpose

Drives the bounding box walk, edge testing, and fragment output handshake.
Sub-unit of UNIT-005 (Rasterizer).

## Parent Unit

- UNIT-005 (Rasterizer)

## Implements Requirements

- REQ-002.03 (Rasterization Algorithm) — bounding box traversal and edge testing

## Interfaces

### Internal Interfaces

- Receives e0/e1/e2 initial values and A/B edge coefficients from UNIT-005.01 (Edge Setup) and UNIT-005.02 (Derivative Pre-computation)
- Commands UNIT-005.03 (Attribute Accumulation) to step accumulators on inside-pixel and row-advance events
- Drives fragment output bus handshake (frag_valid/frag_ready) toward UNIT-006 (Pixel Pipeline)

## Design Description

**FSM states:** EDGE_TEST, INTERPOLATE, ITER_NEXT (inner loop)

Drives the bounding box walk: tests edge functions (e0 >= 0, e1 >= 0, e2 >= 0) at the current pixel, conditionally enables UNIT-005.03 for inside pixels, then advances to the next pixel.
When stepping right, adds A coefficients to e0/e1/e2.
When advancing to a new row, adds B coefficients to e0/e1/e2 (and reloads e0_row/e1_row/e2_row).
On bounding box exhaustion, returns to IDLE and asserts tri_ready.
Manages the fragment output bus handshake: asserts frag_valid when a fragment is ready; stalls (holds all state) when frag_ready is deasserted by UNIT-006.

## Implementation

- `spi_gpu/src/render/rasterizer.sv`: Iteration FSM logic within the parent rasterizer module.
  Corresponds to the `always_comb` next-state block for the iteration state machine and the associated flat `always_ff` register assignments.

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).
