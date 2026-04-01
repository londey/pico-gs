# UNIT-005.01: Triangle Setup

## Purpose

Validates incoming triangle data, computes the signed triangle area, performs backface culling, and passes vertex positions and attributes to the rasterizer pipeline.
Sub-unit of UNIT-005 (Rasterizer).

## Implements Requirements

- REQ-002.03 (Rasterization Algorithm) — triangle validation, backface culling, and vertex attribute passthrough to the rasterizer

## Interfaces

### Internal Interfaces

- Receives triangle vertex data from UNIT-003 (Register File) via the `tri_valid`/`tri_ready` handshake (INT-010): three vertex positions (X, Y, Z), primary vertex colors (RGBA8888 UNORM8, VER_COLOR0), secondary vertex colors (RGBA8888 UNORM8, VER_COLOR1), Q/W per vertex (Q3.12), S0/T0 and S1/T1 projected texture coordinates per vertex (Q4.12), and register state (TRI_MODE, FB_CONFIG)
- Outputs validated vertex data to UNIT-005.02 (Edge Setup) for edge coefficient computation

## Design Description

Triangle Setup is the first stage of the rasterizer pipeline.
It receives a complete triangle descriptor from the register file and decides whether the triangle proceeds into rasterization.

**Backface culling:**
The signed triangle area is computed from the vertex screen-space positions:

```
area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
```

When `TRI_MODE.CULL_MODE` is enabled and the computed area is negative (back-facing winding), the triangle is discarded without emitting any fragments.
Degenerate triangles (zero area) are always discarded.

**Vertex attribute passthrough:**
For non-culled triangles, all vertex positions and attributes (colors, Z, Q/W, S/T projected texture coordinates) are forwarded to UNIT-005.02 (Edge Setup) for coefficient computation and derivative setup.
No coordinate transformation occurs at this stage; vertex positions are already in screen space when received from the register file.

**Register state capture:**
The active `TRI_MODE` and `FB_CONFIG` register values are latched at triangle arrival and held constant throughout processing of that triangle.

## Implementation

- `components/rasterizer/rtl/src/rasterizer.sv`: Triangle Setup logic is contained in the parent rasterizer module.
  Corresponds to the input acceptance logic, area sign check, and attribute latching that occurs before the SETUP FSM state sequence.

## Verification

Covered by UNIT-005 verification (VER-001, VER-010–VER-014).

Key verification points for this sub-unit:

- Verify that a back-facing triangle (negative area with CULL_MODE enabled) produces no fragment output.
- Verify that a front-facing triangle (positive area) proceeds to edge setup.
- Verify that a degenerate triangle (zero area) is discarded.
- Verify that all vertex attributes are forwarded unmodified to UNIT-005.02 for a non-culled triangle.
- Verify that `TRI_MODE` and `FB_CONFIG` register state is latched at triangle arrival and held constant for the duration of rasterization.
