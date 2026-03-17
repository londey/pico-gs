# INT-032: Texture Cache Architecture

## Type

Internal

## Specification

### Overview

The texture cache is a per-sampler, two-level cache architecture that reduces SDRAM bandwidth and enables single-cycle bilinear filtering.
Each of the 2 texture samplers maintains an independent two-level cache to avoid inter-sampler contention.

- **L1 (Decoded):** 2,048-texel cache (32 sets × 4 ways × 16 texels/line) storing decompressed 4×4 blocks in UQ1.8 format (36 bits per texel).
  4 PDPW16KD 512×36 banks per sampler (4 EBR per sampler, all 512 entries utilized).
- **L2 (Compressed):** 1,024 × 64-bit entry cache storing raw compressed/uncompressed block data.
  4 DP16KD 1024×16 banks per sampler (4 EBR per sampler).
  Format-aware packing: 1024 BC1 blocks, 512 BC3, 256 RGB565, or 128 RGBA8888.

Total: 8 EBR per sampler, 16 EBR for 2 samplers.

### Details

#### Format Field Width

The `tex_format` signal that selects the decode path is a **4-bit field** (`[5:2]` of TEXn_FMT; see INT-010).
Seven formats are defined (0–3, 5–7); value 4 (formerly BC5) is reserved along with 8–15.
The 4-bit width accommodates eight formats with room for future additions.

#### Cache Line Format

Writing `TEXn_FMT` (regardless of which bits change) invalidates the corresponding sampler's cache.
The first access after the write is guaranteed a cache miss and will fill using the UQ1.8 format.

#### Cache Line Format (UQ1.8 per channel)

Each cache line stores a single decompressed 4×4 texel block (16 texels) in four-channel UQ1.8 format:

| Component | Bits | Description |
|-----------|------|-------------|
| R | 9 | Red channel as UQ1.8 (range 0.0 to ~2.0, UNORM maps to [0x000, 0x100]) |
| G | 9 | Green channel as UQ1.8 |
| B | 9 | Blue channel as UQ1.8 |
| A | 9 | Alpha channel as UQ1.8 (0x000=transparent, 0x100=opaque) |
| **Total** | **36 bits/texel** | **576 bits/cache line (16 texels)** |

UQ1.8 stores values in range [0, 2) with 1/256 resolution.
UNORM [0, 1] maps to integer values [0x000, 0x100] (256 decimal = value 1.0).
The extra headroom above 1.0 is unused for UNORM source data but reserved for potential HDR extensions.

**Rationale:**
- 9-bit per channel matches the natural output precision of BC color endpoint expansion (BC endpoints are 8-bit after scaling)
- Eliminates the precision loss of truncating RGBA8888 or BC-decoded 8-bit values to 5- or 6-bit fields
- 36-bit width matches ECP5 PDPW16KD pseudo-dual-port primitive in 512×36 mode
- Preferred mode for BC-compressed and RGBA8888 textures where decoding produces 8-bit channel values

**L1 EBR note:** 4 PDPW16KD 512×36 banks per sampler = 4 EBR per sampler (8 EBR for 2 samplers).
Each bank stores 128 lines × 4 texels = 512 entries, fully utilizing the 512-deep primitive.
See REQ-011.02 for the complete resource budget.

**BC Division — shift+add reciprocal multiply:**
All BC palette interpolation divisions (e.g., `(2*c0 + c1) / 3`, `(c0 + c1) / 2`) are implemented using shift+add reciprocal-multiply rather than Verilog `/` operators.
This ensures deterministic LUT usage: no synthesizer-generated integer dividers are instantiated.
The formulas are (see DD-039):

- Division by 2: `x_div2 = (x + 1) >> 1`
- Division by 3: `x_div3 = (x + 1) * 683 >> 11` (multiply by 0x2AB, shift 11; exact for sums ≤ 769)
- Division by 5: `x_div5 = (x + 2) * 3277 >> 14` (BC3 6-entry alpha; exact for sums ≤ 1277)
- Division by 7: `x_div7 = (x + 3) * 2341 >> 14` (BC3 8-entry alpha; exact for sums ≤ 1788)

**Conversion from Source Formats (UQ1.8):**

All source-format channel values are decoded and expanded to 9-bit UQ1.8 using correction terms that map the maximum UNORM value to exactly 0x100 (1.0).
The naive `{1'b0, unorm8}` mapping is **not used** because it maps 255 to 0xFF (≈0.996), failing to represent 1.0 exactly.
See DD-038 for rationale.

Channel expansion formulas (gs-twin is authoritative):

- **8-bit → UQ1.8**: `ch8_to_uq18(x) = {1'b0, x[7:0]} + {8'b0, x[7]}` — maps 0→0x000, 255→0x100
- **5-bit → UQ1.8**: `ch5_to_uq18(x) = {1'b0, x[4:0], x[4:2]} + {8'b0, x[4]}` — maps 0→0x000, 31→0x100
- **6-bit → UQ1.8**: `ch6_to_uq18(x) = {1'b0, x[5:0], x[5:4]} + {8'b0, x[5]}` — maps 0→0x000, 63→0x100
- **4-bit → UQ1.8** (BC2 alpha): `ch4_to_uq18(x) = {1'b0, x[3:0], x[3:0]} + {8'b0, x[3]}` — maps 0→0x000, 15→0x100

**From BC1 (FORMAT=0):**

- Expand each RGB565 endpoint to UQ1.8 using `ch5_to_uq18` (R, B) and `ch6_to_uq18` (G)
- Interpolate palette at UQ1.8 precision using shift+add reciprocal-multiply (see BC Division above)
- A: 1-bit punch-through: `0→9'h000` (transparent), `1→9'h100` (opaque)

**From BC2 (FORMAT=1):**

- RGB: decoded as BC1 color block above
- A: 4-bit explicit alpha expanded via `ch4_to_uq18`

**From BC3 (FORMAT=2):**

- RGB: decoded as BC1 color block above
- A: 8-bit interpolated alpha (6 or 8-entry BC3 alpha palette), expanded via `ch8_to_uq18`

**From BC4 (FORMAT=3):**

- Decoded single channel via BC3 alpha interpolation, expanded via `ch8_to_uq18`
- Replicated to R=G=B (grayscale); A=`9'h100` (opaque)

**From RGB565 (FORMAT=5):**

- Expand channels via `ch5_to_uq18` (R, B) and `ch6_to_uq18` (G)
- A=`9'h100` (opaque)

**From RGBA8888 (FORMAT=6):**

- Each channel expanded via `ch8_to_uq18`

**From R8 (FORMAT=7):**

- Expanded via `ch8_to_uq18`, replicated to R=G=B; A=`9'h100` (opaque)

**Onward Conversion to Q4.12:**

After cache read, texels are promoted to Q4.12 signed fixed-point format for pipeline processing (REQ-004.02).
This document is the authoritative source for the promotion formula.
The RTL implementation lives in `spi_gpu/src/fp_types_pkg.sv` as named conversion functions; the `texel_promote.sv` module applies them.

Each 9-bit UQ1.8 channel is promoted to Q4.12 by left-shifting 4 bits: `Q412 = {3'b0, uq18[8:0], 3'b0}`
(This maps UQ1.8 value 0x100 = 1.0 to Q4.12 value 0x1000 = 1.0; UQ1.8 LSB resolution 2^-8 maps to Q4.12 resolution 2^-12 * 2^4 = 2^-8, so no precision is lost.)
All four channels (R, G, B, A) use the same formula.

All Q4.12 values represent signed fixed-point in range [−8.0, +7.999], where UNORM [0, 1] maps to [0x0000, 0x1000].

**UV Coordinate Format at Cache Lookup:**

UV coordinates consumed by Stage 1 (Texture Cache Lookup) arrive from UNIT-005 (Rasterizer) in Q4.12 format (16-bit signed: sign at [15], integer bits at [14:12], fractional bits at [11:0]).
The coordinates are fully perspective-corrected by the rasterizer (UNIT-005 performs the 1/Q division internally); UNIT-006 receives true U, V values and does not perform any further perspective division.
The block address and set index computation uses the integer portion `uv[14:12]` for the block coordinate, and the sub-texel fractional portion `uv[11:0]` for bilinear weight computation.
Note: the current `pixel_pipeline.sv` implementation contains an incorrect Q1.15 comment and bit extraction at this stage (audit finding F4b); the correct format is Q4.12 as defined here.

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
- Clears all valid bits for the affected sampler's L1 (128 cache lines) and L2 caches
- No explicit flush register required (implicit invalidation only)
- Next texture access after invalidation is guaranteed L1 + L2 miss
- Stale data is never served after configuration change

**Cross-Sampler Independence:**
- Invalidating sampler N does not affect the other sampler
- Each sampler maintains independent valid bit arrays

#### Cache Miss Handling Protocol

On L1 cache miss, the pipeline checks L2 before falling through to SDRAM:

```text
Pixel needs texel → L1 lookup
  → L1 hit: return 4 texels from 4 banks (single cycle bilinear quad)
  → L1 miss: L2 lookup
    → L2 hit: decompress 4×4 block → fill L1 → return
    → L2 miss: SDRAM burst → fill L2 → decompress → fill L1 → return
```

**L1 Miss / L2 Hit (fast path):**

1. **Stall Pipeline:** No pixel output until fill completes
2. **L2 Read:** Read compressed block from L2 backing store (format-aware entry count)
3. **Decompression/Conversion:** Transform source format to UQ1.8 per channel (see conversion table above)
4. **L1 Bank Write:** Write 16 decompressed texels to 4 interleaved L1 EBR banks
5. **L1 Replacement:** Select victim way using pseudo-LRU policy (per set)
6. **Resume Pipeline:** Output requested texels and continue processing

**L1 Miss / L2 Miss (SDRAM path):**

1. **Stall Pipeline:** No pixel output until fill completes
2. **SDRAM Burst Read Request:** Issue a burst read to UNIT-007 (Memory Arbiter) with:
   - **Start address:** Computed block address in SDRAM (from INT-014 layout, 4×4 block-tiled)
   - **Burst length (`burst_len`):** Number of sequential 16-bit words to read

| Format   | FORMAT code | burst_len | Bytes | L2 entries | Reason                                        |
|----------|-------------|-----------|-------|------------|-----------------------------------------------|
| BC1      | 0           | 4         | 8     | 1          | 64-bit BC1 block                              |
| BC2      | 1           | 8         | 16    | 2          | 128-bit BC2 block                             |
| BC3      | 2           | 8         | 16    | 2          | 128-bit BC3 block                             |
| BC4      | 3           | 4         | 8     | 1          | 64-bit BC4 block                              |
| RGB565   | 5           | 16        | 32    | 4          | 16 × 16-bit pixels                            |
| RGBA8888 | 6           | 32        | 64    | 8          | 16 × 32-bit pixels                            |
| R8       | 7           | 8         | 16    | 2          | 16 × 8-bit pixels (packed two per 16-bit word)|

3. **L2 Fill:** Pack SDRAM burst data into L2 backing store (4 u16 words per u64 entry, little-endian)
4. **Decompression/Conversion:** Transform source format to UQ1.8 per channel
5. **L1 Bank Write:** Write 16 decompressed texels to 4 interleaved L1 EBR banks
6. **L1 Replacement:** Select victim way using pseudo-LRU policy (per set)
7. **Resume Pipeline:** Output requested texels and continue processing

**SDRAM Fill Latency (at 100 MHz `clk_core`):**

- BC1/BC4: ~11 cycles / 110 ns (ACTIVATE + tRCD + READ + CL=3 latency + 4 burst data cycles)
- BC2/BC3/R8: ~19 cycles / 190 ns (8 burst data cycles)
- RGB565: ~23 cycles / 230 ns (16 burst data cycles)
- RGBA8888: ~39 cycles / 390 ns (32 burst data cycles)

**Note on SDRAM burst latency:**
When consecutive cache fills target the same SDRAM row (common for spatially adjacent texture blocks), the row activation can be skipped, reducing fill latency toward the CAS-only baseline.

The texture cache and SDRAM controller share the same 100 MHz clock domain, so cache fill SDRAM reads are synchronous single-domain transactions with no CDC overhead.

**L1 Replacement Policy:**

- Pseudo-LRU per set (32 sets, each with 4 ways)
- Avoids thrashing for sequential access patterns (e.g., horizontal scanline sweeps)

#### L1 Set Indexing (XOR Folding)

L1 cache set index is computed using XOR-folded addressing to distribute spatially adjacent blocks across different cache sets:

```
block_x = pixel_x >> 2
block_y = pixel_y >> 2
set = (block_x[4:0] ^ block_y[4:0])  // XOR of low 5 bits → 32 sets
```

**Rationale:** XOR indexing distributes adjacent blocks across different sets, avoiding the systematic aliasing that arises from linear indexing when texture rows map to the same set indices.

**Properties:**

- Vertically adjacent blocks map to different cache sets
- Horizontally adjacent blocks map to different cache sets
- No systematic aliasing patterns for typical texture access
- 32 sets covers a 32×32 block area (128×128 texels); the L2 backstop ensures L1 misses are fast

#### L1 Cache Address Space

Each L1 cache line is identified by:

- **Tag:** Unique identifier for the 4×4 block
  - Texture base address: `tex_cfg.BASE_ADDR` (from TEX0_CFG/TEX1_CFG register)
  - Mipmap level: `mip_level[3:0]` (0-15); derived from the rasterizer-supplied `frag_lod` (UQ4.4, 8-bit: integer mip level in bits [7:4], trilinear blend fraction in bits [3:0]) after UNIT-006 applies the TEXn_MIP_BIAS offset; the 4-bit integer portion maps directly to `mip_level[3:0]`
  - Block address: Computed from UV coordinates and mip level (bits above the 5-bit set index)
- **Set:** 5-bit index (0-31) from XOR-folded block coordinates
- **Way:** 2-bit index (0-3) for 4-way set associativity

**L1 Capacity per Sampler**:

- 128 cache lines × 16 texels/line = 2,048 texels (~45×45 texture equivalent)
- 128 lines × 36 bits/texel × 16 texels = 9,216 bytes = 9 KB per sampler (18 KB total)

**L1 EBR Usage per Sampler**:

- 4 PDPW16KD 512×36 bilinear banks = 4 EBR per sampler; 8 EBR total for 2 samplers
- Each bank stores 128 lines × 4 texels/bank = 512 entries (fully utilized)
- Bank address: `{cache_line_index[6:0], texel_within_bank[1:0]}` = 9 bits → 512 entries

#### L2 Compressed Block Cache

The L2 cache stores raw compressed/uncompressed SDRAM block data, avoiding SDRAM round-trips when the same block is needed again after L1 eviction.

**EBR Geometry:** 4 × DP16KD 1024×16 = 1024 × 64-bit entries per sampler (4 EBR per sampler).

**Format-Aware Packing:**

Each texture format occupies a different number of 64-bit entries per 4×4 block.
Block data is packed as 4 u16 words per u64 entry (little-endian).

| Format   | Entries/block | Capacity (blocks) | Notes                           |
|----------|---------------|-------------------|---------------------------------|
| BC1      | 1             | 1024              | 128×128 texture fits entirely   |
| BC4      | 1             | 1024              | 128×128 texture fits entirely   |
| BC2      | 2             | 512               | 128×128 at 50%                  |
| BC3      | 2             | 512               | 128×128 at 50%                  |
| R8       | 2             | 512               | 128×128 at 50%                  |
| RGB565   | 4             | 256               | 64×64 texture fits entirely     |
| RGBA8888 | 8             | 128               | 45×45 texture fits entirely     |

**L2 Addressing:**

Direct-mapped with format-dependent slot count:

```text
entries_per_block = {BC1: 1, BC4: 1, BC2: 2, BC3: 2, R8: 2, RGB565: 4, RGBA8888: 8}
num_slots = 1024 / entries_per_block
slot = (base_words ^ block_index) % num_slots
data_base = slot * entries_per_block
```

**L2 Tag:** `(base_words, block_index)` per slot, with a valid bit.

#### EBR Budget

**Total EBR per Sampler:** 4 (L1) + 4 (L2) = 8 EBR.
**Total for 2 Samplers:** 16 EBR.

**EBR Budget Note:** The ECP5-25K provides 56 EBR blocks total.
The texture cache uses 16 EBR (2 samplers × 8 EBR), consuming 29% of available EBR.
See REQ-011.02 for the complete resource budget.

## Constraints

- Maximum 2 texture samplers (0-1)
- L1: 2,048 texels per sampler (32 sets × 4 ways × 16 texels/line)
- L2: 1,024 × 64-bit entries per sampler (format-aware packing)
- Cache line size fixed at 4×4 texels (16 texels)
- L1 cache line format (UQ1.8) is internal to cache (not exposed to firmware)
- Both L1 and L2 are write-through (texture writes not supported)
- Both caches are non-coherent (invalidation required on texture change via TEXn_CFG write)
- RGBA8888 and R8 formats incur the highest SDRAM fill latency due to larger burst sizes; prefer compressed formats for performance-sensitive textures
- The format-select mux in the pixel pipeline routes the L2 data to the appropriate decoder module (one of six standalone decoders: `texture_bc2.sv`, `texture_bc3.sv`, `texture_bc4.sv`, `texture_rgb565.sv`, `texture_rgba8888.sv`, `texture_r8.sv`) based on `tex_format[3:0]` (INT-010 TEXn_FMT bits [5:2])
- BC palette interpolation uses shift+add reciprocal-multiply (not Verilog `/`) for deterministic synthesis; see BC Division note in UQ1.8 format section

## Notes

### XOR Set Indexing

XOR set indexing (both L1 and L2) is a hardware-only optimization; no physical texture memory layout change is required in SDRAM.
The 4×4 block-tiled layout in SDRAM (INT-014) remains unchanged.

### Alpha Precision

Alpha is stored at 9-bit UQ1.8 precision using the same correction-term expansion as color channels (see channel expansion formulas above), preserving the full decoder output precision for all source formats including BC2 (4-bit explicit alpha via `ch4_to_uq18`) and BC3 (8-bit interpolated alpha via `ch8_to_uq18`).

### Cache Coherency

The cache is non-coherent: texture data is read-only from the GPU's perspective.
If firmware modifies texture data in SDRAM via `MEM_DATA` writes, it must invalidate the affected sampler's cache by writing to `TEX0_CFG` or `TEX1_CFG` (even if the value doesn't change).

### Design Rationale

See DD-010 in [design_decisions.md](../design/design_decisions.md) for architectural rationale behind per-sampler caches and XOR set indexing.
See DD-038 for the UQ1.8 format selection and DD-037 for the PDPW16KD primitive choice.
DD-040 (switchable 18/36-bit cache mode) has been superseded; the cache now uses UQ1.8 exclusively.

### References

- **INT-010 (GPU Register Map):** TEX0_CFG, TEX1_CFG register definitions
- **INT-014 (Texture Memory Layout):** Source texture block addressing in SDRAM
- **UNIT-006 (Pixel Pipeline):** Cache implementation details (4-way set associative, pseudo-LRU, EBR usage)
- **REQ-003.06 (Texture Sampling):** Cache-aware sampling pipeline behavior
- **REQ-003.07 (Texture Mipmapping):** Cache handles mip-level blocks with distinct tags

### Verification

- **VER-005** (`texture_decoder_tb`): Unit testbench verifying texture decoders produce correct UQ1.8 output.
  Tests all seven source formats (BC1–BC4, RGB565, RGBA8888, R8) and confirms correct encoding per the conversion table above.
- **VER-012** (Textured triangle golden image test): Integration test exercising the full cache + decode + sample path.
  The integration simulation harness must model (or stub) the SDRAM miss-handling protocol defined in the Cache Miss Handling Protocol section above, including correct burst lengths per format and the IDLE → FETCH → DECOMPRESS → WRITE_BANKS → IDLE fill FSM.
