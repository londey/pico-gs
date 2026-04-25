# INT-014: Texture Memory Layout

## Type

Internal

## Specification

## Overview

This document specifies the in-memory layout of texture data in GPU SDRAM.
The GPU supports a single texture format: `INDEXED8_2X2`.
Each texture is stored as two distinct payloads:

1. **Index array** — 4×4 block-tiled array of 8-bit palette indices, addressed via `TEXn_CFG.BASE_ADDR`.
2. **Palette payload** — separately loaded into one of the two on-chip palette slots (UNIT-011.06) via `PALETTEn.BASE_ADDR` and `PALETTEn.LOAD_TRIGGER` (see INT-010).

Sole supported format (`TEXn_CFG.FORMAT` field encoding from INT-010):

| Code  | Name          | Bits per index | Index block storage             | Apparent coverage |
|-------|---------------|----------------|---------------------------------|-------------------|
| 4'd0  | INDEXED8_2X2  | 8 bpi          | 16 bytes per 4×4 index block    | 8×8 apparent texels per block |
| 4'd1–4'd15 | (Reserved) | —             | —                               | —                 |

The 4-bit FORMAT field is retained for ABI stability (see DD-042); only code `4'd0` is valid.

---

## INDEXED8_2X2 Index Array Layout

### Apparent vs. index resolution

INDEXED8_2X2 stores **one 8-bit palette index per 2×2 apparent-texel tile**.
The apparent texture dimensions (configured via `TEXn_CFG.WIDTH_LOG2`, `HEIGHT_LOG2`) describe the perceived surface.
The underlying index array has half the apparent resolution per axis.

```
index_width  = apparent_width  / 2 = 1 << (WIDTH_LOG2  - 1)
index_height = apparent_height / 2 = 1 << (HEIGHT_LOG2 - 1)
```

Sampling derives the active palette quadrant from the wrapped UV low bits:

```
quadrant[1:0] = {v_wrapped[0], u_wrapped[0]}
                                          // 00 = NW, 01 = NE, 10 = SW, 11 = SE
```

The index array address uses `(u_wrapped >> 1, v_wrapped >> 1)`.

### Block organization

The index array uses a 4×4 block-tiled layout: each block contains 16 indices arranged in row-major order, and blocks themselves are arranged in row-major order across the index grid.
Each 4×4 index block therefore covers an **8×8 apparent-texel** region.

For an apparent-pixel position `(ap_x, ap_y)`:

```
idx_x       = ap_x >> 1
idx_y       = ap_y >> 1
block_x     = idx_x >> 2                          // 4 indices wide per block
block_y     = idx_y >> 2
local_x     = idx_x & 3
local_y     = idx_y & 3
block_index = block_y * (index_width / 4) + block_x
byte_offset = texture_base
            + block_index * 16
            + (local_y * 4 + local_x)             // 1 byte per index
quadrant    = {ap_y[0], ap_x[0]}
```

`bytes_per_index_block = 16` (16 indices × 1 byte each).

### Minimum and maximum sizes

- Minimum apparent texture: **2×2** (`WIDTH_LOG2 ≥ 1`, `HEIGHT_LOG2 ≥ 1`); index array degenerates to a single index that is then expanded by quadrant lookup into a 2×2 patch.
- Maximum apparent texture: 1024×1024 (`WIDTH_LOG2`, `HEIGHT_LOG2` ≤ 10).
- Apparent dimensions must be power-of-two.
- Index arrays whose `index_width` is less than 4 (i.e. apparent width less than 8) are padded to a single full 4×4 index block.

### Size examples

| Apparent size | Index grid    | Index block grid | Total index bytes |
|---------------|---------------|-------------------|-------------------|
| 2×2           | 1×1           | 1×1               | 16                |
| 64×64         | 32×32         | 8×8               | 1,024             |
| 256×256       | 128×128       | 32×32             | 16,384            |
| 1024×1024     | 512×512       | 128×128           | 262,144           |

### Alignment

Index array base address must be 512-byte aligned (required by `TEXn_CFG.BASE_ADDR × 512` encoding).

### MIRROR wrap mode interaction

When `TEXn_CFG.U_WRAP` or `V_WRAP` is `MIRROR`, wrapping is computed on the full apparent (u, v) coordinates before the quadrant split.
The mirrored low bit becomes the quadrant selector naturally; mirrored tiles swap NE↔NW (for u-mirror) or SE↔SW (for v-mirror).

---

## Palette Payload Layout

Each palette slot resident in UNIT-011.06 holds 256 entries × 4 quadrant colors × 4 channels (UQ1.8 RGBA).
The SDRAM payload format used during `PALETTEn` load is **256 entries × 4 RGBA8888 colors per entry = 4096 bytes**, promoted inline to UQ1.8 by the load FSM (`UQ1.8 = UNORM8 << 1`).

### Per-entry layout (16 bytes)

For each 8-bit palette index `i`, the payload stores 4 RGBA8888 colors in NW/NE/SW/SE order, little-endian, with R at the lowest byte:

```
Offset (bytes)       | Field
---------------------|------------------------------------------
i*16 + 0             | NW.R  (UNORM8)
i*16 + 1             | NW.G  (UNORM8)
i*16 + 2             | NW.B  (UNORM8)
i*16 + 3             | NW.A  (UNORM8)
i*16 + 4             | NE.R
i*16 + 5             | NE.G
i*16 + 6             | NE.B
i*16 + 7             | NE.A
i*16 + 8             | SW.R
i*16 + 9             | SW.G
i*16 + 10            | SW.B
i*16 + 11            | SW.A
i*16 + 12            | SE.R
i*16 + 13            | SE.G
i*16 + 14            | SE.B
i*16 + 15            | SE.A
```

### Total payload size

```
4 quadrants/entry × 4 bytes/quadrant × 256 entries = 4096 bytes (2048 × 16-bit SDRAM words)
```

### Alignment

Palette payload base address must be 512-byte aligned (required by `PALETTEn.BASE_ADDR × 512` encoding).

### Promotion during load

For each RGBA8888 byte fetched from SDRAM, the load FSM produces a 9-bit UQ1.8 value:

```
uq18_channel = {1'b0, unorm8_byte}        // equivalent to (UNORM8 << 1) >> 1, 9-bit, top bit always 0
```

Stored on-chip as 4 channels × 9 bits = 36 bits per quadrant color, addressed by `{slot[0], idx[7:0], quadrant[1:0]}`.

---

## Texture Alignment Requirements

- Apparent texture width and height must be power-of-two, between 2 and 1024.
- Index array base address (`TEXn_CFG.BASE_ADDR`): 512-byte aligned.
- Palette payload base address (`PALETTEn.BASE_ADDR`): 512-byte aligned.

---

## Swizzle Pattern Application

Swizzle patterns (defined in INT-010, `TEXn_CFG.SWIZZLE` field, n=0,1) are applied **after palette lookup**, before the color combiner stage.

Process:
1. Resolve apparent UV → index-grid (idx_x, idx_y) + quadrant.
2. Fetch 8-bit palette index from the index array (via UNIT-011.03 cache).
3. Look up RGBA UQ1.8 from the palette LUT (UNIT-011.06) at `{slot, index, quadrant}`.
4. Apply swizzle pattern (reorder/replicate channels).
5. Promote UQ1.8 → Q4.12 and pass to the color combiner as `TEX_COLOR0` or `TEX_COLOR1` (see INT-010 CC_MODE register).

See INT-010 for swizzle pattern encoding (16 predefined patterns).

---

## Maximum Texture Sizes

Given SDRAM constraints (INT-011: texture region):

| Apparent size | Index bytes | Palette payload (each slot) |
|---------------|-------------|------------------------------|
| 256×256       | 16 KB       | 4 KB                         |
| 512×512       | 64 KB       | 4 KB                         |
| 1024×1024     | 256 KB      | 4 KB                         |

Two palette slots = 8 KB total of resident palette storage.

---

## Mipmaps

Not supported.
The pipeline does not select between mip levels and the `frag_lod` value emitted by the rasterizer (UNIT-005) is no longer consumed by UNIT-011.

---

## Texture Cache Considerations (REQ-003.08)

UNIT-011 (Texture Sampler) uses an on-chip per-sampler index cache (UNIT-011.03) to reduce SDRAM bandwidth for repeated index fetches.
The cache uses **XOR-folded set indexing** for efficient distribution of spatially adjacent index blocks:

```
set = (block_x[4:0] ^ block_y[4:0])       // 32 sets
```

This is a **hardware-only optimization** — the physical memory layout in SDRAM is unchanged.
Index arrays remain stored in linear left-to-right, top-to-bottom block order as specified above.
The XOR indexing prevents systematic cache aliasing where vertically adjacent block rows would map to the same cache sets under linear indexing.

The palette LUT (UNIT-011.06) is fully resident on-chip after PALETTEn load and is not cached against SDRAM.

## Constraints

- All textures must use power-of-two apparent dimensions (2 to 1024).
- Index array base address must be 512-byte aligned.
- Palette payload base address must be 512-byte aligned.

## Notes

External consumer: [pico-racer](https://github.com/londey/pico-racer) — texture upload sequencing, palette loading, and layout generation.
