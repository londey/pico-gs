# REQ-024: Texture Sampling

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement texture sampling with format-specific decoding for RGBA4444 and BC1 formats.

## Rationale

This requirement defines the functional behavior of the texture sampling subsystem, including format-specific decoding algorithms that convert stored texture data into RGBA8 values for the rendering pipeline.

## Parent Requirements

None

## Allocated To

- UNIT-006 (Pixel Pipeline)

## Interfaces

- INT-010 (GPU Register Map) - TEXn_FMT register (format, dimensions, swizzle)
- INT-011 (SDRAM Memory Layout) - Texture memory region
- INT-014 (Texture Memory Layout) - Format specifications and addressing
- INT-032 (Texture Cache Architecture)

## Functional Requirements

### FR-024-1: RGBA4444 Decoding

The pixel pipeline SHALL decode RGBA4444 texture data as follows:

1. Read 16-bit pixel value from texture memory (little-endian)
2. Extract 4-bit channels: R4=[15:12], G4=[11:8], B4=[7:4], A4=[3:0]
3. Expand to 8-bit: `R8 = (R4 << 4) | R4` (replicate high nibble)
4. Repeat for G, B, A channels
5. Output RGBA8 value for further processing

**Rationale:** Replicating high nibble preserves correct intensity mapping
(0xF -> 0xFF, 0x8 -> 0x88, 0x0 -> 0x00).

### FR-024-2: BC1 Block Decompression

The pixel pipeline SHALL decode BC1 compressed texture data as follows:

1. **Address calculation:**
   - block_x = pixel_x / 4
   - block_y = pixel_y / 4
   - block_addr = texture_base + (block_y * blocks_per_row + block_x) * 8

2. **Read block data (8 bytes):**
   - color0 (bytes 0-1): RGB565, little-endian u16
   - color1 (bytes 2-3): RGB565, little-endian u16
   - indices (bytes 4-7): 32 bits, little-endian u32

3. **Generate color palette:**
   ```
   palette[0] = decode_rgb565(color0)
   palette[1] = decode_rgb565(color1)

   if (color0 > color1):  // as u16 comparison
       palette[2] = (2*palette[0] + palette[1]) / 3  // interpolate
       palette[3] = (palette[0] + 2*palette[1]) / 3  // interpolate
       alpha[0..3] = 255  // fully opaque
   else:
       palette[2] = (palette[0] + palette[1]) / 2    // interpolate
       palette[3] = RGB(0, 0, 0)                     // black
       alpha[0..2] = 255                             // opaque
       alpha[3] = 0                                  // transparent (1-bit alpha)
   ```

4. **Extract pixel index:**
   - texel_offset = (pixel_y % 4) * 4 + (pixel_x % 4)
   - index = (indices >> (texel_offset * 2)) & 0x3

5. **Output pixel:**
   - RGBA8 = (palette[index].rgb, alpha[index])

**RGB565 decoding:**
```
R8 = ((rgb565 >> 11) & 0x1F) << 3  // 5 bits -> 8 bits
G8 = ((rgb565 >> 5) & 0x3F) << 2   // 6 bits -> 8 bits
B8 = (rgb565 & 0x1F) << 3          // 5 bits -> 8 bits
```

### FR-024-3: Swizzle Application

After texture decode, apply swizzle pattern (TEXn_FMT.SWIZZLE) to
reorder or replicate channels. See INT-010 for swizzle encoding.

### FR-024-4: Texture Coordinate Wrapping

Apply UV wrapping mode (TEXn_WRAP) before addressing. See REQ-012.

For BC1 textures, wrapping must respect 4x4 block boundaries.

### FR-024-5: Cache-Aware Sampling Pipeline

Texture sampling SHALL first check the per-sampler texture cache (REQ-131):

1. Apply UV wrapping (FR-024-4) and compute texel coordinates
2. Compute cache set index using XOR-folded addressing and compare tags
3. On cache hit: read decompressed RGBA5652 texels directly from interleaved banks (1 cycle for 2x2 bilinear quad)
4. On cache miss: stall pipeline, fetch 4x4 block from SDRAM (CAS latency + burst transfer), decompress to RGBA5652, fill cache line, then resume sampling
5. Apply swizzle pattern (FR-024-3) after reading from cache
6. Bilinear filtering operates on 4 texels read in parallel from the interleaved banks within each sampler's cache

**Note**: The cache stores decompressed RGBA5652 texels, so format-specific decoding (FR-024-1, FR-024-2) occurs only on cache miss during the fill operation, not on every texel access.
Each of the 2 texture samplers has its own independent cache (REQ-131).

### FR-024-6: Texture Format Promotion to 10.8

After cache read, texture pixel data SHALL be promoted from RGBA5652 to 10.8 fixed-point:

- **R5→R10:** left shift 5, replicate top 5 bits to bottom 5 (`{R5, R5}`)
- **G6→G10:** left shift 4, replicate top 6 bits to bottom 4 (`{G6, G6[5:2]}`)
- **B5→B10:** left shift 5, replicate top 5 bits to bottom 5 (`{B5, B5}`)
- **A2→A10:** expand (00→0, 01→341, 10→682, 11→1023)

Fractional bits are zero after promotion. Promotion occurs in a dedicated pipeline stage (1 cycle, pipelined).

See REQ-134 for 10.8 fixed-point format details.

## Verification Method

**Test:** Execute relevant test suite for texture sampling, including:

- [ ] RGBA4444 decode produces correct RGBA8 output for all 4-bit channel values
- [ ] BC1 decode produces correct output for 4-color mode (color0 > color1)
- [ ] BC1 decode produces correct output for 1-bit alpha mode (color0 <= color1)
- [ ] BC1 color interpolation matches reference implementation
- [ ] Swizzle patterns apply correctly to decoded RGBA values
- [ ] UV wrapping modes work correctly with block-organized textures
- [ ] Texture cache hit returns correct RGBA5652 texels
- [ ] Texture cache miss triggers SDRAM fetch and correct cache fill
- [ ] Bilinear 2x2 quad reads from interleaved banks simultaneously on cache hit
- [ ] Cache invalidation on TEXn_BASE/TEXn_FMT write prevents stale data
- [ ] RGBA5652→10.8 promotion produces correct values for all component ranges
- [ ] A2 expansion produces correct 10-bit alpha values (0, 341, 682, 1023)

## Notes

Functional requirements grouped from specification.
See INT-014 for detailed format specifications.

The system supports 2 texture samplers (TEX0, TEX1), each with an independent cache (REQ-131).
Texture colors produced by sampling feed into the color combiner stage (REQ-009).
