# INT-014: Texture Memory Layout

**Moved to `registers/doc/int_014_texture_memory_layout.md`** — managed outside syskit as part of the register interface.

## External Consumer

The host-side producer of texture data in this layout (PNG decoding, format conversion, SDRAM upload sequencing) is implemented in the pico-racer application repository (https://github.com/londey/pico-racer).
The GPU-side consumers of this layout (UNIT-006 texture cache, Verilator test harnesses VER-012 and VER-014) remain in this repo.
