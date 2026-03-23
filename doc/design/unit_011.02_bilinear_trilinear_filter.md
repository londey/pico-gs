# UNIT-011.02: Bilinear/Trilinear Filter

## Purpose

Fetches a 2×2 bilinear quad from the four interleaved L1 EBR banks (one texel per bank per cycle), computes bilinear interpolation weights from sub-texel UV fractions, and—when trilinear filtering is enabled—blends two bilinear results from adjacent mip levels using the fractional part of `frag_lod` as the blend weight.
Output is a single filtered UQ1.8 RGBA texel per sampler, ready for format promotion by UNIT-011.04.

## Implements Requirements

- REQ-003.06 (Texture Sampling) — filter portion: bilinear 2×2 interpolation on cache-hit path
- REQ-003.07 (Texture Mipmapping) — trilinear blending between adjacent mip levels

## Interfaces

### Provides

(none — internal to UNIT-011)

### Consumes

- INT-010 (GPU Register Map) — TEXn_CFG.FILTER (NEAREST / BILINEAR / TRILINEAR), TEXn_CFG.MIP_LEVELS

### Internal Interfaces

- Receives wrapped texel coordinates and `bilinear_frac_u[11:0]`, `bilinear_frac_v[11:0]` from UNIT-011.01
- Receives `frag_lod[3:0]` (fractional trilinear blend weight) from the UNIT-006 fragment bus
- Issues L1 cache read requests to UNIT-011.03 (one 4-texel read per mip level; two reads for trilinear)
- Outputs filtered UQ1.8 RGBA to UNIT-011.04 for promotion to Q4.12

## Design Description

### Inputs

- `bilinear_frac_u[11:0]`, `bilinear_frac_v[11:0]`: sub-texel fractional coordinates from UNIT-011.01 (Q4.12 fractional bits [11:0])
- `texels_00`, `texels_10`, `texels_01`, `texels_11`: four UQ1.8 RGBA texels (36 bits each) read from the four interleaved L1 banks in a single cycle (bank 0 = even_x/even_y, bank 1 = odd_x/even_y, bank 2 = even_x/odd_y, bank 3 = odd_x/odd_y)
- For trilinear mode: a second set of four texels from the adjacent mip level
- `trilinear_blend[3:0]`: `frag_lod[3:0]`, the fractional LOD weight for trilinear blending
- `filter_mode[1:0]`: NEAREST (0), BILINEAR (1), or TRILINEAR (2) from TEXn_CFG.FILTER
- `mip_levels[3:0]`: number of mip levels from TEXn_CFG.MIP_LEVELS

### Outputs

- Filtered UQ1.8 RGBA texel (36 bits: 4 × 9-bit channels) to UNIT-011.04

### Algorithm / Behavior

**NEAREST Filtering:**

The nearest texel is selected directly from the cache using the integer texel coordinates (no interpolation).
The four UQ1.8 bank reads are not used; only the texel at the exact wrapped coordinate is output.

**Bilinear Filtering:**

A 2×2 quad is read from UNIT-011.03 in a single cycle, exploiting bank interleaving.
The four banks guarantee one texel per bank for any aligned 2×2 neighborhood:

```
texels_00 (even_x, even_y) from Bank 0
texels_10 (odd_x,  even_y) from Bank 1
texels_01 (even_x, odd_y)  from Bank 2
texels_11 (odd_x,  odd_y)  from Bank 3
```

Bilinear weights are derived from the upper bits of the Q4.12 fractional coordinates:
```
wu = bilinear_frac_u[11:4]   // 8-bit weight in U (0 = left texel, 256 = right texel)
wv = bilinear_frac_v[11:4]   // 8-bit weight in V (0 = top texel, 256 = bottom texel)
```

Per-channel bilinear interpolation (UQ1.8 arithmetic):
```
top    = lerp(texels_00.ch, texels_10.ch, wu)
bottom = lerp(texels_01.ch, texels_11.ch, wu)
result = lerp(top, bottom, wv)
```

All multiplications use the UQ1.8 fixed-point representation; products are 18-bit before right-shift by 8 to recover UQ1.8.

**Trilinear Filtering:**

Trilinear blending requires TEXn_CFG.MIP_LEVELS > 1.
When FILTER = TRILINEAR, two independent bilinear samples are computed: one at mip level `floor(frag_lod[7:4] + mip_bias)` and one at the next coarser level `floor(frag_lod[7:4] + mip_bias) + 1`.
Both L1 reads are issued to UNIT-011.03 (back-to-back if both levels are resident, or stalled for fill if not).
The two bilinear results are blended using `trilinear_blend[3:0]` (4-bit weight from `frag_lod[3:0]`):

```
result = lerp(bilinear_fine, bilinear_coarse, trilinear_blend / 16)
```

When MIP_LEVELS = 1, trilinear mode degenerates to bilinear (no second mip level read is issued).

**Cross-block bilinear filtering:**

When the bilinear neighborhood spans a 4×4 block boundary (e.g., texel at column 3 needs its neighbor at column 4 of the adjacent block), both blocks must be resident in the L1 cache.
The 4-way set associativity of UNIT-011.03 provides sufficient capacity to hold both blocks simultaneously for typical access patterns.
If either neighbor is not resident, the fill FSM is invoked before the bilinear read proceeds.

## Implementation

- `components/texture/rtl/texture_cache.sv`: Bilinear fetch and weight computation are implemented within the texture cache module, in the `bilinear_filter` section

The authoritative algorithmic design is the gs-texture twin crate (`components/texture/twin/`).
RTL output must be bit-identical to the twin's filtered texel values.

## Design Notes

**Single-cycle bilinear on L1 hit:** The bank interleaving scheme (see UNIT-011.03) guarantees that any 2×2 bilinear quad maps to exactly four different banks, so all four texels are available in a single read cycle.
This is the critical property that enables single-cycle bilinear filtering without multi-cycle arbitration.

**No DSP slices for bilinear interpolation:** The 8-bit bilinear weights and 9-bit UQ1.8 texel values fit within 18-bit ECP5 DSP slice inputs.
Bilinear interpolation can be implemented using DSP slices or LUT-based multiply; either approach produces identical results.
See REQ-011.02 for the DSP budget.

**Trilinear latency:** Trilinear mode roughly doubles the L1 read bandwidth requirement because two mip levels must be fetched.
If both mip levels are resident in L1, trilinear adds one extra pipeline cycle for the second bank read; if either level misses, two sequential fill operations may occur.
