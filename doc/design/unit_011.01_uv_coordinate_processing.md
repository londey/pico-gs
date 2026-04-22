# UNIT-011.01: UV Coordinate Processing

## Purpose

Applies wrap mode, clamp, mirror-repeat, and swizzle pattern to incoming Q4.12 UV coordinates, then selects the final mip level by combining `frag_lod` with `TEXn_MIP_BIAS`.
Outputs wrapped integer texel coordinates and a mip level index to UNIT-011.03 (L1 Decompressed Cache) for cache tag comparison and block address computation.

## Implements Requirements

- REQ-003.04 (Swizzle Patterns) — applies TEXn_CFG.SWIZZLE to the UV pair after wrapping
- REQ-003.05 (UV Wrapping Modes) — implements REPEAT, CLAMP, and MIRROR modes per TEXn_CFG.U_WRAP / V_WRAP

## Interfaces

### Provides

(none — internal to UNIT-011)

### Consumes

- INT-010 (GPU Register Map) — TEXn_CFG.U_WRAP, TEXn_CFG.V_WRAP, TEXn_CFG.SWIZZLE, TEXn_CFG.MIP_BIAS fields

### Internal Interfaces

- Receives Q4.12 UV coordinates (UV0 or UV1) from the UNIT-006 fragment bus
- Receives `frag_lod` (UQ4.4, 8-bit) from the UNIT-006 fragment bus
- Outputs wrapped texel coordinates (integer block_x, block_y and sub-texel fraction bits) to UNIT-011.02 and UNIT-011.03
- Outputs `mip_level[3:0]` to UNIT-011.03 for cache tag matching

## Design Description

### Inputs

- `uv_q412[15:0]`: Q4.12 signed fixed-point UV coordinate (16-bit; sign at [15], integer at [14:12], fractional at [11:0]).
  Perspective correction is performed upstream by UNIT-005.05; this unit receives true U, V values.
- `frag_lod[7:0]`: UQ4.4 level-of-detail from UNIT-005; integer mip level in bits [7:4], trilinear blend weight in bits [3:0]
- `tex_u_wrap[1:0]`, `tex_v_wrap[1:0]`: wrap mode from TEXn_CFG (REPEAT=0, CLAMP=1, MIRROR=2)
- `tex_swizzle[1:0]`: swizzle pattern from TEXn_CFG
- `tex_mip_bias[3:0]`: signed mip bias from TEXn_CFG

### Outputs

- `block_x[N-1:0]`, `block_y[N-1:0]`: integer texel block coordinates after wrap/clamp/mirror; width N is texture-size-dependent
- `sub_u[1:0]`, `sub_v[1:0]`: 2-bit sub-texel position within a 4×4 block (selects which of the 16 texels to sample)
- `bilinear_frac_u[11:0]`, `bilinear_frac_v[11:0]`: sub-texel fractional bits from the Q4.12 coordinate, used by UNIT-011.02 for bilinear weight computation
- `mip_level[3:0]`: final mip level after bias application

### Algorithm / Behavior

**UV Coordinate Extraction:**

The Q4.12 UV value encodes the texture coordinate as a signed fixed-point number.
The integer portion `uv[14:12]` selects the texel block column/row.
The fractional portion `uv[11:0]` carries sub-texel position for bilinear filtering.
The sign bit `uv[15]` indicates negative coordinates (used by wrap/mirror logic).

**Wrap Mode Application (applied independently to U and V):**

- **REPEAT:** Mask the integer portion to texture width/height − 1: `texel_int = uv_int & (tex_size − 1)`.
  Negative coordinates wrap correctly using the same mask (two's-complement).
- **CLAMP:** Saturate: `texel_int = max(0, min(uv_int, tex_size − 1))`.
  Fractional bits are zeroed when the coordinate is clamped to an edge.
- **MIRROR:** Reflect at each integer boundary.
  Even integer parts use `uv_frac` directly; odd integer parts use `(tex_size − 1) − uv_frac`.
  The integer block address is masked to `tex_size − 1` after reflection.

**Block Address Computation:**

After wrap mode is applied, the texel coordinate is divided into a 4×4 block address and a within-block position:
```
block_x = texel_x >> 2
block_y = texel_y >> 2
sub_u   = texel_x[1:0]
sub_v   = texel_y[1:0]
```

**Swizzle Pattern (REQ-003.04):**

After wrap mode and block decomposition, the swizzle pattern from TEXn_CFG.SWIZZLE remaps the UV pair.
The swizzle field selects one of the defined swizzle modes (e.g., UV, VU, UU, VV) by exchanging or replicating the U and V coordinate channels before they are passed to UNIT-011.03.

**Mip Level Selection:**

The final mip level is computed by adding `TEXn_MIP_BIAS` to the integer mip level from `frag_lod`:
```
mip_level[3:0] = (frag_lod[7:4] + tex_mip_bias[3:0]) & 4'hF
```
The addition is treated as unsigned 4-bit with wrap-around.
The fractional blend weight `frag_lod[3:0]` is passed through unchanged to UNIT-011.02 for trilinear blending.

## Implementation

- `rtl/components/texture/detail/uv-coord/src/texture_uv_coord.sv`: UV coordinate wrapping and bilinear tap computation

The authoritative algorithmic design is the gs-texture twin crate (`twin/components/texture/`).
RTL behavior must be bit-identical to the twin at the texel coordinate level.

## Design Notes

**No division required:** All wrap, clamp, and mirror operations are implemented using bit masking and saturation.
Power-of-two texture dimensions (required by INT-014) mean modulo wrap reduces to a single AND mask.

**Swizzle precedes cache lookup:** The swizzle is applied to the UV pair before the block address and cache tag are computed, so the cache stores texels at swizzled addresses.
This is transparent to UNIT-011.02 (which receives already-swizzled coordinates).

**Mip bias clamping:** If the biased mip level exceeds TEXn_CFG.MIP_LEVELS − 1, it is clamped to the maximum valid level.
This prevents out-of-range lookups for textures with fewer than 16 mip levels.
