# REQ-007: Vertex Transformation

## Classification

- **Priority:** Essential
- **Stability:** Draft
- **Verification:** Inspection

## Requirement

The system SHALL transform mesh vertices through model-view-projection matrices on the host CPU, performing back-face culling, frustum culling, clipping, lighting, and quantization bias correction before submitting transformed vertices to the GPU.

## Rationale

The vertex transformation area groups all host-side software requirements for the 3D transformation pipeline that runs on the RP2350 (or PC debug host).
This covers the per-patch processing loop from mesh data to GPU-ready vertex submissions.

## Parent Requirements

None (top-level area)

## Child Requirements

- REQ-007.01 (Matrix Transformation Pipeline)
- REQ-007.02 (Render Mesh Patch)

## Allocated To

- UNIT-023 (Transformation Pipeline)
- UNIT-024 (Lighting Calculator)

## Notes

This is one of 13 top-level requirement areas organizing the specification hierarchy.
