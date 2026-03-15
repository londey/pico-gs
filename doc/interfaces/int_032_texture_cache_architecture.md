# INT-032: Texture Cache Architecture

## Type

Internal

## Specification

### Overview

The texture cache is a per-sampler cache architecture that stores decompressed 4×4 texel blocks in UQ1.8 format (36 bits per texel) to enable single-cycle bilinear filtering and reduce SDRAM bandwidth.
Each of the 2 texture samplers maintains an independent cache to avoid inter-sampler contention.
Each sampler has an 8,192-texel cache using PDPW16KD 512×36 EBR banks.

### Details

#### Format Field Width

The `tex_format` signal that selects the decode path is a **4-bit field** (`[5:2]` of TEXn_FMT; see INT-010).
Eight distinct values (0–7) are defined; values 8–15 are reserved.
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

**EBR note:** PDPW16KD in 512×36 mode uses 4 EBR per bank (4 banks per sampler = 16 EBR per sampler, 32 EBR for 2 samplers).
See REQ-011.02 for the complete resource budget.

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

**From BC5 (FORMAT=4):**

- Two independent BC3-style single-channel alpha blocks packed sequentially in each 16-byte block: first 8 bytes decode the red channel (R8), next 8 bytes decode the green channel (G8)
- Each 8-byte sub-block uses the BC3 alpha block encoding: two 8-bit endpoints followed by 6 bytes of 3-bit indices (FR-024-BC5)
- B: `9'h000` (fixed zero), A: `9'h100` (opaque)
- Stored as `{1'b0, R8}`, `{1'b0, G8}`, `9'h000`, `9'h100`

**From RGB565 (FORMAT=5):**

- Expand with MSB replication: R8=`{R5,R5[4:2]}`, G8=`{G6,G6[5:3]}`, B8=`{B5,B5[4:2]}`
- Store as `{1'b0, R8}`, `{1'b0, G8}`, `{1'b0, B8}`, `9'h100` (opaque)

**From RGBA8888 (FORMAT=6):**

- Store directly as `{1'b0, R8}`, `{1'b0, G8}`, `{1'b0, B8}`, `{1'b0, A8}`

**From R8 (FORMAT=7):**

- Store as `{1'b0, R8}`, replicated to all three channels; A=`9'h100` (opaque)

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
- Clears all valid bits for the affected sampler (512 cache lines)
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

| Format   | FORMAT code | burst_len | Bytes | Reason                                         |
|----------|-------------|-----------|-------|------------------------------------------------|
| BC1      | 0           | 4         | 8     | 64-bit BC1 block                               |
| BC2      | 1           | 8         | 16    | 128-bit BC2 block                              |
| BC3      | 2           | 8         | 16    | 128-bit BC3 block                              |
| BC4      | 3           | 4         | 8     | 64-bit BC4 block                               |
| BC5      | 4           | 8         | 16    | 128-bit BC5 block (two 8-byte sub-blocks)      |
| RGB565   | 5           | 16        | 32    | 16 × 16-bit pixels                             |
| RGBA8888 | 6           | 32        | 64    | 16 × 32-bit pixels                             |
| R8       | 7           | 8         | 16    | 16 × 8-bit pixels (packed two per 16-bit word) |

3. **Decompression/Conversion:** Transform source format to UQ1.8 per channel (see conversion table above)
4. **Bank Write:** Write 16 decompressed texels to 4 interleaved EBR banks
5. **Replacement:** Select victim way using pseudo-LRU policy (per set)
6. **Resume Pipeline:** Output requested texels and continue processing

**Cache Fill Latency (at 100 MHz `clk_core`):**
- BC1/BC4: ~11 cycles / 110 ns (ACTIVATE + tRCD + READ + CL=3 latency + 4 burst data cycles)
- BC2/BC3/BC5/R8: ~19 cycles / 190 ns (8 burst data cycles)
- RGB565: ~23 cycles / 230 ns (16 burst data cycles)
- RGBA8888: ~39 cycles / 390 ns (32 burst data cycles)

**Note on SDRAM burst latency:**
When consecutive cache fills target the same SDRAM row (common for spatially adjacent texture blocks), the row activation can be skipped, reducing fill latency toward the CAS-only baseline.

Note: The texture cache and SDRAM controller share the same 100 MHz clock domain, so cache fill SDRAM reads are synchronous single-domain transactions with no CDC overhead.

**Replacement Policy:**
- Pseudo-LRU per set (128 sets, each with 4 ways)
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
- 512 cache lines × 16 texels/line = 8,192 texels (~90×90 texture equivalent)
- 512 lines × 36 bits/texel × 16 texels = 36,864 bytes = 36 KB per sampler (72 KB total)

**EBR Usage per Sampler**:

- PDPW16KD 512×36: 4 bilinear banks × 4 EBR blocks each = 16 EBR blocks per sampler; 32 EBR total for 2 samplers

**EBR Budget Note**: The ECP5-25K provides 56 EBR blocks total.
The texture cache uses 32 EBR (2 samplers × 16 EBR), consuming 57% of available EBR.
Combined with other EBR consumers (1 dither, 1 LUT, 1 scanline FIFO, 2 command FIFO = 5 EBR), the total is 37 EBR out of 56, leaving 19 EBR free.
See REQ-011.02 for the complete resource budget.

## Constraints

- Maximum 2 texture samplers (0-1)
- 8,192 texels per sampler cache
- Cache line size fixed at 4×4 texels (16 texels)
- Cache line format (UQ1.8) is internal to cache (not exposed to firmware)
- Cache is write-through (texture writes not supported)
- Cache is non-coherent (invalidation required on texture change via TEXn_CFG write)
- RGBA8888 and R8 formats incur the highest fill latency due to larger burst sizes; prefer compressed formats for performance-sensitive textures
- The format-select mux in the pixel pipeline routes the SDRAM burst data to the appropriate decoder module (one of seven standalone decoders: `texture_bc2.sv`, `texture_bc3.sv`, `texture_bc4.sv`, `texture_bc5.sv`, `texture_rgb565.sv`, `texture_rgba8888.sv`, `texture_r8.sv`) based on `tex_format[3:0]` (INT-010 TEXn_FMT bits [5:2])
- BC palette interpolation uses shift+add reciprocal-multiply (not Verilog `/`) for deterministic synthesis; see BC Division note in UQ1.8 format section

## Notes

### XOR Set Indexing

XOR set indexing is a hardware-only optimization; no physical texture memory layout change is required in SDRAM.
The 4×4 block-tiled layout in SDRAM (INT-014) remains unchanged.

### Alpha Precision

Alpha is stored at 9-bit UQ1.8 precision (8-bit UNORM with a leading zero bit), preserving the full decoder output precision for all source formats including BC2 (4-bit explicit alpha expanded to 8-bit) and BC3 (8-bit interpolated alpha).

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
  Tests all eight source formats (BC1–BC5, RGB565, RGBA8888, R8) and confirms correct encoding per the conversion table above.
- **VER-012** (Textured triangle golden image test): Integration test exercising the full cache + decode + sample path.
  The integration simulation harness must model (or stub) the SDRAM miss-handling protocol defined in the Cache Miss Handling Protocol section above, including correct burst lengths per format and the IDLE → FETCH → DECOMPRESS → WRITE_BANKS → IDLE fill FSM.
