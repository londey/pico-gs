# REQ-002: Rasterizer

## Classification

- **Priority:** Essential
- **Stability:** Draft
- **Verification:** Inspection

## Requirement

The system SHALL rasterize triangles from vertex data into per-pixel fragments, supporting Gouraud shading and edge-function-based coverage evaluation.

## Rationale

The rasterizer area groups all requirements related to converting triangle primitives (defined by three vertices) into a stream of pixel fragments with Gouraud-interpolated colors, perspective-correct texture coordinates, and depth.

## Parent Requirements

None (top-level area)

## Child Requirements

- REQ-002.02 (Gouraud Shaded Triangle)
- REQ-002.03 (Rasterization Algorithm)

## Allocated To

- UNIT-004 (Triangle Setup)
- UNIT-005 (Rasterizer)
- UNIT-006 (Pixel Pipeline)
- UNIT-007 (Memory Arbiter)

## Interfaces

- INT-010 (GPU Register Map)
- INT-011 (SDRAM Memory Layout)

## Notes

This is one of 13 top-level requirement areas organizing the specification hierarchy.
