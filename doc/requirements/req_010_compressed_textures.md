# REQ-010: Compressed Textures

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to use BC1 block-compressed textures, so that I can reduce memory usage and bandwidth for texture-heavy scenes

## Rationale

BC1 block compression provides 8:1 compression over RGBA8888 and 4:1 over RGBA4444, enabling significantly more texture data to fit in the 768 KB SRAM texture region. This is critical for rendering complex 3D scenes with multiple textured objects.

## Parent Requirements

None

## Allocated To

- UNIT-006 (Pixel Pipeline)

## Interfaces

- INT-010 (GPU Register Map) - TEXn_FMT.FORMAT field
- INT-014 (Texture Memory Layout) - BC1 format specification

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- [ ] Set TEXn_FMT.FORMAT=01 to enable BC1 mode
- [ ] Texture width and height are multiples of 4 (validated by power-of-2 dimension encoding)
- [ ] Texture data uses BC1 format: 8 bytes per 4x4 block
- [ ] Sampling correctly decodes BC1 blocks (2 RGB565 endpoints + 2-bit indices)
- [ ] Color interpolation: 4-color palette per block (see INT-014)
- [ ] Support 1-bit alpha mode (color0 <= color1 case)
- [ ] Achieve 8:1 memory reduction vs RGBA8, 4:1 vs RGBA4444
- [ ] BC1 data uploaded via MEM_ADDR/MEM_DATA registers (same as other formats)

---


## Notes

Replaces previous indexed palette compression (v2.0). BC1 provides better compression ratio (8:1 vs 4:1) with simpler hardware implementation (no separate LUT required).
