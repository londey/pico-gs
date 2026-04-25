# REQ-003: Texture Samplers

## Requirement

The system SHALL sample and deliver texture data to the pixel pipeline using the INDEXED8_2X2 format, supporting dual-texture rendering, UV wrapping, palette slot selection, and per-sampler index caching.

## Rationale

The texture samplers area groups all requirements related to reading texture memory, performing palette lookups, applying addressing modes, and feeding texel data to the color combiner.

## Parent Requirements

None (top-level area)

## Interfaces

- INT-010 (GPU Register Map)
- INT-014 (Texture Memory Layout)

## Design Allocation

UNIT-011 (Texture Sampler)

## Child Requirements

- REQ-003.01 (Textured Triangle)
- REQ-003.02 (Multi-Texture Rendering)
- REQ-003.05 (UV Wrapping Modes)
- REQ-003.06 (Texture Sampling)
- REQ-003.08 (Texture Cache)
- REQ-003.09 (Palette Slots)

## Verification Method

**Inspection:** Verify that UNIT-011 instantiates the index cache (UNIT-011.03), palette LUT (UNIT-011.06), and UV coordinate processing (UNIT-011.01) with a single INDEXED8_2X2 format path.
Child requirements REQ-003.01 through REQ-003.09 carry individual Test-level verification via VER-012/VER-014 (textured golden image tests) and the palette/index-cache unit testbench.

## Notes

The single texture format is INDEXED8_2X2 (TEXn_CFG.FORMAT = 4'd0).
The 4-bit FORMAT field width is retained for ABI stability; values 4'd1–4'd15 are reserved.
See INT-014 for texture memory layout and UNIT-011 (with subunits UNIT-011.01, UNIT-011.03, UNIT-011.06) for index cache and palette LUT architecture.
