# REQ-002: Rasterizer

## Requirement

The system SHALL rasterize triangles from vertex data into per-pixel fragments, supporting Gouraud shading and edge-function-based coverage evaluation.

## Rationale

The rasterizer area groups all requirements related to converting triangle primitives (defined by three vertices) into a stream of pixel fragments with Gouraud-interpolated colors, perspective-correct texture coordinates, and depth.
In ARCHITECTURE.md's three-pipeline model, this area spans two substages of the Render Pipeline: Triangle Setup (edge coefficient computation, bounding box, derivative precomputation) and the Block Pipeline (Hi-Z test, tile buffer prefetch, edge test, attribute interpolation per fragment).
The Pixel Pipeline substage — which begins when UNIT-005 emits the per-fragment bus to UNIT-006 — is covered by separate requirement areas.

## Parent Requirements

None (top-level area)

## Sub-Requirements

- REQ-002.01 (Flat Shaded Triangle — withdrawn)
- REQ-002.02 (Gouraud Shaded Triangle)
- REQ-002.03 (Rasterization Algorithm)

## Interfaces

- INT-010 (GPU Register Map)
- INT-011 (SDRAM Memory Layout)
