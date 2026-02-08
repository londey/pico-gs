# REQ-003: Flat Shaded Triangle

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to submit a triangle with a single color, so that I can render simple geometry without texture overhead

## Rationale

This requirement enables the user story described above.

## Parent Requirements

None

## Allocated To

- UNIT-004 (Triangle Setup)
- UNIT-005 (Rasterizer)
- UNIT-006 (Pixel Pipeline)
- UNIT-007 (SRAM Arbiter)

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

User Story: As a firmware developer, I want to submit a triangle with a single color, so that I can render simple geometry without texture overhead
