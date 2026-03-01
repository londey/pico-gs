# UNIT-005.01: Edge Setup

## Purpose

Computes edge function coefficients and bounding box for a triangle.
Sub-unit of UNIT-005 (Rasterizer).

## Parent Unit

- UNIT-005 (Rasterizer)

## Implements Requirements

- REQ-002.03 (Rasterization Algorithm) — edge function coefficient computation

## Interfaces

### Internal Interfaces

- Receives triangle vertex positions from UNIT-004 (Triangle Setup) via the parent UNIT-005 input interface
- Outputs edge coefficients and bounding box to UNIT-005.02 (Derivative Pre-computation)

## Design Description

**FSM states:** SETUP → SETUP_2 → SETUP_3 (3 cycles)

Computes edge function coefficients A (11-bit), B (11-bit), and C (21-bit) for each of the three triangle edges, and computes the pixel bounding box from the three vertex positions.
Edge C coefficients are produced by a shared pair of 11×11 multipliers serialized over 3 cycles.
The bounding box is clamped to the configured surface dimensions (FB_CONFIG.WIDTH_LOG2, FB_CONFIG.HEIGHT_LOG2).

### Outputs

- A and B coefficients for all three edges
- Clamped bounding box min/max

## Implementation

- `spi_gpu/src/render/rasterizer.sv`: Edge setup logic within the parent rasterizer module.
  Corresponds to the `always_comb` next-state block covering SETUP/SETUP_2/SETUP_3 states and the associated flat `always_ff` register assignments.

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).
