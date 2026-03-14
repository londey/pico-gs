# INT-032: Texture Cache Architecture

## Type

Internal

## Specification

### Overview

The texture cache is a per-sampler cache architecture that stores decompressed 4×4 texel blocks in a selectable intermediate format to enable single-cycle bilinear filtering and reduce SDRAM bandwidth.
Each of the 2 texture samplers maintains an independent cache to avoid inter-sampler contention.
Each sampler has a 16,384-texel cache for improved hit rates on larger textures.
A per-sampler `CACHE_MODE` bit in `TEXn_FMT` selects between 18-bit (RGBA5652) and 36-bit (UQ1.8 per channel) cache line formats; see INT-010.

### Details

#### Format Field Width

The `tex_format` signal that selects the decode path is a **3-bit field** (`[4:2]` of TEXn_FMT; see INT-010).
Seven distinct values (0–6) are defined; value 7 is reserved.
The 3-bit width is the minimum required to encode all seven formats without aliasing.

#### Cache Line Format — Mode Selection

Each sampler's cache operates in one of two modes, selected by `TEXn_FMT.CACHE_MODE` (bit [5] of TEXn_FMT; see INT-010):

| CACHE_MODE | Format             | Bits/texel | Cache line            | EBR primitive      | EBR capacity |
|------------|--------------------|------------|-----------------------|--------------------|--------------|
| 0          | RGBA5652           | 18         | 288 bits (16 texels)  | DP16KD, 1024×18    | 4 EBR/bank   |
| 1          | UQ1.8 per channel  | 36         | 576 bits (16 texels)  | PDPW16KD, 512×36   | 8 EBR/bank   |

Writing `TEXn_FMT` (regardless of which bits change) invalidates the corresponding sampler's cache.
This ensures that toggling `CACHE_MODE` between renders is safe — the first access after the write is guaranteed a cache miss and will fill using the new format.

#### Cache Line Format (RGBA5652) — CACHE_MODE=0

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
- 18-bit width matches ECP5 EBR DP16KD native width (1024×18 configuration)
- Suitable for RGB565 textures and use cases where EBR budget is constrained

**Conversion from Source Formats (RGBA5652):**

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

#### Cache Line Format (UQ1.8 per channel) — CACHE_MODE=1

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

**EBR note:** PDPW16KD in 512×36 mode consumes 8 EBR per bank (4 banks per sampler = 32 EBR per sampler, 64 EBR for 2 samplers).
This exceeds the ECP5-25K budget of 56 EBR when combined with other consumers.
CACHE_MODE=1 is therefore only usable when the overall EBR allocation is verified to fit; see REQ-011.02 and the EBR Budget Note below.

**BC Division — shift+add reciprocal multiply:**
All BC palette interpolation divisions (e.g., `(2*c0 + c1) / 3`, `(c0 + c1) / 2`) are implemented using shift+add reciprocal-multiply rather than Verilog `/` operators.
This ensures deterministic LUT usage: no synthesizer-generated integer dividers are instantiated.
The formulas are:
- Division by 3: `x_div3 = (x * 11'h55) >> 8` (multiply by 85 = 0x55, shift 8; exact for x ≤ 255)
- Division by 2: `x_div2 = x >> 1`

**Conversion from Source Formats (UQ1.8):**

All source-format channel values are first decoded to 8-bit UNORM (values 0–255), then converted to UQ1.8 by appending a leading zero bit: `uq18 = {1'b0, unorm8}`.
This maps UNORM 255 to UQ1.8 0xFF (≈1.0) and UNORM 0 to UQ1.8 0x00.

**From BC1 (FORMAT=0):**
- Expand each RGB565 endpoint to 8-bit using MSB replication: R8=`{R5,R5[4:2]}`, G8=`{G6,G6[5:3]}`, B8=`{B5,B5[4:2]}`
- Interpolate palette at 8-bit precision using shift+add formulas
- Store as UQ1.8: `{1'b0, R8}`, `{1'b0, G8}`, `{1'b0, B8}`
- A: 1-bit punch-through: `0→9'h000` (transparent), `1→9'h100` (opaque)

**From BC2 (FORMAT=1):**
- RGB: decoded as BC1 color block above (8-bit precision)
- A: 4-bit explicit alpha expanded to 8-bit: A8=`{A4, A4}`, stored as `{1'b0, A8}`

**From BC3 (FORMAT=2):**
- RGB: decoded as BC1 color block above (8-bit precision)
- A: 8-bit interpolated alpha (6 or 8-entry BC3 alpha palette at 8-bit precision), stored as `{1'b0, A8}`

**From BC4 (FORMAT=3):**
- Decoded 8-bit single channel R8, replicated to G8=R8, B8=R8
- A: `9'h100` (opaque)
- Stored as `{1'b0, R8}`, `{1'b0, G8}`, `{1'b0, B8}`, `9'h100`

**From RGB565 (FORMAT=4):**
- Expand with MSB replication: R8=`{R5,R5[4:2]}`, G8=`{G6,G6[5:3]}`, B8=`{B5,B5[4:2]}`
- Store as `{1'b0, R8}`, `{1'b0, G8}`, `{1'b0, B8}`, `9'h100` (opaque)

**From RGBA8888 (FORMAT=5):**
- Store directly as `{1'b0, R8}`, `{1'b0, G8}`, `{1'b0, B8}`, `{1'b0, A8}`

**From R8 (FORMAT=6):**
- Store as `{1'b0, R8}`, replicated to all three channels; A=`9'h100` (opaque)

**Onward Conversion to Q4.12:**

After cache read, texels are promoted to Q4.12 signed fixed-point format for pipeline processing (REQ-004.02).
This document is the authoritative source for the promotion formulas.
The RTL implementation lives in `spi_gpu/src/fp_types_pkg.sv` as named conversion functions; the `texel_promote.sv` module applies them.

**CACHE_MODE=0 (RGBA5652) promotion:**
- R5 to Q4.12: Expand to UNORM [0.0, 1.0] using MSB replication: `{3'b0, R5, R5[4:1], 3'b0}`
- G6 to Q4.12: Expand to UNORM [0.0, 1.0] using MSB replication: `{3'b0, G6, G6[5:0], 2'b0}`
- B5 to Q4.12: Same as R5
- A2 to Q4.12: Four-level expansion: 00→0x0000, 01→0x0555, 10→0x0AAA, 11→0x1000

**CACHE_MODE=1 (UQ1.8) promotion:**
- Each 9-bit UQ1.8 channel is promoted to Q4.12 by left-shifting 4 bits: `Q412 = {3'b0, uq18[8:0], 3'b0}`
  (This maps UQ1.8 value 0x100 = 1.0 to Q4.12 value 0x1000 = 1.0; UQ1.8 LSB resolution 2⁻⁸ maps to Q4.12 resolution 2⁻¹²·2⁴ = 2⁻⁸, so no precision is lost.)
- All four channels (R, G, B, A) use the same formula.

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

3. **Decompression/Conversion:** Transform source format to the active cache format (RGBA5652 or UQ1.8 per channel, per CACHE_MODE; see conversion tables above)
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
  - Mipmap level: `mip_level[3:0]` (0-15); derived from the rasterizer-supplied `frag_lod` (UQ4.4, 8-bit: integer mip level in bits [7:4], trilinear blend fraction in bits [3:0]) after UNIT-006 applies the TEXn_MIP_BIAS offset; the 4-bit integer portion maps directly to `mip_level[3:0]`
  - Block address: Computed from UV coordinates and mip level
- **Set:** 8-bit index (0-255) from XOR-folded block coordinates
- **Way:** 2-bit index (0-3) for 4-way set associativity

**Total Cache Capacity per Sampler**:
- 1024 cache lines × 16 texels/line = 16,384 texels (128×128 texture equivalent)
- CACHE_MODE=0: 1024 lines × 18 bits/texel × 16 texels = 18,432 bytes = 18 KB per sampler (36 KB total)
- CACHE_MODE=1: 1024 lines × 36 bits/texel × 16 texels = 36,864 bytes = 36 KB per sampler (72 KB total)

**EBR Usage per Sampler**:

- CACHE_MODE=0 (DP16KD 1024×18): 4 bilinear banks × 4 EBR blocks each = 16 EBR blocks per sampler; 32 EBR total for 2 samplers
- CACHE_MODE=1 (PDPW16KD 512×36): 4 bilinear banks × 8 EBR blocks each = 32 EBR blocks per sampler; 64 EBR total for 2 samplers

**EBR Budget Note**: The ECP5-25K provides 56 EBR blocks total.
CACHE_MODE=0 uses 32 EBR for the texture cache (2 samplers × 16 EBR), consuming 57% of available EBR.
Combined with other EBR consumers (1 dither, 1 LUT, 1 scanline FIFO, 2 command FIFO = 5 EBR), the CACHE_MODE=0 total is 37 EBR out of 56, leaving 19 EBR free.
CACHE_MODE=1 uses 64 EBR for the texture cache alone, which exceeds the ECP5-25K budget and is not feasible for both samplers simultaneously.
A single-sampler CACHE_MODE=1 configuration (32 EBR) combined with CACHE_MODE=0 for the other sampler (16 EBR) totals 48 EBR for the texture cache, leaving 8 EBR for other consumers.
See REQ-011.02 for the complete resource budget.

## Constraints

- Maximum 2 texture samplers (0-1)
- 16,384 texels per sampler cache
- Cache line size fixed at 4×4 texels (16 texels)
- Cache line format (RGBA5652 or UQ1.8) is internal to cache (not exposed to firmware)
- CACHE_MODE=1 (UQ1.8, PDPW16KD 512×36) may not be used for both samplers simultaneously on ECP5-25K due to EBR budget; verify against REQ-011.02 before enabling
- Cache is write-through (texture writes not supported)
- Cache is non-coherent (invalidation required on texture change via TEXn_CFG write, including CACHE_MODE changes)
- In CACHE_MODE=0: BC2/BC3 alpha is truncated to 2 bits in cache (A2); this precision loss is eliminated in CACHE_MODE=1 (full 8-bit alpha stored as UQ1.8)
- RGBA8888 and R8 formats incur the highest fill latency due to larger burst sizes; prefer compressed formats for performance-sensitive textures
- The format-select mux in the pixel pipeline routes the SDRAM burst data to the appropriate decoder module (one of six standalone decoders: `texture_bc2.sv`, `texture_bc3.sv`, `texture_bc4.sv`, `texture_rgb565.sv`, `texture_rgba8888.sv`, `texture_r8.sv`) based on `tex_format[2:0]` (INT-010 TEXn_FMT bits [4:2])
- BC palette interpolation uses shift+add reciprocal-multiply (not Verilog `/`) for deterministic synthesis; see BC Division note in UQ1.8 format section

## Notes

### XOR Set Indexing

XOR set indexing is a hardware-only optimization; no physical texture memory layout change is required in SDRAM.
The 4×4 block-tiled layout in SDRAM (INT-014) remains unchanged.

### Alpha Precision

In CACHE_MODE=0 (RGBA5652), all source formats are reduced to 2-bit alpha in cache.
This is acceptable in that mode because:

- Final framebuffer is RGB565 with no alpha channel stored
- Alpha is only used for blending intermediate results
- 2-bit alpha (4 levels) is sufficient for basic transparency (opaque, mostly opaque, mostly transparent, transparent)
- BC1 1-bit punch-through uses only the 00 and 11 states of the 2-bit field

In CACHE_MODE=1 (UQ1.8), alpha is stored at 9-bit precision (8-bit UNORM with a leading zero bit), eliminating this precision loss.

### Cache Coherency

The cache is non-coherent: texture data is read-only from the GPU's perspective.
If firmware modifies texture data in SDRAM via `MEM_DATA` writes, it must invalidate the affected sampler's cache by writing to `TEX0_CFG` or `TEX1_CFG` (even if the value doesn't change).

### Design Rationale

See DD-010 in [design_decisions.md](../design/design_decisions.md) for architectural rationale behind per-sampler caches, RGBA5652 format selection, and XOR set indexing.
See DD-011 (to be added) for the rationale behind the switchable 18/36-bit cache mode, UQ1.8 format selection, PDPW16KD primitive choice, and shift+add BC division.

### References

- **INT-010 (GPU Register Map):** TEX0_CFG, TEX1_CFG register definitions
- **INT-014 (Texture Memory Layout):** Source texture block addressing in SDRAM
- **UNIT-006 (Pixel Pipeline):** Cache implementation details (4-way set associative, pseudo-LRU, EBR usage)
- **REQ-003.06 (Texture Sampling):** Cache-aware sampling pipeline behavior
- **REQ-003.07 (Texture Mipmapping):** Cache handles mip-level blocks with distinct tags

### Verification

- **VER-005** (`texture_decoder_tb`): Unit testbench verifying texture decoders for both CACHE_MODE=0 (RGBA5652) and CACHE_MODE=1 (UQ1.8) output.
  Tests all seven source formats (BC1–BC4, RGB565, RGBA8888, R8) in each mode and confirms correct encoding per the conversion tables above.
- **VER-012** (Textured triangle golden image test): Integration test exercising the full cache + decode + sample path.
  The integration simulation harness must model (or stub) the SDRAM miss-handling protocol defined in the Cache Miss Handling Protocol section above, including correct burst lengths per format and the IDLE → FETCH → DECOMPRESS → WRITE_BANKS → IDLE fill FSM.
  Golden images must be re-approved after any CACHE_MODE change, as texel precision differences produce different downstream Q4.12 values and therefore different final RGB565 output pixels.
