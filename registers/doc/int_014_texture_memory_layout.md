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

## Overview

This document specifies the in-memory layout of texture data in GPU SDRAM.
All textures use 4×4 texel blocks as the fundamental storage unit, stored in
left-to-right, top-to-bottom block order.

Supported formats (TEXn_CFG.FORMAT field encoding from INT-010):

| Code | Name     | Bits/texel | Block storage |
|------|----------|------------|---------------|
| 0    | BC1      | 4 bpp      | 8 bytes per 4×4 block |
| 1    | BC2      | 8 bpp      | 16 bytes per 4×4 block |
| 2    | BC3      | 8 bpp      | 16 bytes per 4×4 block |
| 3    | BC4      | 4 bpp      | 8 bytes per 4×4 block (single channel) |
| 4    | RGB565   | 16 bpp     | 32 bytes per 4×4 block |
| 5    | RGBA8888 | 32 bpp     | 64 bytes per 4×4 block |
| 6    | R8       | 8 bpp      | 16 bytes per 4×4 block (single channel) |

All formats share the same block addressing formula; they differ only in bytes-per-block.

---

## Block Organization

**Block order:** Left-to-right, top-to-bottom
**Texel order within block:** Left-to-right, top-to-bottom (row 0 first, row 3 last)

For a 256×256 texture:
- Block grid: 64×64 = 4,096 blocks
- Block 0 contains pixels (0,0) to (3,3)
- Block 1 contains pixels (4,0) to (7,3)
- Block 64 contains pixels (0,4) to (3,7)

**Common address calculation for all formats:**
```
block_x     = pixel_x / 4
block_y     = pixel_y / 4
block_index = block_y * (texture_width / 4) + block_x
block_addr  = texture_base + block_index * bytes_per_block
```

Where `bytes_per_block` is the format-specific value from the table above.

---

## Format 0: BC1 (4 bpp, 8 bytes per 4×4 block)

BC1 block-compressed format.
Opaque (4-color) or 1-bit alpha (3-color + transparent) mode per block.

**Block structure:**
```
Bytes 0-1: color0 (RGB565, little-endian u16)
Bytes 2-3: color1 (RGB565, little-endian u16)
Bytes 4-7: indices (2 bits per texel, 16 texels, little-endian u32)
```

**Color palette generation:**
```
if color0 > color1 (as u16):          // 4-color opaque mode
    palette[0] = decode_rgb565(color0)
    palette[1] = decode_rgb565(color1)
    palette[2] = (2*palette[0] + palette[1]) / 3
    palette[3] = (palette[0] + 2*palette[1]) / 3
    alpha[0..3] = 255
else:                                  // 3-color + transparent mode (1-bit alpha)
    palette[0] = decode_rgb565(color0)
    palette[1] = decode_rgb565(color1)
    palette[2] = (palette[0] + palette[1]) / 2
    palette[3] = RGB(0, 0, 0), alpha = 0
    alpha[0..2] = 255
```

**Index layout (little-endian u32):**
```
Bits [1:0]   = texel[0,0] index
Bits [3:2]   = texel[1,0] index
...
Bits [31:30] = texel[3,3] index
```

**RGB565 channel decode:**
```
R8 = ((rgb565 >> 11) & 0x1F) << 3   // replicate top bit: (val << 3) | (val >> 2)
G8 = ((rgb565 >> 5)  & 0x3F) << 2   // replicate top bits: (val << 2) | (val >> 4)
B8 = (rgb565 & 0x1F) << 3
```

**Size examples:**
- 64×64: 256 blocks × 8 bytes = 2,048 bytes (2 KB)
- 256×256: 4,096 blocks × 8 bytes = 32,768 bytes (32 KB)
- 1024×1024: 65,536 blocks × 8 bytes = 524,288 bytes (512 KB)

---

## Format 1: BC2 (8 bpp, 16 bytes per 4×4 block)

BC2 block-compressed format with explicit 4-bit alpha per texel.

**Block structure:**
```
Bytes 0-7:  alpha data (4 bits per texel, 16 texels, two rows per u32, little-endian)
Bytes 8-15: color block (same as BC1 opaque: color0, color1, indices)
```

**Alpha decode:**
The first 8 bytes store 4-bit alpha for each texel in row-major order.
Each u16 holds one row of 4 texels: bits [3:0] = texel[0], [7:4] = texel[1], [11:8] = texel[2], [15:12] = texel[3].
Expand to 8-bit: `A8 = (A4 << 4) | A4`.

The color block is always decoded in 4-color opaque mode (color0 and color1 comparison is ignored for alpha; only RGB is used).

**Size examples:**
- 64×64: 256 blocks × 16 bytes = 4,096 bytes (4 KB)
- 256×256: 4,096 blocks × 16 bytes = 65,536 bytes (64 KB)
- 1024×1024: 65,536 blocks × 16 bytes = 1,048,576 bytes (1 MB)

---

## Format 2: BC3 (8 bpp, 16 bytes per 4×4 block)

BC3 block-compressed format with interpolated alpha per texel.

**Block structure:**
```
Bytes 0-7:  alpha block (alpha0 u8, alpha1 u8, 6-byte 3-bit index table)
Bytes 8-15: color block (same as BC1 opaque)
```

**Alpha palette generation:**
```
if alpha0 > alpha1:                   // 8-entry interpolated
    palette[0] = alpha0
    palette[1] = alpha1
    palette[2..7] = linear interpolation between alpha0 and alpha1
else:                                 // 6-entry + 0 and 255
    palette[0] = alpha0
    palette[1] = alpha1
    palette[2..5] = linear interpolation between alpha0 and alpha1
    palette[6] = 0
    palette[7] = 255
```

Each texel index is 3 bits; 48 bits = 6 bytes encode all 16 texels.

**Size examples:** Same as BC2 (16 bytes per block).

---

## Format 3: BC4 (4 bpp, 8 bytes per 4×4 block, single channel)

BC4 stores a single channel (red) using the BC3 alpha block encoding.

**Block structure:**
```
Bytes 0-7: red block (red0 u8, red1 u8, 6-byte 3-bit index table — same as BC3 alpha)
```

Decoded output is an 8-bit red value; green and blue are zero; alpha is 255.

**Size examples:** Same as BC1 (8 bytes per block).

---

## Format 4: RGB565 (16 bpp, 32 bytes per 4×4 block)

Uncompressed format. Each texel is one 16-bit RGB565 value, little-endian.

**Bit layout per texel:**
```
[15:11] R (5 bits)
[10:5]  G (6 bits)
[4:0]   B (5 bits)
```
Alpha is implicitly 255 (fully opaque).

**4×4 block memory layout (32 bytes):**
```
Offset | Data
-------|------------------------------------
+0     | Texel[0,0] RGB565 (2 bytes, little-endian u16)
+2     | Texel[1,0]
+4     | Texel[2,0]
+6     | Texel[3,0]
+8     | Texel[0,1]
...
+30    | Texel[3,3]
```

**Decoding to 8-bit channels:**
```
R8 = (R5 << 3) | (R5 >> 2)   // 5 bits → 8 bits, replicate top bits
G8 = (G6 << 2) | (G6 >> 4)   // 6 bits → 8 bits
B8 = (B5 << 3) | (B5 >> 2)
A8 = 255
```

**Size examples:**
- 64×64: 256 blocks × 32 bytes = 8,192 bytes (8 KB)
- 256×256: 4,096 blocks × 32 bytes = 131,072 bytes (128 KB)
- 1024×1024: 65,536 blocks × 32 bytes = 2,097,152 bytes (2 MB)

---

## Format 5: RGBA8888 (32 bpp, 64 bytes per 4×4 block)

Uncompressed format. Each texel is one 32-bit RGBA8888 value, little-endian.

**Bit layout per texel:**
```
[31:24] A (8 bits)
[23:16] B (8 bits)
[15:8]  G (8 bits)
[7:0]   R (8 bits)
```

**4×4 block memory layout (64 bytes):** Row-major, 4 bytes per texel.

**Decoding:** Direct; no expansion needed. Values are UNORM8.

**Size examples:**
- 64×64: 256 blocks × 64 bytes = 16,384 bytes (16 KB)
- 256×256: 4,096 blocks × 64 bytes = 262,144 bytes (256 KB)
- 1024×1024: 65,536 blocks × 64 bytes = 4,194,304 bytes (4 MB)

Note: RGBA8888 is too large for practical use at 1024×1024 (4 MB exceeds the texture SDRAM region).
Use BC3 for high-quality textures with full alpha; use RGB565 for opaque surfaces.

---

## Format 6: R8 (8 bpp, 16 bytes per 4×4 block, single channel)

Uncompressed single-channel format. Each texel is one unsigned 8-bit value.

**4×4 block memory layout (16 bytes):** Row-major, 1 byte per texel.

**Decoding:** Red channel = stored byte (UNORM8); green and blue are zero; alpha is 255.
Apply a swizzle (e.g., RRR1) to replicate to RGB for grayscale output (see INT-010 TEXn_CFG.SWIZZLE).

**Size examples:**
- 64×64: 256 blocks × 16 bytes = 4,096 bytes (4 KB)
- 256×256: 4,096 blocks × 16 bytes = 65,536 bytes (64 KB)
- 1024×1024: 65,536 blocks × 16 bytes = 1,048,576 bytes (1 MB)

---

## Format 0 (Legacy): RGBA4444 — Removed

RGBA4444 is no longer a supported texture format.
Assets previously using RGBA4444 should be converted to RGB565 (for opaque data) or BC1/BC2/BC3 (for compressed data).

---

## Texture Alignment Requirements

All formats:
- Base address: 512-byte aligned (required by TEXn_CFG.BASE_ADDR × 512 encoding)

Block-compressed formats (BC1, BC2, BC3, BC4):
- Texture width and height: **must be multiples of 4** (BC block size)
  - Valid: 64×64, 256×256, 128×512, 1024×256
  - Invalid: 65×65, 100×100, 127×127

Uncompressed formats (RGB565, RGBA8888, R8):
- Texture width and height: must be power-of-two (8 to 1024)
- No minimum multiple-of-4 restriction beyond power-of-two

---

## Swizzle Pattern Application

Swizzle patterns (defined in INT-010 GPU Register Map, TEXn_CFG.SWIZZLE field, n=0,1)
are applied **after texture decode**, before the color combiner stage.

Process:
1. Decode texture to RGBA8 (format-specific, see sections above)
2. Apply swizzle pattern (reorder/replicate channels)
3. Pass to color combiner as TEX_COLOR0 or TEX_COLOR1 (see INT-010 CC_MODE register)

See INT-010 for swizzle pattern encoding (16 predefined patterns).

The R8 and BC4 formats produce a single meaningful channel (red = stored value, G=0, B=0, A=255).
Apply RRR1 swizzle to produce a grayscale RGBA output.

---

## Maximum Texture Sizes

Given SDRAM constraints (INT-011: texture region):

| Format   | 256×256 | 512×512 | 1024×1024 |
|----------|---------|---------|-----------|
| BC1      | 32 KB   | 128 KB  | 512 KB    |
| BC2/BC3  | 64 KB   | 256 KB  | 1 MB      |
| BC4      | 32 KB   | 128 KB  | 512 KB    |
| RGB565   | 128 KB  | 512 KB  | 2 MB      |
| RGBA8888 | 256 KB  | 1 MB    | 4 MB      |
| R8       | 64 KB   | 256 KB  | 1 MB      |

**Recommendation:**
- Use BC1 for opaque surfaces (best compression, 4 bpp)
- Use BC3 for surfaces requiring smooth alpha (8 bpp)
- Use BC4/R8 for single-channel data (heightmaps, AO maps)
- Use RGB565 only for small textures or when BC1 quality is insufficient
- Avoid RGBA8888 above 256×256 due to memory cost

---

## Mipmap Chain Organization

### Overview

Textures may include a mipmap chain: the base level plus progressively downsampled levels.
Mipmaps improve visual quality by reducing aliasing and improve texture cache performance.

**Mipmap levels**: Base (level 0) + N additional levels, where each level dimension = max(prev_dimension / 2, minimum_dimension)

**Minimum dimension:**
- BC formats (BC1, BC2, BC3, BC4): 4 pixels (minimum BC block size)
- Uncompressed formats (RGB565, RGBA8888, R8): 1 pixel

### Memory Layout

Mipmaps are stored **sequentially** in memory, starting with the base level.

**Layout for 256×256 BC1 texture (7 mipmap levels, down to 4×4):**
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
---------------|-------|------------|------------|-------------
Total size: 43,688 bytes (42.7 KB)
Memory overhead: +33.3%
```

**Note:** BC1/BC4 blocks are always 8 bytes minimum; BC2/BC3 blocks are always 16 bytes minimum.
Levels smaller than 4×4 are padded to one full block.

### Address Calculation

**Mipmap level address:**
```
mip_address[0] = texture_base        // Base level

For i > 0:
  mip_address[i] = mip_address[i-1] + size_of_level(i-1)
```

**Level size calculation:**
```
width_at_level(i)  = max(base_width  >> i, min_dim)
height_at_level(i) = max(base_height >> i, min_dim)

For BC formats:
  min_dim = 4
  block_w = max(width_at_level(i) / 4, 1)
  block_h = max(height_at_level(i) / 4, 1)
  size_of_level(i) = block_w * block_h * bytes_per_block

For uncompressed formats:
  min_dim = 1
  size_of_level(i) = width_at_level(i) * height_at_level(i) * bytes_per_texel
```

### Size Examples

**BC1 with full mipmap chain:**

| Base Size | Levels | Base Size | Mipmap Chain Size | Overhead |
|-----------|--------|-----------|-------------------|----------|
| 64×64     | 5      | 2 KB      | 2.7 KB            | +33.3%   |
| 256×256   | 7      | 32 KB     | 42.7 KB           | +33.3%   |
| 512×512   | 8      | 128 KB    | 170.7 KB          | +33.3%   |
| 1024×1024 | 9      | 512 KB    | 682.7 KB          | +33.3%   |

**RGB565 with full mipmap chain:**

| Base Size | Levels | Base Size | Mipmap Chain Size | Overhead |
|-----------|--------|-----------|-------------------|----------|
| 64×64     | 7      | 8 KB      | 10.7 KB           | +33.3%   |
| 256×256   | 9      | 128 KB    | 170.7 KB          | +33.3%   |
| 512×512   | 10     | 512 KB    | 682.7 KB          | +33.3%   |

**Memory overhead is consistent at ~33% for all formats with full mipmap chains.**

### Alignment

Mipmap chains do not require additional alignment beyond the 512-byte alignment required for TEXn_CFG.BASE_ADDR.
The base level must be 512-byte aligned; subsequent levels are stored sequentially with no padding.

### Partial Mipmap Chains

Textures may include fewer than the maximum mipmap levels.
The GPU clamps LOD selection to [0, MIP_LEVELS−1].

### GPU Addressing

The pixel pipeline calculates the mipmap level address using a cumulative offset table:

**Hardware implementation** (UNIT-006):
```systemverilog
// Precomputed offset table based on TEXn_CFG fields
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
- BC-family textures must have dimensions that are multiples of 4
- Base address must be 512-byte aligned (TEXn_CFG.BASE_ADDR × 512)

## Texture Cache Considerations (REQ-003.08)

The pixel pipeline uses an on-chip texture cache (REQ-003.08) with 2 independent per-sampler caches to reduce SDRAM bandwidth.
Each sampler cache holds 16,384 texels in a 4-way set-associative configuration with 256 sets.
The cache uses **XOR-folded set indexing** for efficient distribution of spatially adjacent blocks:

```
set = (block_x[7:0] ^ block_y[7:0])  // 256 sets
```

This is a **hardware-only optimization** — the physical memory layout in SDRAM is unchanged.
Textures remain stored in linear left-to-right, top-to-bottom block order as specified above.
The XOR indexing prevents systematic cache aliasing where vertically adjacent block rows would map to the same cache sets under linear indexing.

**Note:** The 16K-texel cache per sampler significantly reduces cache thrashing for 256×256 and larger textures.
The cache can hold the equivalent of a 128×128 texel working set per sampler.
