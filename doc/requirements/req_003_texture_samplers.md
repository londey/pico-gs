# REQ-003: Texture Samplers

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Inspection

## Requirement

The system SHALL sample, decode, and deliver texture data to the pixel pipeline, supporting multiple texture formats, dual-texture rendering, channel swizzling, UV wrapping, mipmapping, and per-sampler caching.

## Rationale

The texture samplers area groups all requirements related to reading texture memory, decoding compressed and uncompressed formats, applying addressing modes, and feeding texel data to the color combiner.

## Parent Requirements

None (top-level area)

## Child Requirements

- REQ-003.01 (Textured Triangle)
- REQ-003.02 (Multi-Texture Rendering)
- REQ-003.03 (Compressed Textures)
- REQ-003.04 (Swizzle Patterns)
- REQ-003.05 (UV Wrapping Modes)
- REQ-003.06 (Texture Sampling)
- REQ-003.07 (Texture Mipmapping)
- REQ-003.08 (Texture Cache)

## Allocated To

- UNIT-006 (Pixel Pipeline)

## Interfaces

- INT-010 (GPU Register Map)
- INT-014 (Texture Memory Layout)
- INT-032 (Texture Cache Architecture)

## Verification Method

**Inspection:** Verify that UNIT-006 instantiates texture cache and all format decoders (BC1, BC2, BC3, BC4, RGBA4444, RGB565, RGBA8888, R8) connected via a format-select mux.
Child requirements REQ-003.01 through REQ-003.08 carry individual Test-level verification via VER-005 (texture decoder) and VER-012/VER-014 (textured golden image tests).

## Notes

This is one of 13 top-level requirement areas organizing the specification hierarchy.
All seven texture format decoders are wired to the texture cache in UNIT-006 through a 3-bit `tex_format` select (INT-032).
See INT-014 for texture memory layout and INT-032 for cache architecture and per-format burst lengths.
