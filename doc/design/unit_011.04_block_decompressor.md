# UNIT-011.04: Block Decompressor

Status: Deleted.

This design unit has been removed as part of the INDEXED8_2X2 texture architecture (see UNIT-011).
All BC1–BC4, RGB565, RGBA8888, and R8 format decoders and the `texel_promote` helper are no longer part of the texture pipeline.
Palette index promotion from UQ1.8 to Q4.12 is now performed inside UNIT-011.06 (Palette LUT).
