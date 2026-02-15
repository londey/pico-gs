# REQ-003: Flat Shaded Triangle

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

When the firmware writes three VERTEX registers with TRI_MODE configured for flat shading (GOURAUD=0, TEXTURED=0), the system SHALL rasterize a triangle using the single COLOR value from the first vertex for all pixels.

## Rationale

Flat-shaded triangles are the simplest rendering primitive, requiring no texture sampling or color interpolation. They enable UI rendering, solid-color geometry, debug visualization, and serve as a baseline for verifying the rasterization pipeline before adding more complex shading modes (Gouraud, texturing).

## Parent Requirements

None

## Allocated To

- UNIT-004 (Triangle Setup)
- UNIT-005 (Rasterizer)
- UNIT-006 (Pixel Pipeline)
- UNIT-007 (Memory Arbiter)

## Interfaces

- INT-010 (GPU Register Map)

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- - [ ] Set TRI_MODE to flat shading (GOURAUD=0, TEXTURED=0)
- [ ] Set COLOR register once (used for all three vertices)
- [ ] Write three VERTEX registers; third write triggers rasterization
- [ ] Triangle renders correctly for all orientations (CW/CCW)
- [ ] Subpixel precision prevents "dancing" vertices during animation

---


## Notes

Flat shading is the foundation of the rendering pipeline. All triangles (even textured ones) can fall back to this mode if no texture units are enabled.
