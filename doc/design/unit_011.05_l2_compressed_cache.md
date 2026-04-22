# UNIT-011.05: L2 Compressed Cache

## Purpose

Per-sampler direct-mapped cache storing raw compressed or uncompressed 4×4 block data fetched from SDRAM.
Reduces SDRAM bandwidth by serving recently-evicted L1 blocks without a full SDRAM burst read.
On L2 miss, issues a format-dependent burst read request to UNIT-007 (Memory Arbiter) on arbiter port 3, then forwards the compressed block to UNIT-011.04 (Block Decompressor) for L1 fill.

## Implements Requirements

- REQ-003.08 (Texture Cache) — L2 portion: per-sampler 1,024×64-bit compressed block backing store

## Interfaces

### Provides

(none — internal to UNIT-011)

### Consumes

- INT-010 (GPU Register Map) — TEXn_CFG base address and format fields
- INT-011 (SDRAM Memory Layout) — SDRAM addressing conventions for burst read requests
- INT-014 (Texture Memory Layout) — 4×4 block-tiled texture layout in SDRAM; used to compute block start addresses for SDRAM burst reads

### Internal Interfaces

- Receives L2 lookup requests (block address, format, sampler ID) from the UNIT-011.03 miss handling path
- Returns raw compressed block data to UNIT-011.04 on L2 hit
- Issues SDRAM burst read requests to UNIT-007 port 3 on L2 miss
- Receives SDRAM burst data from UNIT-007 and stores it in L2 EBR banks
- Stall signal to UNIT-006 fragment pipeline while SDRAM burst is in progress

## Design Description

### Cache Organization

```
Per-Sampler L2 Cache (2 samplers, independent):

  1,024 × 64-bit entries per sampler
  Direct-mapped (no set associativity)
  EBR primitive: DP16KD in 1024×16 mode
  4 DP16KD banks per sampler — each bank stores 1024 entries × 16-bit word
  Combined: 1024 × 64-bit (four 16-bit words packed per entry)

  Total: 4 EBR per sampler, 8 EBR for 2 samplers
```

### Format-Aware Packing

Each texture format occupies a different number of 64-bit entries per 4×4 block.
Block data is packed as four 16-bit words per 64-bit entry (little-endian byte order).

| Format   | FORMAT code | entries/block | L2 capacity (blocks) | Notes |
|----------|-------------|---------------|----------------------|-------|
| BC1      | 0           | 1             | 1,024                | 64-bit BC1 block |
| BC4      | 3           | 1             | 1,024                | 64-bit BC4 block |
| BC2      | 1           | 2             | 512                  | 128-bit BC2 block |
| BC3      | 2           | 2             | 512                  | 128-bit BC3 block |
| R8       | 7           | 2             | 512                  | 16 × 8-bit pixels, two per 16-bit word |
| RGB565   | 5           | 4             | 256                  | 16 × 16-bit pixels |
| RGBA8888 | 6           | 8             | 128                  | 16 × 32-bit pixels |

### L2 Addressing

Direct-mapped with format-dependent slot count:

```text
entries_per_block = format_entries[tex_format]  // from table above
num_slots = 1024 / entries_per_block
slot = (base_words ^ block_index) % num_slots
data_base = slot * entries_per_block
```

Where `base_words` is the texture base address in units of 16-bit words, and `block_index` is the linear index of the 4×4 block within the texture at the given mip level.

**L2 Tag:** Each slot stores `(base_words, block_index, mip_level)` and a valid bit.
A tag match on all three fields constitutes an L2 hit.

XOR addressing distributes blocks from different textures (and different mip levels of the same texture) across different L2 slots, reducing systematic aliasing similar to the L1 XOR set indexing in UNIT-011.03.

### SDRAM Burst Fill

On L2 miss, the fill FSM issues a burst read request to UNIT-007 (Memory Arbiter) on port 3:

| Format   | FORMAT code | burst_len | Bytes | Reason |
|----------|-------------|-----------|-------|--------|
| BC1      | 0           | 4         | 8     | 64-bit BC1 block |
| BC4      | 3           | 4         | 8     | 64-bit BC4 block |
| BC2      | 1           | 8         | 16    | 128-bit BC2 block |
| BC3      | 2           | 8         | 16    | 128-bit BC3 block |
| R8       | 7           | 8         | 16    | 16 × 8-bit pixels |
| RGB565   | 5           | 16        | 32    | 16 × 16-bit pixels |
| RGBA8888 | 6           | 32        | 64    | 16 × 32-bit pixels |

`burst_len` is the number of 16-bit words to read.
The start address is computed from the INT-014 texture memory layout: block-tiled 4×4 addressing using the texture base address from TEXn_CFG and the block index at the requested mip level.

**SDRAM Fill Latency (at 100 MHz `clk_core`):**

- BC1/BC4: ~11 cycles / 110 ns (ACTIVATE + tRCD + READ + CL=3 + 4 burst data cycles)
- BC2/BC3/R8: ~19 cycles / 190 ns (8 burst data cycles)
- RGB565: ~23 cycles / 230 ns (16 burst data cycles)
- RGBA8888: ~39 cycles / 390 ns (32 burst data cycles)

When consecutive fills target the same SDRAM row (common for spatially adjacent texture blocks), the row activation can be skipped, reducing fill latency toward the CAS-only baseline.

The texture cache and SDRAM controller share the same 100 MHz clock domain, so cache fill SDRAM reads are synchronous single-domain transactions with no CDC overhead.

### Cache Invalidation

A TEX0_CFG write clears all valid bits for sampler 0's L2 cache in a single cycle.
A TEX1_CFG write clears all valid bits for sampler 1's L2 cache in a single cycle.
The two samplers are independent; invalidating one does not affect the other.
After invalidation, the next access is guaranteed to miss L2 and will trigger a full SDRAM burst fill.

See UNIT-011.03 for the corresponding L1 invalidation.

### Fill State Machine

The fill FSM (in `texture_cache.sv`) implements:
```
IDLE → FETCH → DECOMPRESS → WRITE_BANKS → IDLE
```

- **FETCH:** Issues burst read request to UNIT-007 port 3; waits for all burst data words to arrive
- **DECOMPRESS:** Forwards raw block data to UNIT-011.04; waits for all 16 UQ1.8 texels
- **WRITE_BANKS:** Writes 16 decompressed texels to UNIT-011.03 L1 banks; updates L1 tag and pseudo-LRU state; writes raw block to L2 EBR
- **IDLE:** Returns to ready state; removes pipeline stall

### EBR Notes

**Primitive:** DP16KD (ECP5 true dual-port EBR)
**Mode:** 1024×16 (one 16-bit word per address)
**Per sampler:** 4 banks × 1 EBR per bank = 4 EBR
Combined as a 1024×64-bit store (four 16-bit banks accessed simultaneously).

**Why DP16KD at 1024×16?** The 1024-deep address space exactly matches the L2 slot count.
The true dual-port configuration allows simultaneous L2 tag check (read port) and L2 fill write (write port) when fill data arrives while a lookup is in progress.

See REQ-011.02 for the complete EBR budget across the GPU.

## Implementation

- `rtl/components/texture/detail/l1-cache/src/texture_cache_l1.sv`: L1 cache arrays, tag storage, format-aware addressing, fill FSM, and SDRAM burst request logic
- `rtl/components/texture/detail/l2-cache/src/texture_l2_cache.sv`: L2 compressed block cache (per-sampler direct-mapped cache)

The authoritative algorithmic design is the gs-texture twin crate (`twin/components/texture/`).
The RTL L2 addressing, tag matching, and fill protocol must be bit-identical to the twin.

## Verification

- VER-012 (Textured Triangle Golden Image Test) — exercises L2 fill on cold start
- VER-014 (Textured Cube Golden Image Test) — exercises L2 with multi-face access patterns
- VER-016 (Perspective Road Golden Image Test) — exercises L2 with RGB565 burst fills

## Design Notes

**L2 reduces SDRAM bandwidth for L1 thrashing:** When rendering geometry with texture footprints larger than the L1 capacity (~45×45 texels), L1 evictions are frequent.
Without L2, each re-access to an evicted block would trigger a full SDRAM burst.
With L2, the re-access is served from L2 at roughly 2–4 cycles (EBR read latency) rather than 11–39 cycles (SDRAM latency).

**RGBA8888 capacity:** At 8 entries per block, L2 holds only 128 RGBA8888 blocks (equivalent to a 45×45 texel area).
Applications using large RGBA8888 textures should prefer BC1 or BC3 compression to maximize effective L2 coverage.

**L2 is write-through/read-only from GPU perspective:** Texture data is never written by the GPU.
If firmware modifies texture data in SDRAM via `MEM_DATA` writes, it must invalidate the affected sampler's cache by writing to `TEX0_CFG` or `TEX1_CFG` even if no field value changes.
See the Cache Coherency note in the design decisions document (DD-010).

**Port 3 arbitration:** Texture burst reads share port 3 with `PERF_TIMESTAMP` writes from `gpu_top.sv`.
Timestamp writes are single-word, low-priority, fire-and-forget; texture bursts hold the port for up to 32 words and have effective precedence due to arrival-order arbitration.
See DD-026.
