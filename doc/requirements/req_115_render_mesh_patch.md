# REQ-115: Render Mesh Patch

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

When the render executor receives a RenderMeshPatch command, the system SHALL DMA-prefetch the referenced mesh patch data from flash, unpack vertex attributes from the quantized SoA blob per INT-031 (u16 positions, i16 normals, i16 UVs for up to 2 texture units), convert to f32 for processing, transform all patch vertices through the MVP matrix (which includes the quantization bias per REQ-104), compute per-vertex Gouraud lighting, perform back-face culling, optionally clip triangles against frustum planes indicated by the command's clip flags, and submit the resulting visible triangles to the GPU using the kicked vertex register protocol (VERTEX_NOKICK, VERTEX_KICK_012, VERTEX_KICK_021) as specified in INT-010.

## Rationale

This requirement defines the functional behavior of the render mesh patch subsystem.

## Parent Requirements

REQ-TBD-VERTEX-TRANSFORM (Vertex Transformation)

## Allocated To

- UNIT-021 (Core 1 Render Executor)
- UNIT-022 (GPU Driver Layer)
- UNIT-023 (Transformation Pipeline)
- UNIT-024 (Lighting Calculator)

## Interfaces

- INT-020 (GPU Driver API)
- INT-021 (Render Command Format)

## Verification Method

**Test:** Verify that a RenderMeshPatch command with known patch data produces the expected sequence of GPU register writes (COLOR, UV0, VERTEX_NOKICK/KICK_012/KICK_021) after transformation, lighting, and culling. Verify that UV computation covers up to 2 texture units per the dual-texture architecture. Verify that clip_flags=0 skips triangle clipping, and non-zero clip_flags triggers Sutherland-Hodgman clipping against the indicated planes.

## Notes

Functional requirements grouped from specification.

UV computation supports up to 2 texture units per vertex (dual-texture architecture).
Color combiner setup (combiner mode, material colors) is configured per-material before mesh patch submission, not per-patch.
