# UNIT-006: Pixel Pipeline

## Purpose

Texture sampling, blending, z-test, framebuffer write

## Implements Requirements

- REQ-003 (Flat Shaded Triangle)
- REQ-004 (Gouraud Shaded Triangle)
- REQ-005 (Depth Tested Triangle)
- REQ-006 (Textured Triangle)
- REQ-008 (Multi-Texture Rendering)
- REQ-009 (Texture Blend Modes)
- REQ-010 (Compressed Textures)
- REQ-011 (Swizzle Patterns)
- REQ-012 (UV Wrapping Modes)
- REQ-013 (Alpha Blending)
- REQ-014 (Enhanced Z-Buffer)
- REQ-016 (Triangle-Based Clearing)
- REQ-024 (Texture Sampling)
- REQ-027 (Z-Buffer Operations)
- REQ-028 (Alpha Blending)
- REQ-131 (Texture Cache)

## Interfaces

### Provides

None

### Consumes

- INT-010 (GPU Register Map)
- INT-011 (SRAM Memory Layout)
- INT-014 (Texture Memory Layout)

### Internal Interfaces

TBD

## Design Description

### Inputs

- Fragment position (x, y) from rasterizer (UNIT-005)
- Interpolated UV coordinates (per texture unit)
- Interpolated vertex color (for Gouraud shading)
- Interpolated Z depth value
- Register state (TEXn_FMT, TEXn_BASE, TEXn_BLEND, TEXn_WRAP, TRI_MODE, etc.)

### Outputs

- Pixel color (RGB565) to framebuffer
- Z value to Z-buffer (if Z_WRITE enabled)

### Internal State

- Texture decode pipeline registers
- Per-sampler texture cache (4 caches, each with 4x1024x18-bit EBR banks)
- Cache tags, valid bits, and pseudo-LRU replacement state per sampler
- Cache fill state machine (SRAM read + decompress + bank write)

### Algorithm / Behavior

The pixel pipeline processes rasterized fragments through the following stages:

0. **Texture Cache Lookup (per enabled texture unit, REQ-131):**
   - Apply UV wrapping mode (REQ-012, TEXn_WRAP)
   - Compute block_x = pixel_x / 4, block_y = pixel_y / 4
   - Compute cache set = (block_x[5:0] ^ block_y[5:0]) (XOR set indexing)
   - Compare tags across 4 ways in the sampler's cache
   - **HIT:** Read 4 bilinear texels from interleaved banks (1 cycle)
   - **MISS:** Stall pipeline, execute cache fill (see below), then read texels

1. **Texture Sampling (per enabled texture unit):**
   - On cache hit: read decompressed RGBA5652 texels directly from cache banks
   - On cache miss: fetch 4x4 block from SRAM, decompress, fill cache line:
     - FORMAT=00 (RGBA4444): Read 32 bytes from SRAM, convert to RGBA5652
     - FORMAT=01 (BC1): Read 8 bytes from SRAM, decompress to RGBA5652
   - Apply swizzle pattern (REQ-011, TEXn_FMT.SWIZZLE)

2. **Multi-Texture Blending:**
   - Sample up to 4 texture units (TEX0-TEX3)
   - Blend sequentially using TEXn_BLEND modes (REQ-009)
   - TEX0_BLEND is ignored (first texture is passthrough)

3. **Shading:**
   - Multiply by interpolated vertex color if GOURAUD enabled (REQ-004)

4. **Z-Buffer Test:**
   - Compare fragment Z with Z-buffer value (REQ-027)
   - Z_COMPARE function from FB_ZBUFFER register
   - Early discard if test fails

5. **Alpha Blending:**
   - Blend with framebuffer using ALPHA_BLEND mode (REQ-013, REQ-028)

6. **Framebuffer Write:**
   - Convert RGBA8 to RGB565 (REQ-025)
   - Write to framebuffer at FB_DRAW address
   - If Z_WRITE enabled, write Z value to Z-buffer

### Implementation Notes

**RGBA4444 Decoder (SystemVerilog):**
```systemverilog
// Extract 4-bit channels from 16-bit pixel
wire [3:0] r4 = pixel_data[15:12];
wire [3:0] g4 = pixel_data[11:8];
wire [3:0] b4 = pixel_data[7:4];
wire [3:0] a4 = pixel_data[3:0];

// Expand to 8-bit by replicating high nibble
wire [7:0] r8 = {r4, r4};
wire [7:0] g8 = {g4, g4};
wire [7:0] b8 = {b4, b4};
wire [7:0] a8 = {a4, a4};
```

**BC1 Decoder (High-Level Design):**
- Implement 4-stage pipeline:
  1. **Block fetch:** Read 8 bytes from SRAM (2 cycles on 16-bit bus = 4 reads)
  2. **Color palette generation:** RGB565 decode + interpolation
  3. **Index extraction:** 2-bit lookup from 32-bit index word
  4. **Color output:** Select palette entry, apply alpha
- RGB565 -> RGB888 conversion using shift and replicate
- Color interpolation using fixed-point dividers (divide-by-3 or divide-by-2)
- Alpha mode detection: compare color0 vs color1 as u16

**Texture Cache Architecture (REQ-131):**

Each sampler has an independent 4-way set-associative texture cache:

```
Per-Sampler Cache:
  4 x EBR blocks (1024x18-bit each), interleaved by texel parity:
    Bank 0: (even_x, even_y) texels — 4 per cache line, 1024 entries
    Bank 1: (odd_x, even_y)  texels — 4 per cache line, 1024 entries
    Bank 2: (even_x, odd_y)  texels — 4 per cache line, 1024 entries
    Bank 3: (odd_x, odd_y)   texels — 4 per cache line, 1024 entries

  256 cache lines = 64 sets x 4 ways
  Cache line = 4x4 block of RGBA5652 (18 bits/texel)
  Tag = texture_base[31:12] + mip_level[3:0] + block_addr (sufficient bits)

  Set index = block_x[5:0] ^ block_y[5:0]  (XOR-folded)
  Replacement: pseudo-LRU per set

Cache Fill State Machine:
  IDLE → FETCH → DECOMPRESS → WRITE_BANKS → IDLE
  - BC1:      4 SRAM reads (8 bytes) + decompress → ~8 cycles
  - RGBA4444: 16 SRAM reads (32 bytes) + convert  → ~18 cycles

Invalidation:
  - TEXn_BASE or TEXn_FMT write → clear all valid bits for sampler N
```

**Estimated FPGA Resources:**
- RGBA4444 decoder: ~20 LUTs, 0 DSPs
- BC1 decoder: ~150-200 LUTs, 2-4 DSPs (for division)
- Texture cache (per sampler): 4 EBR blocks (1024x18), ~200-400 LUTs (tags, comparators, FSM)
- Texture cache (all 4 samplers): 16 EBR blocks total (288 Kbits), ~800-1600 LUTs

## Implementation

- `spi_gpu/src/render/pixel_pipeline.sv`: Main implementation
- `spi_gpu/src/render/texture_rgba4444.sv`: RGBA4444 decoder (new)
- `spi_gpu/src/render/texture_bc1.sv`: BC1 decoder (new)
- `spi_gpu/src/render/texture_cache.sv`: Per-sampler texture cache (new, REQ-131)

## Verification

- Testbench for RGBA4444 decoder: verify all 16 nibble values expand correctly
- Testbench for BC1 decoder: verify 4-color and 1-bit alpha modes
- Integration test with rasterizer: render textured triangles and compare to reference
- Testbench for texture cache: verify hit/miss behavior, tag matching, and replacement
- Cache invalidation test: verify TEXn_BASE/TEXn_FMT writes invalidate cache
- Bilinear interleaving test: verify 2x2 quad reads from 4 different banks
- XOR set indexing test: verify adjacent blocks map to different sets
- Cache fill test: verify SRAM read + decompress + bank write pipeline

## Design Notes

Migrated from speckit module specification. Updated for RGBA4444/BC1 texture formats (v3.0).
