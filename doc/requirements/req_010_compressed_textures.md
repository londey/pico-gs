# REQ-010: Compressed Textures

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to use compressed textures with indexed palettes, so that I can reduce memory usage and bandwidth for texture-heavy scenes

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

- - [ ] Set TEXn_FMT.COMPRESSED=1 to enable compressed mode
- [ ] Configure TEXn_LUT_BASE with lookup table address
- [ ] Texture data uses 8-bit indices (one per 2×2 texel tile)
- [ ] LUT contains 256 entries, each with 4 RGBA8 texels (16 bytes per entry)
- [ ] Sampling correctly fetches and decodes 2×2 tiles
- [ ] Achieve 4:1 memory reduction vs RGBA8 for appropriate content
- [ ] Upload LUT via MEM_ADDR/MEM_DATA registers

---


## Notes

User Story: As a firmware developer, I want to use compressed textures with indexed palettes, so that I can reduce memory usage and bandwidth for texture-heavy scenes
