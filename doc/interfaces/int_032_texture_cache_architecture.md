# INT-032: Texture Cache Architecture

## Type

Internal

## Parties

- **Provider:** UNIT-006 (Pixel Pipeline)
- **Consumer:** UNIT-006 (Pixel Pipeline)

## Referenced By

- REQ-131 (Texture Cache)
- REQ-024 (Texture Sampling)
- REQ-130 (Texture Mipmapping)

## Specification

### Overview

The texture cache is a per-sampler cache architecture that stores decompressed 4x4 texel blocks in a common intermediate format (RGBA5652) to enable single-cycle bilinear filtering and reduce SDRAM bandwidth. Each of the 4 texture samplers maintains an independent cache to avoid inter-sampler contention.

### Details

#### Cache Line Format (RGBA5652)

Each cache line stores a single decompressed 4x4 texel block (16 texels) in RGBA5652 format:

| Component | Bits | Description |
|-----------|------|-------------|
| R | 5 | Red channel (matches framebuffer RGB565 precision) |
| G | 6 | Green channel (matches framebuffer RGB565 precision) |
| B | 5 | Blue channel (matches framebuffer RGB565 precision) |
| A | 2 | Alpha channel (00=transparent, 01=33%, 10=67%, 11=opaque) |
| **Total** | **18 bits/texel** | **288 bits/cache line (16 texels)** |

**Rationale:**
- RGB565 precision matches framebuffer format (no precision loss)
- 2-bit alpha provides BC1 punch-through support (1-bit alpha expanded to 2 bits)
- 18-bit width matches ECP5 EBR native width (1024×18 configuration)

**Conversion from Source Formats:**

**From RGBA4444:**
- R: `R4→R5` via left shift 1 + MSB replicate: `{R4, R4[3]}`
- G: `G4→G6` via left shift 2 + MSB replicate: `{G4, G4[3:2]}`
- B: `B4→B5` via left shift 1 + MSB replicate: `{B4, B4[3]}`
- A: `A4→A2` via right shift 2: `A4[3:2]`

**From BC1:**
- RGB: RGB565 colors stored directly (no conversion needed)
- A: BC1 1-bit alpha expanded: `0→00`, `1→11`

**Onward Conversion to 10.8 Fixed-Point:**

After cache read, RGBA5652 texels are promoted to 10.8 fixed-point format for pipeline processing:
- R5→R10: `{R5, R5}` (left shift 5, replicate MSBs)
- G6→G10: `{G6, G6[5:2]}` (left shift 4, replicate MSBs)
- B5→B10: `{B5, B5}` (left shift 5, replicate MSBs)
- A2→A10: Expand (00→0, 01→341, 10→682, 11→1023)

#### Bilinear Interleaving

The 16 texels within each cache line are distributed across 4 independent EBR banks, interleaved by texel position parity. This ensures any 2×2 bilinear filter neighborhood reads exactly one texel from each bank, enabling parallel single-cycle access.

**Bank Assignment within 4×4 Block:**

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

**Guarantee:** Any 2×2 bilinear quad accesses exactly one texel per bank in a single cycle on cache hit.

**Note:** For bilinear filtering across block boundaries (e.g., texel at x=3 needs neighbor at x=4 in next block), both blocks must be resident in the cache. The 4-way set associativity provides sufficient capacity for this case.

#### Cache Invalidation Protocol

A sampler's cache is fully invalidated (all valid bits cleared) when texture configuration changes for that sampler:

| Trigger Register Write | Invalidation Target | Reason |
|------------------------|---------------------|--------|
| `TEXn_BASE` | Sampler N cache | Texture base address changed (different texture) |
| `TEXn_FMT` | Sampler N cache | Format, dimensions, or mipmap count changed |

**Invalidation Behavior:**
- Clears all valid bits for the affected sampler (256 cache lines)
- No explicit flush register required (implicit invalidation only)
- Next texture access after invalidation is guaranteed cache miss
- Stale data is never served after configuration change

**Cross-Sampler Independence:**
- Invalidating sampler N does not affect samplers 0, 1, 2, or 3 (excluding N)
- Each sampler maintains independent valid bit arrays

#### Cache Miss Handling Protocol

On cache miss, the pixel pipeline stalls and executes the following cache fill sequence:

1. **Stall Pipeline:** No pixel output until fill completes
2. **SDRAM Burst Read Request:** Issue a burst read to UNIT-007 (Memory Arbiter) with:
   - **Start address:** Computed block address in SDRAM (from INT-014 layout)
   - **Burst length (`burst_len`):** Number of sequential 16-bit words to read
     - **BC1 format:** `burst_len=4` (8 bytes)
     - **RGBA4444 format:** `burst_len=16` (32 bytes)
   - The arbiter issues an ACTIVATE command to open the SDRAM row, then a READ command. After the CAS latency (CL=3 at 100 MHz), the SDRAM streams `burst_len` sequential 16-bit data words on consecutive clock cycles.
3. **Decompression/Conversion:** Transform source format to RGBA5652:
   - BC1: Decompress 2 RGB565 colors + 2-bit indices → 16 RGBA5652 texels
   - RGBA4444: Convert 16 RGBA4444 texels → 16 RGBA5652 texels
   - Decompression/conversion may overlap with the final data cycles of the burst read.
4. **Bank Write:** Write 16 decompressed texels to 4 interleaved EBR banks
5. **Replacement:** Select victim way using pseudo-LRU policy (per set)
6. **Resume Pipeline:** Output requested texels and continue processing

**Cache Fill Latency (at 100 MHz `clk_core`):**
- BC1: ~11 cycles / 110 ns (ACTIVATE + tRCD + READ + CL=3 latency + 4 burst data cycles, decompress + write overlapped)
- RGBA4444: ~23 cycles / 230 ns (ACTIVATE + tRCD + READ + CL=3 latency + 16 burst data cycles, convert + write overlapped)

**Note on SDRAM burst latency:**
SDRAM cache fills incur additional latency compared to async SRAM due to the row activation (tRCD) and CAS latency (CL=3) overhead before the first data word arrives.
However, once the burst begins, data streams at one word per clock cycle, matching async SRAM burst throughput.
When consecutive cache fills target the same SDRAM row (common for spatially adjacent texture blocks), the row activation can be skipped, reducing fill latency to near the async SRAM baseline.

Note: The texture cache and SDRAM controller share the same 100 MHz clock domain, so cache fill SDRAM reads are synchronous single-domain transactions with no CDC overhead.
The burst request interface to UNIT-007 consists of the start address, burst length, and a request strobe; the arbiter responds with a grant and streams data words with a valid strobe.

**Replacement Policy:**
- Pseudo-LRU per set (64 sets, each with 4 ways)
- Avoids thrashing for sequential access patterns (e.g., horizontal scanline sweeps)

#### Set Indexing (XOR Folding)

Cache set index is computed using XOR-folded addressing to distribute spatially adjacent blocks across different cache sets:

```
block_x = pixel_x / 4
block_y = pixel_y / 4
set = (block_x[5:0] ^ block_y[5:0])  // XOR of low 6 bits → 64 sets
```

**Rationale:** Linear indexing (`set = block_index % 64`) causes all blocks in a texture row to map to the same 64 sets. For a 256×256 texture (64 blocks per row), vertically adjacent blocks at (x, y) and (x, y+1) map to the same set, causing thrashing during bilinear filtering at block boundaries. XOR indexing distributes adjacent blocks across different sets.

**Properties:**
- Vertically adjacent blocks map to different cache sets
- Horizontally adjacent blocks map to different cache sets
- No systematic aliasing patterns for typical texture access

#### Cache Address Space

Each cache line is identified by:
- **Tag:** Unique identifier for the 4×4 block
  - Texture base address: `texture_base[31:12]` (from TEXn_BASE register)
  - Mipmap level: `mip_level[3:0]` (0-15)
  - Block address: Computed from UV coordinates and mip level
- **Set:** 6-bit index (0-63) from XOR-folded block coordinates
- **Way:** 2-bit index (0-3) for 4-way set associativity

**Total Cache Capacity per Sampler:**
- 256 cache lines × 16 texels/line = 4096 texels (64×64 texture equivalent)
- 256 lines × 18 bits/texel × 16 texels = 4608 bytes = 4.5 KB per sampler
- 4 samplers × 4.5 KB = 18 KB total cache storage

**EBR Usage per Sampler:**
- 4 banks × 1024×18-bit EBR blocks = 4 EBR blocks per sampler
- 4 samplers × 4 EBR = 16 EBR blocks total (matches REQ-051 budget allocation)

## Constraints

- Maximum 4 texture samplers (0-3)
- Cache line size fixed at 4×4 texels (16 texels)
- RGBA5652 format is internal to cache (not exposed to firmware)
- Cache is write-through (texture writes not supported)
- Cache is non-coherent (invalidation required on texture change)
- RGBA4444 textures lose 2 bits of alpha precision (4-bit → 2-bit) in cache

## Notes

### XOR Set Indexing

XOR set indexing is a hardware-only optimization; no physical texture memory layout change is required in SDRAM. The linear 4×4 block layout in SDRAM (INT-014) remains unchanged.

### Alpha Precision Loss

RGBA4444 textures lose 2 bits of alpha precision in cache (4-bit → 2-bit). This is acceptable because:
- Final framebuffer is RGB565 with no alpha channel stored
- Alpha is only used for blending intermediate results
- 2-bit alpha (4 levels) is sufficient for basic transparency (opaque, mostly opaque, mostly transparent, transparent)

### Cache Coherency

The cache is non-coherent: texture data is read-only from the GPU's perspective. If firmware modifies texture data in SDRAM via `MEM_DATA` writes, it must invalidate the affected sampler's cache by writing to `TEXn_BASE` or `TEXn_FMT` (even if the value doesn't change).

### Design Rationale

See DD-010 in [design_decisions.md](../design/design_decisions.md) for architectural rationale behind per-sampler caches, RGBA5652 format selection, and XOR set indexing.

### References

- **INT-010 (GPU Register Map):** TEXn_BASE, TEXn_FMT register definitions
- **INT-014 (Texture Memory Layout):** Source texture block addressing in SDRAM
- **UNIT-006 (Pixel Pipeline):** Cache implementation details (4-way set associative, pseudo-LRU, EBR usage)
- **REQ-024 (Texture Sampling):** Cache-aware sampling pipeline behavior
- **REQ-130 (Texture Mipmapping):** Cache handles mip-level blocks with distinct tags
