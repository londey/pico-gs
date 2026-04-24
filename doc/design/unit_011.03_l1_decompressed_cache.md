# UNIT-011.03: L1 Decompressed Cache

## Purpose

Per-sampler 4-way set-associative cache storing decompressed 4×4 texel blocks in UQ1.8 format (36 bits per texel).
Four interleaved PDPW16KD 512×36 EBR banks per sampler provide single-cycle texel access on cache hit.
On miss, requests UNIT-011.05 (L2 Compressed Cache) to supply the compressed block, then invokes UNIT-011.04 (Block Decompressor) to fill the L1 banks.

## Implements Requirements

- REQ-003.08 (Texture Cache) — L1 portion: per-sampler 2,048-texel decoded cache with pseudo-LRU replacement

## Interfaces

### Provides

(none — internal to UNIT-011)

### Consumes

- INT-010 (GPU Register Map) — TEX0_CFG / TEX1_CFG base address, format, and write-invalidate trigger

### Internal Interfaces

- Receives cache read requests (block address + mip level + sub-texel position) from UNIT-011.01
- Returns one UQ1.8 texel per request on hit (single cycle)
- On miss: requests compressed block from UNIT-011.05; receives 16 decompressed UQ1.8 texels from UNIT-011.04 to fill banks
- Stalls UNIT-006 fragment pipeline while fill is in progress

## Design Description

### Cache Organization

```
Per-Sampler L1 Cache (2 samplers, independent):

  32 sets × 4 ways × 16 texels/line = 2,048 texels per sampler
  UQ1.8 format: 36 bits per texel (4 × 9-bit channels: R, G, B, A)
  Cache line: single 4×4 decompressed texel block (16 texels, 576 bits)

  EBR primitive: PDPW16KD in 512×36 mode
  4 banks per sampler (Bank 0–Bank 3), interleaved by texel parity within the 4×4 block
  Each bank: 512 entries = 128 cache lines × 4 texels/bank
  Total: 4 EBR per sampler, 8 EBR for 2 samplers
```

### Bank Interleaving

The 16 texels within each cache line are distributed across the four banks by their (x, y) parity within the 4×4 block:

```
Texel Positions:       Bank Assignment:
(0,0) (1,0) (2,0) (3,0)    0     1     0     1
(0,1) (1,1) (2,1) (3,1)    2     3     2     3
(0,2) (1,2) (2,2) (3,2)    0     1     0     1
(0,3) (1,3) (2,3) (3,3)    2     3     2     3

Bank 0: texels at (even_x, even_y) positions
Bank 1: texels at (odd_x,  even_y) positions
Bank 2: texels at (even_x, odd_y)  positions
Bank 3: texels at (odd_x,  odd_y)  positions
```

Each NEAREST texel read touches exactly one bank; the 4-bank structure evenly distributes the 16 texels in a 4×4 block and is retained for structural regularity.
The bank selected for a NEAREST read is determined by `sub_u[0]` and `sub_v[0]` (the parity of the sub-texel position).

### Address Fields

**Tag** (stored per way per set):
- `tex_base[31:12]`: texture base address from TEXn_CFG.BASE_ADDR (upper 20 bits of SDRAM byte address)
- `mip_level[3:0]`: mip level (0–15) from UNIT-011.01 output
- Block address bits above the 5-bit set index, derived from UV coordinates and mip level

**Set index (XOR folding):**
```
block_x = pixel_x >> 2
block_y = pixel_y >> 2
set = block_x[4:0] ^ block_y[4:0]    // XOR of low 5 bits → 32 sets
```

XOR indexing distributes spatially adjacent 4×4 blocks across different cache sets, preventing systematic aliasing from row-major access patterns.
Vertically and horizontally adjacent blocks always map to different sets.

**Bank address:**
```
bank_addr = {cache_line_index[6:0], texel_within_bank[1:0]}  // 9 bits → 512 entries
```

### Inputs

- Cache read request: `(tag, set, bank_select)` from UNIT-011.01
- 16 decompressed UQ1.8 texels from UNIT-011.04 (for cache line fill)
- TEX0_CFG / TEX1_CFG write strobe (cache invalidation trigger from UNIT-003)

### Outputs

- One UQ1.8 texel (from the addressed bank) to UNIT-011.04 on hit (single cycle)
- L1 miss signal to trigger UNIT-011.05 L2 lookup
- Pipeline stall signal to UNIT-006

### Replacement Policy

Pseudo-LRU per set (32 sets, each with 4 ways).
On a cache fill, the pseudo-LRU victim way is selected and its tag and valid bit are updated.
Pseudo-LRU avoids thrashing for sequential access patterns such as horizontal scanline sweeps across a texture.

### Cache Invalidation

A TEX0_CFG write clears all 128 valid bits for sampler 0 in a single cycle.
A TEX1_CFG write clears all 128 valid bits for sampler 1 in a single cycle.
The sampler's L2 valid bits are also cleared (see UNIT-011.05).
The next access after invalidation is guaranteed to miss and will trigger an SDRAM fill.
Stale data is never served after a configuration change.

### EBR Notes

**Primitive:** PDPW16KD (ECP5 pseudo-dual-port EBR)
**Mode:** 512×36 (the maximum width mode of this primitive)
**Per sampler:** 4 banks × 1 EBR per bank in 512×36 mode = 4 EBR
Each bank stores exactly 512 entries (128 cache lines × 4 texels per bank), fully utilizing the 512-deep primitive.

**Why PDPW16KD at 512×36?** See DD-037 for the EBR primitive selection rationale.
The 36-bit width exactly matches the 4-channel UQ1.8 texel width (4 × 9 bits).
The pseudo-dual-port configuration allows simultaneous read (for texel fetch) and write (for cache fill) without arbitration, provided the read and write addresses do not collide.
During fill, the read port is held idle.

See REQ-011.02 for the complete EBR budget across the GPU.

## Implementation

- `rtl/components/texture/detail/l1-cache/src/texture_cache_l1.sv`: L1 cache arrays, tag storage, set indexing, replacement logic, and invalidation logic

The authoritative algorithmic design is the gs-texture twin crate (`twin/components/texture/`).
The RTL tag-comparison, replacement, and bank-interleaving behavior must be bit-identical to the twin.

## Design Notes

**L1 capacity:** 2,048 texels per sampler ≈ 45×45 texel equivalent for non-blocked access.
The 32-set × 4-way organization provides working-set locality for typical triangle texture footprints.
The L2 backstop (UNIT-011.05) ensures that L1 misses to recently-evicted blocks are fast (no SDRAM access).

**XOR set indexing is a hardware optimization only:** The physical texture layout in SDRAM (INT-014) is not affected.
The XOR folding is applied entirely within the cache address computation.

**L2 fallback:** When UNIT-011.03 signals an L1 miss, UNIT-011.05 is checked before SDRAM.
The L2 path avoids the full SDRAM burst latency for recently-evicted but not yet-stale blocks.
See UNIT-011.05 for L2 hit latency characteristics.
