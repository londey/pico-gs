# REQ-013: Alpha Blending

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to blend rendered pixels with framebuffer content based on alpha, so that I can render transparent and semi-transparent objects

## Rationale

This requirement enables the user story described above.

## Parent Requirements

None

## Allocated To

- UNIT-006 (Pixel Pipeline)

## Interfaces

- INT-010 (GPU Register Map)

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- - [ ] Set ALPHA_BLEND register to select blend mode
- [ ] Support DISABLED mode (overwrite destination)
- [ ] Support ADD mode (source + destination, saturate)
- [ ] Support SUBTRACT mode (source - destination, saturate)
- [ ] Support ALPHA_BLEND mode (standard Porter-Duff source-over)
- [ ] Alpha blend applies per-component (R, G, B, A)
- [ ] Disable Z_WRITE when rendering transparent objects (Z_TEST still enabled)
- [ ] Verify correct transparency with alpha=0, 0.5, and 1.0

---


## Notes

User Story: As a firmware developer, I want to blend rendered pixels with framebuffer content based on alpha, so that I can render transparent and semi-transparent objects
