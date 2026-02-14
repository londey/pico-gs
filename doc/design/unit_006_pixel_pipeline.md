# UNIT-006: Pixel Pipeline

## Purpose

Depth range clipping, early Z-test, texture sampling, blending, framebuffer write

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
- REQ-132 (Ordered Dithering)
- REQ-134 (Extended Precision Fragment Processing)
- REQ-025 (Framebuffer Format)

## Interfaces

### Provides

- INT-032 (Texture Cache Architecture)

### Consumes

- INT-010 (GPU Register Map)
- INT-011 (SRAM Memory Layout)
- INT-014 (Texture Memory Layout)
- INT-032 (Texture Cache Architecture)

### Internal Interfaces

- Receives fragment data (position, UV, color, Z) from UNIT-005 (Rasterizer)
- Reads texture data from SRAM via UNIT-007 (SRAM Arbiter) texture port
- Reads/writes framebuffer for alpha blending via UNIT-007
- Receives texture configuration (base address, format, dimensions) from UNIT-003 (Register File)
- Receives dither and blend mode configuration from UNIT-003
- Outputs final RGB565 pixel + Z value to SRAM via UNIT-007

## Clock Domain

The pixel pipeline runs at 100 MHz (`clk_core`), in the same clock domain as the SRAM controller (UNIT-007).
This eliminates all clock domain crossing logic for framebuffer reads/writes, Z-buffer reads/writes, and texture data fetches.
All SRAM arbiter requests and responses are synchronous single-clock-domain transactions.

The pixel clock (`clk_pixel`, 25 MHz) is derived as a synchronous 4:1 divisor from `clk_core`.
The pipeline processes fragments at the full 100 MHz rate; scanout to the display operates at 25 MHz.

## Design Description

### Inputs

- Fragment position (x, y) from rasterizer (UNIT-005)
- Interpolated UV coordinates (per texture unit)
- Interpolated vertex color (for Gouraud shading)
- Interpolated Z depth value
- Register state (TEXn_FMT, TEXn_BASE, TEXn_BLEND, TEXn_WRAP, TRI_MODE, etc.)

### Outputs

- Pixel color (RGB565) to framebuffer via SRAM arbiter (if COLOR_WRITE_EN=1)
- Z value to Z-buffer (if Z_WRITE_EN=1)

### Pipeline Data Format

All internal fragment processing uses **10.8 fixed-point format** (18 bits per channel):
- Bits [17:8]: 10-bit integer part (range 0-1023, with 2-bit overflow headroom above 255)
- Bits [7:0]: 8-bit fractional part (precision 1/256)
- Matches ECP5 DSP slice width (18×18 multipliers) for efficient multiply operations

### Internal State

- Texture decode pipeline registers
- Per-sampler texture cache (4 caches, each with 4x1024x18-bit EBR banks)
- Cache tags, valid bits, and pseudo-LRU replacement state per sampler
- Cache fill state machine (SRAM read + decompress + bank write)

### Algorithm / Behavior

The pixel pipeline processes rasterized fragments through a 7-stage pipeline. All color operations use 10.8 fixed-point format (REQ-134).

**Stage 0: Depth Range Test + Early Z-Test:**
- **Depth Range Test** (Z Scissor): Compare fragment Z against Z_RANGE register (0x31):
  - If `fragment_z < Z_RANGE_MIN` or `fragment_z > Z_RANGE_MAX`: discard fragment immediately
  - No SRAM access required (register comparison only)
  - When Z_RANGE_MIN=0x0000 and Z_RANGE_MAX=0xFFFF: all fragments pass (effectively disabled)
- **Early Z-Test** (REQ-027, RENDER_MODE.Z_COMPARE):
  - Read Z-buffer value at fragment (x, y) from SRAM
  - Compare fragment Z against Z-buffer using Z_COMPARE function
  - If test fails: discard fragment, skip all subsequent stages (no texture fetch, no FB write)
  - If test passes: continue to Stage 1
  - **Bypass conditions**: Early Z-test is skipped (fragment always passes) when:
    - RENDER_MODE.Z_TEST_EN = 0 (depth testing disabled)
    - RENDER_MODE.Z_COMPARE = ALWAYS (110)
  - Z-buffer write deferred to Stage 6 (ensures only visible fragments update Z)

**Stage 1: Texture Cache Lookup (per enabled texture unit, REQ-131):**
- Apply UV wrapping mode (REQ-012, TEXn_WRAP)
- Compute block_x = pixel_x / 4, block_y = pixel_y / 4
- Compute cache set = (block_x[5:0] ^ block_y[5:0]) (XOR set indexing)
- Compare tags across 4 ways in the sampler's cache
- **HIT:** Read 4 bilinear texels from interleaved banks (1 cycle)
- **MISS:** Stall pipeline, execute cache fill (see below), then read texels

**Stage 2: Texture Sampling (per enabled texture unit):**
- On cache hit: read decompressed RGBA5652 texels directly from cache banks
- On cache miss: fetch 4x4 block from SRAM, decompress, fill cache line:
  - FORMAT=00 (RGBA4444): Read 32 bytes from SRAM, convert to RGBA5652
  - FORMAT=01 (BC1): Read 8 bytes from SRAM, decompress to RGBA5652
- Apply swizzle pattern (REQ-011, TEXn_FMT.SWIZZLE)

**Stage 3: Format Promotion (RGBA5652 → 10.8):**
- Promote texture data to 10.8 fixed-point via `texel_promote.sv` (combinational):
  - R5→R10: `{R5, R5}` (left shift 5, replicate MSBs)
  - G6→G10: `{G6, G6[5:2]}` (left shift 4, replicate MSBs)
  - B5→B10: `{B5, B5}` (left shift 5, replicate MSBs)
  - A2→A10: expand (00→0, 01→341, 10→682, 11→1023)
- Fractional bits are zero after promotion

**Stage 4: Multi-Texture Blending (10.8 precision):**
- Blend up to 4 texture units sequentially using TEXn_BLEND modes (REQ-009)
- TEX0_BLEND is ignored (first texture is passthrough)
- Blend operations use 18×18 DSP multipliers:
  - **MULTIPLY:** `result = (a * b) >> 8`
  - **ADD:** `result = saturate(a + b)` at 10-bit integer max (1023)
  - **SUBTRACT:** `result = saturate(a - b)` at 0
  - **INVERSE_SUBTRACT:** `result = saturate(b - a)` at 0

**Stage 5: Vertex Color Modulation (Gouraud) + Alpha Blending (10.8 precision):**
- Multiply by rasterizer's interpolated RGBA (10.8) if GOURAUD enabled (REQ-004)
- `result = (tex_color * vtx_color) >> 8` per component using DSP multipliers
- For alpha blending (REQ-013, REQ-028):
  1. Read destination pixel from framebuffer (RGB565)
  2. Promote to 10.8 via `fb_promote.sv`: same MSB replication as texture promotion, alpha defaults to 1023
  3. Blend in 10.8: `result = (src * alpha + dst * (1023 - alpha)) >> 8`

**Stage 6: Ordered Dithering + Framebuffer Write + Z Write:**
- If DITHER_MODE.ENABLE=1 (REQ-132):
  1. Read dither matrix entry indexed by `{screen_y[3:0], screen_x[3:0]}` from EBR
  2. Scale 6-bit dither values per channel: top 3 bits for R/B (8→5 loss), top 2 bits for G (8→6 loss)
  3. Add scaled dither to fractional bits below RGB565 threshold
  4. Carry propagates into integer part if needed
- Extract upper bits from 10-bit integer: R[9:5]→R5, G[9:4]→G6, B[9:5]→B5
- Pack into RGB565
- If RENDER_MODE.COLOR_WRITE_EN=1: write color to framebuffer at FB_DRAW address
- If RENDER_MODE.Z_WRITE_EN=1: write Z value to Z-buffer
- Alpha channel is discarded (RGB565 has no alpha storage)

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

Cache Fill State Machine (same clock domain as SRAM, no CDC):
  IDLE → FETCH → DECOMPRESS → WRITE_BANKS → IDLE
  - BC1:      4 SRAM reads (8 bytes) + decompress → ~8 cycles (80 ns at 100 MHz)
  - RGBA4444: 16 SRAM reads (32 bytes) + convert  → ~18 cycles (180 ns at 100 MHz)

Invalidation:
  - TEXn_BASE or TEXn_FMT write → clear all valid bits for sampler N
```

**Estimated FPGA Resources:**
- RGBA4444 decoder: ~20 LUTs, 0 DSPs
- BC1 decoder: ~150-200 LUTs, 2-4 DSPs (for division)
- Texture cache (per sampler): 4 EBR blocks (1024x18), ~200-400 LUTs (tags, comparators, FSM)
- Texture cache (all 4 samplers): 16 EBR blocks total (288 Kbits), ~800-1600 LUTs
- 10.8 blend/shade pipeline: ~8-12 DSP slices (18×18 multipliers), ~1500-2500 LUTs
- Texel/FB promotion: ~200-400 LUTs (combinational)
- Dither module: 1 EBR block (256×18 blue noise), ~100-200 LUTs
- Total pipeline latency: ~13-16 cycles at 100 MHz (130-160 ns), fully pipelined, 1 pixel/cycle throughput (100 Mpixels/sec peak)

## Implementation

- `spi_gpu/src/render/pixel_pipeline.sv`: Main implementation
- `spi_gpu/src/render/texture_rgba4444.sv`: RGBA4444 decoder
- `spi_gpu/src/render/texture_bc1.sv`: BC1 decoder
- `spi_gpu/src/render/texture_cache.sv`: Per-sampler texture cache (REQ-131)
- `spi_gpu/src/render/texel_promote.sv`: RGBA5652→10.8 promotion (REQ-134)
- `spi_gpu/src/render/fb_promote.sv`: RGB565→10.8 framebuffer readback promotion (REQ-134)
- `spi_gpu/src/render/texture_blend.sv`: 10.8 texture blend operations (REQ-134)
- `spi_gpu/src/render/alpha_blend.sv`: 10.8 alpha blend operations (REQ-134)
- `spi_gpu/src/render/dither.sv`: Ordered dithering with blue noise EBR (REQ-132)
- `spi_gpu/src/render/early_z.sv`: Depth range test + early Z-test logic

## Verification

- Testbench for RGBA4444 decoder: verify all 16 nibble values expand correctly
- Testbench for BC1 decoder: verify 4-color and 1-bit alpha modes
- Integration test with rasterizer: render textured triangles and compare to reference
- Testbench for texture cache: verify hit/miss behavior, tag matching, and replacement
- Cache invalidation test: verify TEXn_BASE/TEXn_FMT writes invalidate cache
- Bilinear interleaving test: verify 2x2 quad reads from 4 different banks
- XOR set indexing test: verify adjacent blocks map to different sets
- Cache fill test: verify SRAM read + decompress + bank write pipeline
- Early Z-test: verify discard before texture fetch when Z-test fails
- Early Z-test bypass: verify passthrough when Z_TEST_EN=0 or Z_COMPARE=ALWAYS
- Depth range test: verify discard when fragment Z outside [Z_RANGE_MIN, Z_RANGE_MAX]
- Depth range test disabled: verify passthrough when Z_RANGE_MIN=0x0000, Z_RANGE_MAX=0xFFFF
- COLOR_WRITE_EN: verify Z-only prepass (Z writes without color writes)

## Design Notes

The pipeline operates at 100 MHz in a unified clock domain with the SRAM controller.
This eliminates CDC FIFOs and synchronizers for all memory transactions (framebuffer, Z-buffer, texture), simplifying the design and reducing latency.
The early Z-test (Stage 0) reads the Z-buffer synchronously, and framebuffer writes (Stage 6) complete in the same domain, avoiding multi-cycle CDC handshakes.

Migrated from speckit module specification. Updated for RGBA4444/BC1 texture formats (v3.0).
