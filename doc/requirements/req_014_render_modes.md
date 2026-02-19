# REQ-014: Render Modes

## Classification

- **Priority:** Essential
- **Stability:** Draft
- **Verification:** Inspection

## Requirement

The system SHALL support multiple render modes (material types), each defining a specific GPU register configuration, color combiner setup, and vertex processing strategy for rendering mesh patches with different visual characteristics.

## Rationale

The render modes area groups requirements for the different material types that the rendering pipeline supports.
Each render mode defines how mesh patches are processed: which vertex attributes are used, how the GPU's color combiner is configured, and what texture/lighting setup is applied.
The shared vertex transformation infrastructure (REQ-007) provides the common matrix and patch processing used by all render modes.

## Parent Requirements

None (top-level area)

## Child Requirements

- REQ-014.01 (Lightmapped Static Mesh)
- REQ-014.02 (Static Mesh with Directional Lighting)
- REQ-014.03 (Skinned Mesh)
- REQ-014.04 (Particle System)

## Notes

This is one of the top-level requirement areas organizing the specification hierarchy.
