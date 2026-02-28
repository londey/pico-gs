# REQ-014: Render Modes

## Classification

- **Priority:** Essential
- **Stability:** Stable
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

## Allocated To

- UNIT-006 (Pixel Pipeline) — GPU-side multi-texture and combiner execution for lightmapped mode
- UNIT-021 (Core 1 Render Executor) — host-side render command dispatch
- UNIT-022 (GPU Driver Layer) — GPU register configuration for each mode
- UNIT-023 (Transformation Pipeline) — vertex transformation shared by all modes
- UNIT-024 (Lighting Calculator) — per-vertex lighting for directionally-lit modes

## Verification Method

**Inspection:** Verify that each render mode's GPU register configuration (combiner mode, texture unit config, render mode flags) produces the correct visual output through UNIT-006.
Child requirements carry Test-level verification; REQ-014.01 (Lightmapped Static Mesh) is the primary integration test target via VER-014.

## Notes

This is one of the top-level requirement areas organizing the specification hierarchy.
Render mode flags `mode_gouraud`, `mode_cull`, `mode_alpha_blend`, `mode_dither_en`, `mode_stipple_en`, `mode_alpha_test`, `mode_alpha_ref`, texture config `tex0_cfg`/`tex1_cfg`, and color combiner config `cc_mode`/`const_color` are wired from UNIT-003 (Register File) to UNIT-006 (Pixel Pipeline) and take functional effect during rendering.
See INT-010 for register field definitions.
