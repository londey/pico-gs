# INT-014: Texture Memory Layout

## Type

Internal

## Parties

- **Provider:** External (host firmware defines layout)
- **Consumer:** UNIT-006 (Pixel Pipeline)
- **Consumer:** UNIT-030 (PNG Decoder - generates layout)
- **Consumer:** UNIT-033 (Codegen Engine - generates layout)

## Referenced By

- REQ-003 (Texture Samplers — top-level area 3 requirement, not yet created)
- REQ-003.01 (Textured Triangle — sub-requirement under area 3)
- REQ-003.02 (Multi-Texture Rendering — sub-requirement under area 3)
- REQ-003.03 (Compressed Textures — sub-requirement under area 3)
- REQ-003.04 (Swizzle Patterns — sub-requirement under area 3)
- REQ-003.06 (Texture Sampling — sub-requirement under area 3)
- INT-011 (SDRAM Memory Layout - overall memory allocation)
- REQ-003.08 (Texture Cache — sub-requirement under area 3)

## Specification

**Version**: 1.0
**Date**: February 2026

---

## Overview

This document specifies the in-memory layout of texture data in GPU SDRAM.
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

Swizzle patterns (defined in INT-010 GPU Register Map, TEXn_FMT.SWIZZLE field, n=0,1)
are applied **after texture decode**, before the color combiner stage.

Process:
1. Decode texture to RGBA8 (from RGBA4444 or BC1)
2. Apply swizzle pattern (reorder/replicate channels)
3. Pass to color combiner as TEX_COLOR0 or TEX_COLOR1 (see INT-010 CC_MODE register)

See INT-010 for swizzle pattern encoding (16 predefined patterns).

---

## Maximum Texture Sizes

Given SDRAM constraints (INT-011: 768 KB texture region):

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

---

## Mipmap Chain Organization

**Version**: Added in v2.0 (Mipmap Support)

### Overview

Textures may include a mipmap chain: the base level plus progressively downsampled levels. Mipmaps improve visual quality by reducing aliasing and improving texture cache performance.

**Mipmap levels**: Base (level 0) + N additional levels, where each level dimension = max(prev_dimension / 2, minimum_dimension)

**Minimum dimension**:
- RGBA4444: 1 pixel
- BC1: 4 pixels (minimum BC1 block size)

### Memory Layout

Mipmaps are stored **sequentially** in memory, starting with the base level.

**Layout for 256×256 BC1 texture (9 levels)**:
```
Address Offset | Level | Dimensions | Block Grid | Size (bytes)
---------------|-------|------------|------------|-------------
+0x0000        | 0     | 256×256    | 64×64      | 32,768
+0x8000        | 1     | 128×128    | 32×32      | 8,192
+0xA000        | 2     | 64×64      | 16×16      | 2,048
+0xA800        | 3     | 32×32      | 8×8        | 512
+0xAA00        | 4     | 16×16      | 4×4        | 128
+0xAA80        | 5     | 8×8        | 2×2        | 32
+0xAAA0        | 6     | 4×4        | 1×1        | 8
+0xAAA8        | 7     | 2×2        | 1×1        | 8 (min block)
+0xAAB0        | 8     | 1×1        | 1×1        | 8 (min block)
---------------|-------|------------|------------|-------------
Total size: 43,704 bytes (42.7 KB) vs 32,768 bytes (32 KB) for base only
Memory overhead: +33.6%
```

**Note**: BC1 blocks are always 8 bytes minimum, so levels smaller than 4×4 still occupy one full block.

### Address Calculation

**Mipmap level address:**
```
mip_address[0] = texture_base  // Base level

For i > 0:
  mip_address[i] = mip_address[i-1] + size_of_level(i-1)
```

**Level size calculation:**
```
width_at_level(i)  = max(base_width >> i, min_width)
height_at_level(i) = max(base_height >> i, min_height)

For RGBA4444:
  min_width = 1, min_height = 1
  size_of_level(i) = width_at_level(i) * height_at_level(i) * 2 bytes

For BC1:
  min_width = 4, min_height = 4
  block_width  = max(width_at_level(i) / 4, 1)
  block_height = max(height_at_level(i) / 4, 1)
  size_of_level(i) = block_width * block_height * 8 bytes
```

### Size Examples

**RGBA4444 with full mipmap chain:**

| Base Size | Levels | Base Size | Mipmap Chain Size | Overhead |
|-----------|--------|-----------|-------------------|----------|
| 64×64     | 7      | 8 KB      | 10.7 KB           | +33.3%   |
| 256×256   | 9      | 128 KB    | 170.7 KB          | +33.3%   |
| 512×512   | 10     | 512 KB    | 682.7 KB          | +33.3%   |

**BC1 with full mipmap chain:**

| Base Size | Levels | Base Size | Mipmap Chain Size | Overhead |
|-----------|--------|-----------|-------------------|----------|
| 64×64     | 5      | 2 KB      | 2.7 KB            | +33.3%   |
| 256×256   | 7      | 32 KB     | 42.7 KB           | +33.3%   |
| 512×512   | 8      | 128 KB    | 170.7 KB          | +33.3%   |
| 1024×1024 | 9      | 512 KB    | 682.7 KB          | +33.3%   |

**Memory overhead is consistent at ~33% for full mipmap chains.**

### Alignment

Mipmap chains do not require additional alignment beyond the 4K alignment required for TEXn_BASE. The base level must be 4K aligned; subsequent levels are stored sequentially with no padding.

### Partial Mipmap Chains

Textures may include fewer than the maximum mipmap levels. For example, a 256×256 texture could have:
- MIP_LEVELS=1: Base only (32 KB)
- MIP_LEVELS=5: Base + 4 mips (256→128→64→32→16, total ~42 KB)
- MIP_LEVELS=9: Full chain down to 1×1 (total ~43 KB)

The GPU will clamp LOD selection to [0, MIP_LEVELS-1].

### GPU Addressing

The pixel pipeline calculates the mipmap level address using a cumulative offset table:

**Hardware implementation** (UNIT-006):
```systemverilog
// Precomputed offset table based on TEXn_FMT fields
logic [31:0] mip_offsets[0:10];  // Up to 11 levels

always_comb begin
    mip_offsets[0] = 0;
    for (int i = 1; i < mip_levels; i++) begin
        mip_offsets[i] = mip_offsets[i-1] +
                         calculate_level_size(width_log2, height_log2, i-1, format);
    end
end

// Select mipmap level
mip_base_addr = texture_base + mip_offsets[selected_mip];
```

---

## Constraints

- All textures must use power-of-2 dimensions (8 to 1024)
- BC1 textures must have dimensions that are multiples of 4
- Base address must be 4K aligned

## Texture Cache Considerations (REQ-003.08)

The pixel pipeline uses an on-chip texture cache (REQ-003.08) with 2 independent per-sampler caches (v10.0: reduced from 4 samplers) to reduce SDRAM bandwidth.
Each sampler cache holds 16,384 texels (v10.0: increased from 4,096) in a 4-way set-associative configuration with 256 sets.
The cache uses **XOR-folded set indexing** for efficient distribution of spatially adjacent blocks:

```
set = (block_x[7:0] ^ block_y[7:0])  // 256 sets (v10.0: increased from 64)
```

This is a **hardware-only optimization** — the physical memory layout in SDRAM is unchanged. Textures remain stored in linear left-to-right, top-to-bottom block order as specified above. The XOR indexing prevents systematic cache aliasing where vertically adjacent block rows would map to the same cache sets under linear indexing.

**Note**: The larger 16K-texel cache per sampler significantly reduces cache thrashing for 256×256 and larger textures, as the cache can hold the equivalent of a 128×128 texel working set per sampler.

## Notes

Created as part of texture format migration (RGBA8888/Indexed -> RGBA4444/BC1).
See design_decisions.md for format selection rationale.
