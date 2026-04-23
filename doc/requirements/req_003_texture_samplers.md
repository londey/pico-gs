# REQ-003: Texture Samplers

## Requirement

The system SHALL sample, decode, and deliver texture data to the pixel pipeline, supporting multiple texture formats, dual-texture rendering, channel swizzling, UV wrapping, mipmapping, and per-sampler caching.

## Rationale

The texture samplers area groups all requirements related to reading texture memory, decoding compressed and uncompressed formats, applying addressing modes, and feeding texel data to the color combiner.

## Parent Requirements

None (top-level area)

## Interfaces

- INT-010 (GPU Register Map)
- INT-014 (Texture Memory Layout)

## Design Allocation

UNIT-011 (Texture Sampler)

## Verification Method

**Inspection:** Verify that UNIT-011 instantiates texture cache and all format decoders (BC1, BC2, BC3, BC4, BC5, RGB565, RGBA8888, R8) connected via a 4-bit format-select mux.
Child requirements REQ-003.01 through REQ-003.08 carry individual Test-level verification via VER-005 (texture decoder) and VER-012/VER-014 (textured golden image tests).

## Notes

All eight texture format decoders are wired to the texture cache in UNIT-011 through a 4-bit `tex_format` select (see UNIT-011.04 and INT-010 for the encoding).
See INT-014 for texture memory layout and UNIT-011 (with subunits UNIT-011.03, UNIT-011.04, UNIT-011.05) for cache architecture and per-format burst lengths.
