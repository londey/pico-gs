# INT-032: Texture Cache Architecture

## Type

Internal

## Parties

- **Provider:** UNIT-006 (Pixel Pipeline)
- **Consumer:** UNIT-006 (Pixel Pipeline)

## Referenced By

- REQ-003 (Texture Samplers)
- REQ-003.06 (Texture Sampling)
- REQ-003.07 (Texture Mipmapping)
- REQ-003.08 (Texture Cache)

## Specification

### Overview

The texture cache is a per-sampler cache architecture that stores decompressed 4×4 texel blocks in a common intermediate format (RGBA5652) to enable single-cycle bilinear filtering and reduce SDRAM bandwidth.
Each of the 2 texture samplers maintains an independent cache to avoid inter-sampler contention.
Each sampler has a 16,384-texel cache for improved hit rates on larger textures.

### Details

#### Format Field Width

The `tex_format` signal that selects the decode path is a **3-bit field** (`[4:2]` of TEXn_FMT; see INT-010).
Seven distinct values (0–6) are defined; value 7 is reserved.
The 3-bit width is the minimum required to encode all seven formats without aliasing.

#### Cache Line Format (RGBA5652)

Each cache line stores a single decompressed 4×4 texel block (16 texels) in RGBA5652 format:

| Component | Bits | Description |
|-----------|------|-------------|
| R | 5 | Red channel (matches framebuffer RGB565 precision) |
| G | 6 | Green channel (matches framebuffer RGB565 precision) |
| B | 5 | Blue channel (matches framebuffer RGB565 precision) |
| A | 2 | Alpha channel (00=transparent, 01=33%, 10=67%, 11=opaque) |
| **Total** | **18 bits/texel** | **288 bits/cache line (16 texels)** |

**Rationale:**
- RGB565 precision matches framebuffer format (no precision loss for color data)
- 2-bit alpha provides BC1 punch-through support (1-bit alpha expanded to 2 bits)
- 18-bit width matches ECP5 EBR native width (1024×18 configuration)
- Single unified format for all source texture formats simplifies downstream pipeline

**Conversion from Source Formats:**

**From BC1 (FORMAT=0):**
- RGB: Reconstructed RGB565 palette entries stored directly (no conversion needed)
- A: BC1 1-bit punch-through alpha: `0→00` (transparent), `1→11` (opaque)

**From BC2 (FORMAT=1):**
- RGB: Reconstructed from BC1 color block (last 8 bytes)
- A: 4-bit explicit alpha truncated to 2 bits: A4[3:2]

**From BC3 (FORMAT=2):**
- RGB: Reconstructed from BC1 color block (last 8 bytes)
- A: 8-bit interpolated alpha (from first 8 bytes) truncated to 2 bits: A8[7:6]

**From BC4 (FORMAT=3):**
- R: Reconstructed 8-bit single channel
- G: Copy of R channel
- B: Copy of R channel
- A: `11` (opaque)
- Stored as R5=`{R8[7:3]}`, G6=`{R8[7:2]}`, B5=`{R8[7:3]}`

**From RGB565 (FORMAT=4):**
- R5, G6, B5: Stored directly
- A: `11` (opaque)

**From RGBA8888 (FORMAT=5):**
- R: `R8[7:3]` (top 5 bits)
- G: `G8[7:2]` (top 6 bits)
- B: `B8[7:3]` (top 5 bits)
- A: `A8[7:6]` (top 2 bits)

**From R8 (FORMAT=6):**
- R: `R8[7:3]`
- G: Same as R (channel replicate)
- B: Same as R (channel replicate)
- A: `11` (opaque)

**Onward Conversion to Q4.12:**

After cache read, RGBA5652 texels are promoted to Q4.12 signed fixed-point format for pipeline processing (REQ-004.02):

- R5 to Q4.12: Expand to UNORM [0.0, 1.0] using MSB replication: `{3'b0, R5, R5[4:1], 3'b0}`
- G6 to Q4.12: Expand to UNORM [0.0, 1.0] using MSB replication: `{3'b0, G6, G6[5:0], 2'b0}`
- B5 to Q4.12: Same as R5
- A2 to Q4.12: Four-level expansion: 00→0x0000, 01→0x0555, 10→0x0AAA, 11→0x1000

All Q4.12 values represent signed fixed-point in range [−8.0, +7.999], where UNORM [0, 1] maps to [0x0000, 0x1000].

#### Bilinear Interleaving

The 16 texels within each cache line are distributed across 4 independent EBR banks, interleaved by texel position parity.
This ensures any 2×2 bilinear filter neighborhood reads exactly one texel from each bank, enabling parallel single-cycle access.

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

**Note:** For bilinear filtering across block boundaries (e.g., texel at x=3 needs neighbor at x=4 in next block), both blocks must be resident in the cache.
The 4-way set associativity provides sufficient capacity for this case.

#### Cache Invalidation Protocol

A sampler's cache is fully invalidated (all valid bits cleared) when texture configuration changes for that sampler:

| Trigger Register Write | Invalidation Target | Reason |
|------------------------|---------------------|--------|
| `TEX0_CFG` (0x10) | Sampler 0 cache | Texture configuration changed |
| `TEX1_CFG` (0x11) | Sampler 1 cache | Texture configuration changed |

**Invalidation Behavior:**
- Clears all valid bits for the affected sampler (1024 cache lines)
- No explicit flush register required (implicit invalidation only)
- Next texture access after invalidation is guaranteed cache miss
- Stale data is never served after configuration change

**Cross-Sampler Independence:**
- Invalidating sampler N does not affect the other sampler
- Each sampler maintains independent valid bit arrays

#### Cache Miss Handling Protocol

On cache miss, the pixel pipeline stalls and executes the following cache fill sequence:

1. **Stall Pipeline:** No pixel output until fill completes
2. **SDRAM Burst Read Request:** Issue a burst read to UNIT-007 (Memory Arbiter) with:
   - **Start address:** Computed block address in SDRAM (from INT-014 layout, 4×4 block-tiled)
   - **Burst length (`burst_len`):** Number of sequential 16-bit words to read

| Format | burst_len | Bytes | Reason |
|--------|-----------|-------|--------|
| BC1 | 4 | 8 | 64-bit BC1 block |
| BC2 | 8 | 16 | 128-bit BC2 block |
| BC3 | 8 | 16 | 128-bit BC3 block |
| BC4 | 4 | 8 | 64-bit BC4 block |
| RGB565 | 16 | 32 | 16 × 16-bit pixels |
| RGBA8888 | 32 | 64 | 16 × 32-bit pixels |
| R8 | 8 | 16 | 16 × 8-bit pixels (packed two per 16-bit word) |

3. **Decompression/Conversion:** Transform source format to RGBA5652 (per conversion table above)
4. **Bank Write:** Write 16 decompressed texels to 4 interleaved EBR banks
5. **Replacement:** Select victim way using pseudo-LRU policy (per set)
6. **Resume Pipeline:** Output requested texels and continue processing

**Cache Fill Latency (at 100 MHz `clk_core`):**
- BC1/BC4: ~11 cycles / 110 ns (ACTIVATE + tRCD + READ + CL=3 latency + 4 burst data cycles)
- BC2/BC3/R8: ~19 cycles / 190 ns (8 burst data cycles)
- RGB565: ~23 cycles / 230 ns (16 burst data cycles)
- RGBA8888: ~39 cycles / 390 ns (32 burst data cycles)

**Note on SDRAM burst latency:**
When consecutive cache fills target the same SDRAM row (common for spatially adjacent texture blocks), the row activation can be skipped, reducing fill latency toward the CAS-only baseline.

Note: The texture cache and SDRAM controller share the same 100 MHz clock domain, so cache fill SDRAM reads are synchronous single-domain transactions with no CDC overhead.

**Replacement Policy:**
- Pseudo-LRU per set (256 sets, each with 4 ways)
- Avoids thrashing for sequential access patterns (e.g., horizontal scanline sweeps)

#### Set Indexing (XOR Folding)

Cache set index is computed using XOR-folded addressing to distribute spatially adjacent blocks across different cache sets:

```
block_x = pixel_x >> 2
block_y = pixel_y >> 2
set = (block_x[7:0] ^ block_y[7:0])  // XOR of low 8 bits → 256 sets
```

**Rationale:** XOR indexing distributes adjacent blocks across different sets, avoiding the systematic aliasing that arises from linear indexing when texture rows map to the same set indices.

**Properties:**
- Vertically adjacent blocks map to different cache sets
- Horizontally adjacent blocks map to different cache sets
- No systematic aliasing patterns for typical texture access
- 256 sets covers a 256×256 texel area (128×128 in 4×4 blocks), providing excellent coverage for typical texture sizes

#### Cache Address Space

Each cache line is identified by:
- **Tag:** Unique identifier for the 4×4 block
  - Texture base address: `tex_cfg.BASE_ADDR` (from TEX0_CFG/TEX1_CFG register)
  - Mipmap level: `mip_level[3:0]` (0-15)
  - Block address: Computed from UV coordinates and mip level
- **Set:** 8-bit index (0-255) from XOR-folded block coordinates
- **Way:** 2-bit index (0-3) for 4-way set associativity

**Total Cache Capacity per Sampler**:
- 1024 cache lines × 16 texels/line = 16,384 texels (128×128 texture equivalent)
- 1024 lines × 18 bits/texel × 16 texels = 18,432 bytes = 18 KB per sampler
- 2 samplers × 18 KB = 36 KB total cache storage

**EBR Usage per Sampler**:
- 4 bilinear banks × 4 EBR blocks each = 16 EBR blocks per sampler
- 2 samplers × 16 EBR = 32 EBR blocks total

**EBR Budget Note**: The ECP5-25K provides 56 EBR blocks total.
The texture cache allocation of 32 EBR (2 samplers × 16 EBR) consumes 57% of available EBR.
Combined with other EBR consumers (1 dither, 1 LUT, 1 scanline FIFO, 2 command FIFO = 5 EBR), the total is 37 EBR out of 56, leaving 19 EBR for other uses.
See REQ-011.02 for the complete resource budget.

## Constraints

- Maximum 2 texture samplers (0-1)
- 16,384 texels per sampler cache
- Cache line size fixed at 4×4 texels (16 texels)
- RGBA5652 format is internal to cache (not exposed to firmware)
- Cache is write-through (texture writes not supported)
- Cache is non-coherent (invalidation required on texture change via TEXn_CFG write)
- BC2/BC3 alpha is truncated to 2 bits in cache (A2); precision loss is acceptable for the intermediate blending step
- RGBA8888 and R8 formats incur the highest fill latency due to larger burst sizes; prefer compressed formats for performance-sensitive textures
- The format-select mux in the pixel pipeline routes the SDRAM burst data to the appropriate decoder module (one of six standalone decoders: `texture_bc2.sv`, `texture_bc3.sv`, `texture_bc4.sv`, `texture_rgb565.sv`, `texture_rgba8888.sv`, `texture_r8.sv`) based on `tex_format[2:0]` (INT-010 TEXn_FMT bits [4:2])

## Notes

### XOR Set Indexing

XOR set indexing is a hardware-only optimization; no physical texture memory layout change is required in SDRAM.
The 4×4 block-tiled layout in SDRAM (INT-014) remains unchanged.

### Alpha Precision

All source formats are reduced to 2-bit alpha in cache.
This is acceptable because:
- Final framebuffer is RGB565 with no alpha channel stored
- Alpha is only used for blending intermediate results
- 2-bit alpha (4 levels) is sufficient for basic transparency (opaque, mostly opaque, mostly transparent, transparent)
- BC1 1-bit punch-through uses only the 00 and 11 states of the 2-bit field

### Cache Coherency

The cache is non-coherent: texture data is read-only from the GPU's perspective.
If firmware modifies texture data in SDRAM via `MEM_DATA` writes, it must invalidate the affected sampler's cache by writing to `TEX0_CFG` or `TEX1_CFG` (even if the value doesn't change).

### Design Rationale

See DD-010 in [design_decisions.md](../design/design_decisions.md) for architectural rationale behind per-sampler caches, RGBA5652 format selection, and XOR set indexing.

### References

- **INT-010 (GPU Register Map):** TEX0_CFG, TEX1_CFG register definitions
- **INT-014 (Texture Memory Layout):** Source texture block addressing in SDRAM
- **UNIT-006 (Pixel Pipeline):** Cache implementation details (4-way set associative, pseudo-LRU, EBR usage)
- **REQ-003.06 (Texture Sampling):** Cache-aware sampling pipeline behavior
- **REQ-003.07 (Texture Mipmapping):** Cache handles mip-level blocks with distinct tags

### Verification

- **VER-005** (`texture_decoder_tb`): Unit testbench verifying texture decoders that produce RGBA5652 output for cache storage.
  Tests all seven source formats (BC1–BC4, RGB565, RGBA8888, R8) and confirms correct RGBA5652 encoding per the conversion table above.
- **VER-012** (Textured triangle golden image test): Integration test exercising the full cache + decode + sample path.
  The integration simulation harness must model (or stub) the SDRAM miss-handling protocol defined in the Cache Miss Handling Protocol section above, including correct burst lengths per format and the IDLE → FETCH → DECOMPRESS → WRITE_BANKS → IDLE fill FSM.
