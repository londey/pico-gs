# INT-014: Texture Memory Layout

**Moved to `registers/doc/int_014_texture_memory_layout.md`** — managed outside syskit as part of the register interface.

## External Consumer

The host-side producer of texture data in this layout (PNG decoding, format conversion, SDRAM upload sequencing) is implemented in the pico-racer application repository (https://github.com/londey/pico-racer).
The GPU-side consumers of this layout (UNIT-006 texture cache, Verilator test harnesses VER-012 and VER-014) remain in this repo.

## Referenced By

Full cross-references are maintained in `registers/doc/int_014_texture_memory_layout.md`.
Key GPU requirement areas that depend on this interface:

- REQ-003.01 (Texture Addressing) — Area 3: Texture Samplers
- REQ-003.02 (Texture Sampler Count) — Area 3: Texture Samplers
- REQ-003.03 (Texture Format Support) — Area 3: Texture Samplers
- REQ-003.04 (Texture Filtering) — Area 3: Texture Samplers
- REQ-003.05 (Texture Wrapping) — Area 3: Texture Samplers
- REQ-003.06 (Texture Sampling) — Area 3: Texture Samplers
- REQ-003.07 (Texture Mipmapping) — Area 3: Texture Samplers
- REQ-003.08 (Texture Cache) — Area 3: Texture Samplers
- REQ-003 (Texture Samplers)
