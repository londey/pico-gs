# REQ-009: Texture Blend Modes

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to control how multiple textures combine together, so that I can achieve effects like modulated lighting, additive glow, and subtractive masking

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

- - [ ] Set TEXn_BLEND register for each texture unit (except TEX0)
- [ ] Support MULTIPLY blend mode (texture × previous result)
- [ ] Support ADD blend mode (texture + previous result, saturate)
- [ ] Support SUBTRACT blend mode (previous - texture, saturate)
- [ ] Support INVERSE_SUBTRACT blend mode (texture - previous, saturate)
- [ ] Blend operations apply per-component (R, G, B, A independently)
- [ ] Textures evaluate sequentially (TEX0 → TEX1 → TEX2 → TEX3)
- [ ] Verify mathematical correctness with test patterns

---


## Notes

User Story: As a firmware developer, I want to control how multiple textures combine together, so that I can achieve effects like modulated lighting, additive glow, and subtractive masking
