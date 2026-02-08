# REQ-004: Gouraud Shaded Triangle

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to submit a triangle with per-vertex colors, so that I can render smooth lighting gradients

## Rationale

This requirement enables the user story described above.

## Parent Requirements

None

## Allocated To

- UNIT-004 (Triangle Setup)
- UNIT-005 (Rasterizer)
- UNIT-006 (Pixel Pipeline)

## Interfaces

- INT-010 (GPU Register Map)

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- - [ ] Set TRI_MODE with GOURAUD=1
- [ ] Set COLOR register before each VERTEX write
- [ ] Colors interpolate linearly across triangle in screen space
- [ ] No banding artifacts visible in 8-bit per channel output

---


## Notes

User Story: As a firmware developer, I want to submit a triangle with per-vertex colors, so that I can render smooth lighting gradients
