# INT-014: Texture Memory Layout

## Type

Internal

## Parties

- **Provider:** External (host firmware defines layout)
- **Consumer:** UNIT-006 (Pixel Pipeline)
- **Consumer:** UNIT-030 (PNG Decoder - generates layout)
- **Consumer:** UNIT-033 (Codegen Engine - generates layout)

## Referenced By

- REQ-006 (Textured Triangle)
- REQ-008 (Multi-Texture Rendering)
- REQ-010 (Compressed Textures)
- REQ-011 (Swizzle Patterns)
- REQ-024 (Texture Sampling)
- INT-011 (SRAM Memory Layout - overall memory allocation)

## Specification

**Version**: 1.0
**Date**: February 2026

---

## Overview

This document specifies the in-memory layout of texture data in GPU SRAM.
All textures are organized into 4x4 texel blocks, stored in left-to-right,
top-to-bottom order.

Supported formats:
- **RGBA4444**: 16 bits per pixel (4 bits per channel)
- **BC1**: Block-compressed, 64 bits per 4x4 block (0.5 bytes per pixel)

---

## Block Organization

All textures use 4x4 texel blocks as the fundamental storage unit.

**Block order:** Left-to-right, top-to-bottom
**Texel order within block:** Left-to-right, top-to-bottom

For a 256x256 texture:
- Block grid: 64x64 = 4,096 blocks
- Block 0 contains pixels (0,0) to (3,3)
- Block 1 contains pixels (4,0) to (7,3)
- Block 64 contains pixels (0,4) to (3,7)

---

## Format 1: RGBA4444 (16 bits per pixel)

**Encoding:** Each pixel packed into 16 bits

Bit layout (little-endian):
```
[15:12] R (4 bits) - Red channel
[11:8]  G (4 bits) - Green channel
[7:4]   B (4 bits) - Blue channel
[3:0]   A (4 bits) - Alpha channel
```

**Memory layout for 4x4 block (32 bytes):**
```
Offset  | Data
--------|------------------
+0      | Pixel[0,0] RGBA4444 (2 bytes, little-endian u16)
+2      | Pixel[1,0] RGBA4444 (2 bytes)
+4      | Pixel[2,0] RGBA4444 (2 bytes)
+6      | Pixel[3,0] RGBA4444 (2 bytes)
+8      | Pixel[0,1] RGBA4444 (2 bytes)
+10     | Pixel[1,1] RGBA4444 (2 bytes)
...
+30     | Pixel[3,3] RGBA4444 (2 bytes)
```

**Decoding to 8-bit channels:**
```
R8 = (R4 << 4) | R4  // Replicate high bits: 0xF -> 0xFF
G8 = (G4 << 4) | G4
B8 = (B4 << 4) | B4
A8 = (A4 << 4) | A4
```

**Address calculation:**
```
block_x = pixel_x / 4
block_y = pixel_y / 4
block_index = block_y * (texture_width / 4) + block_x

texel_x = pixel_x % 4
texel_y = pixel_y % 4
texel_offset = texel_y * 4 + texel_x

pixel_addr = texture_base + block_index * 32 + texel_offset * 2
```

**Size examples:**
- 64x64: 16x16 blocks = 256 blocks x 32 bytes = 8,192 bytes (8 KB)
- 256x256: 64x64 blocks = 4,096 blocks x 32 bytes = 131,072 bytes (128 KB)
- 1024x1024: 256x256 blocks = 65,536 blocks x 32 bytes = 2,097,152 bytes (2 MB)

---

## Format 2: BC1 Block Compression (64 bits per 4x4 block)

**BC1 format:** Each 4x4 block compressed into 64 bits (8 bytes)

Block structure:
```
Bytes 0-1: color0 (RGB565, little-endian u16)
Bytes 2-3: color1 (RGB565, little-endian u16)
Bytes 4-7: indices (2 bits per pixel, 32 bits total)
```

**Color palette generation:**
```
If color0 > color1 (as u16):
  palette[0] = color0
  palette[1] = color1
  palette[2] = (2*color0 + color1) / 3  // Interpolate
  palette[3] = (color0 + 2*color1) / 3  // Interpolate
  alpha = 255 for all

Else (color0 <= color1):
  palette[0] = color0
  palette[1] = color1
  palette[2] = (color0 + color1) / 2    // Interpolate
  palette[3] = RGB(0,0,0), alpha=0      // Transparent black (1-bit alpha)
```

**Index decoding:**
Indices stored as 2 bits per pixel, 16 pixels total (32 bits).

Bit layout (little-endian u32):
```
Bits [1:0]   = pixel[0,0] index
Bits [3:2]   = pixel[1,0] index
...
Bits [31:30] = pixel[3,3] index
```

**Memory layout for 4x4 block (8 bytes):**
```
Offset | Data
-------|------------------
+0     | color0 RGB565 (2 bytes, little-endian)
+2     | color1 RGB565 (2 bytes, little-endian)
+4     | indices (4 bytes, little-endian u32)
```

**Address calculation:**
```
block_x = pixel_x / 4
block_y = pixel_y / 4
block_index = block_y * (texture_width / 4) + block_x

block_addr = texture_base + block_index * 8
```

**Size examples:**
- 64x64: 16x16 blocks = 256 blocks x 8 bytes = 2,048 bytes (2 KB)
- 256x256: 64x64 blocks = 4,096 blocks x 8 bytes = 32,768 bytes (32 KB)
- 1024x1024: 256x256 blocks = 65,536 blocks x 8 bytes = 524,288 bytes (512 KB)

---

## Texture Alignment Requirements

**RGBA4444:**
- Base address: 4K aligned (required by TEXn_BASE register)
- No additional alignment required

**BC1:**
- Base address: 4K aligned (required by TEXn_BASE register)
- Texture width and height: **MUST be multiples of 4**
  - Valid: 64x64, 256x256, 128x512, 1024x256
  - Invalid: 65x65, 100x100, 127x127

---

## Swizzle Pattern Application

Swizzle patterns (defined in INT-010 GPU Register Map, TEXn_FMT.SWIZZLE field)
are applied **after texture decode**, before blending.

Process:
1. Decode texture to RGBA8 (from RGBA4444 or BC1)
2. Apply swizzle pattern (reorder/replicate channels)
3. Apply texture blend modes
4. Multiply by vertex color (if Gouraud shading enabled)

See INT-010 for swizzle pattern encoding (16 predefined patterns).

---

## Maximum Texture Sizes

Given SRAM constraints (INT-011: 768 KB texture region):

**RGBA4444:**
- 1024x1024 = 2 MB (does not fit in default region)
- 512x512 = 512 KB (1 texture fits)
- 256x256 = 128 KB (6 textures fit)

**BC1:**
- 1024x1024 = 512 KB (1 texture fits)
- 512x512 = 128 KB (6 textures fit)
- 256x256 = 32 KB (24 textures fit)

**Recommendation:** Use BC1 for static textures (environment, lightmaps),
RGBA4444 for dynamic textures (animated, frequently updated).

---

## Migration from RGBA8888

**Breaking change:** This specification replaces RGBA8888 (32 bits per pixel)
and 8-bit indexed compression formats.

**Conversion:**
- RGBA8888 -> RGBA4444: Quantize each 8-bit channel to 4 bits (value >> 4)
- RGBA8888 -> BC1: Use BC1 encoder (see UNIT-030)

All existing assets must be regenerated.

## Constraints

- All textures must use power-of-2 dimensions (8 to 1024)
- BC1 textures must have dimensions that are multiples of 4
- Base address must be 4K aligned

## Notes

Created as part of texture format migration (RGBA8888/Indexed -> RGBA4444/BC1).
See design_decisions.md for format selection rationale.
