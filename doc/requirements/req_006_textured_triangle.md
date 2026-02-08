# REQ-006: Textured Triangle

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to submit a triangle with texture coordinates, so that I can render textured surfaces

## Rationale

This requirement enables the user story described above.

## Parent Requirements

None

## Allocated To

- UNIT-005 (Rasterizer)
- UNIT-006 (Pixel Pipeline)

## Interfaces

- INT-010 (GPU Register Map)
- INT-011 (SRAM Memory Layout)

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- - [ ] Set TRI_MODE with TEXTURED=1
- [ ] Set TEX_BASE to texture address in SRAM
- [ ] Set TEX_FMT with texture dimensions (power-of-two, log2 encoded)
- [ ] Set UV register (U/W, V/W, 1/W) before each VERTEX write
- [ ] Texture sampling is perspective-correct (no affine warping)
- [ ] Texture coordinates wrap or clamp (configurable)
- [ ] Final pixel = texture color × vertex color

---


## Notes

User Story: As a firmware developer, I want to submit a triangle with texture coordinates, so that I can render textured surfaces
