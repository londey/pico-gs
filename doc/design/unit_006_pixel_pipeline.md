# UNIT-006: Pixel Pipeline

## Purpose

Depth range clipping, early Z-test, texture sampling, blending, framebuffer write

## Implements Requirements

- REQ-003 (Flat Shaded Triangle)
- REQ-004 (Gouraud Shaded Triangle)
- REQ-005 (Depth Tested Triangle)
- REQ-006 (Textured Triangle)
- REQ-008 (Multi-Texture Rendering — dual-texture per pass)
- REQ-009 (Color Combiner)
- REQ-010 (Compressed Textures)
- REQ-011 (Swizzle Patterns)
- REQ-012 (UV Wrapping Modes)
- REQ-013 (Alpha Blending)
- REQ-014 (Enhanced Z-Buffer)
- REQ-016 (Triangle-Based Clearing)
- REQ-024 (Texture Sampling)
- REQ-027 (Z-Buffer Operations)
- REQ-131 (Texture Cache)
- REQ-132 (Ordered Dithering)
- REQ-134 (Extended Precision Fragment Processing)
- REQ-025 (Framebuffer Format)

## Interfaces

### Provides

- INT-032 (Texture Cache Architecture)

### Consumes

- INT-010 (GPU Register Map)
- INT-011 (SDRAM Memory Layout)
- INT-014 (Texture Memory Layout)
- INT-032 (Texture Cache Architecture)

### Internal Interfaces

- Receives fragment data (position, UV, color, Z) from UNIT-005 (Rasterizer)
- Reads texture data from SDRAM via UNIT-007 (Memory Arbiter) texture port
- Reads/writes framebuffer for alpha blending via UNIT-007
- Receives texture configuration (base address, format, dimensions) from UNIT-003 (Register File)
- Receives dither and blend mode configuration from UNIT-003
- Outputs final RGB565 pixel + Z value to SDRAM via UNIT-007

## Clock Domain

The pixel pipeline runs at 100 MHz (`clk_core`), in the same clock domain as the SDRAM controller and memory arbiter (UNIT-007).
This eliminates all clock domain crossing logic for framebuffer reads/writes, Z-buffer reads/writes, and texture data fetches.
All memory arbiter requests and responses are synchronous single-clock-domain transactions.

The pixel clock (`clk_pixel`, 25 MHz) is derived as a synchronous 4:1 divisor from `clk_core`.
The pipeline processes fragments at the full 100 MHz rate; scanout to the display operates at 25 MHz.

## Design Description

### Inputs

- Fragment position (x, y) from rasterizer (UNIT-005)
- Interpolated UV coordinates per texture unit (up to 2 sets: UV0, UV1)
- Interpolated vertex colors (VER_COLOR0, VER_COLOR1) in 10.8 fixed-point from rasterizer (UNIT-005)
- Interpolated Z depth value
- Register state (TEXn_FMT, TEXn_BASE, TEXn_WRAP, COMBINER_MODE, MAT_COLOR0, MAT_COLOR1, TRI_MODE, etc.)

### Outputs

- Pixel color (RGB565) to framebuffer via Memory Arbiter (if COLOR_WRITE_EN=1)
- Z value to Z-buffer (if Z_WRITE_EN=1)

### Pipeline Data Format

All internal fragment processing uses **10.8 fixed-point format** (18 bits per channel):
- Bits [17:8]: 10-bit integer part (range 0-1023, with 2-bit overflow headroom above 255)
- Bits [7:0]: 8-bit fractional part (precision 1/256)
- Matches ECP5 DSP slice width (18×18 multipliers) for efficient multiply operations

### Internal State

- Texture decode pipeline registers
- Per-sampler texture cache (2 caches, each with 4x4096x18-bit EBR banks for 16384 texels per sampler)
- Cache tags, valid bits, and pseudo-LRU replacement state per sampler
- Cache fill state machine (burst SDRAM read + decompress + bank write)
- Burst length register (4 for BC1, 16 for RGBA4444) driven to UNIT-007 memory arbiter
- Color combiner configuration registers (COMBINER_MODE, MAT_COLOR0, MAT_COLOR1)

### Algorithm / Behavior

The pixel pipeline processes rasterized fragments through a 7-stage pipeline. All color operations use 10.8 fixed-point format (REQ-134).

**Stage 0: Depth Range Test + Early Z-Test:**
- **Depth Range Test** (Z Scissor): Compare fragment Z against Z_RANGE register (0x31):
  - If `fragment_z < Z_RANGE_MIN` or `fragment_z > Z_RANGE_MAX`: discard fragment immediately
  - No SDRAM access required (register comparison only)
  - When Z_RANGE_MIN=0x0000 and Z_RANGE_MAX=0xFFFF: all fragments pass (effectively disabled)
- **Early Z-Test** (REQ-027, RENDER_MODE.Z_COMPARE):
  - Read Z-buffer value at fragment (x, y) from SDRAM
  - Compare fragment Z against Z-buffer using Z_COMPARE function
  - If test fails: discard fragment, skip all subsequent stages (no texture fetch, no FB write)
  - If test passes: continue to Stage 1
  - **Bypass conditions**: Early Z-test is skipped (fragment always passes) when:
    - RENDER_MODE.Z_TEST_EN = 0 (depth testing disabled)
    - RENDER_MODE.Z_COMPARE = ALWAYS (110)
  - Z-buffer write deferred to Stage 6 (ensures only visible fragments update Z)

**Stage 1: Texture Cache Lookup (per enabled texture unit, up to 2, REQ-131):**
- Apply UV wrapping mode (REQ-012, TEXn_WRAP) for TEX0 and TEX1
- Compute block_x = pixel_x / 4, block_y = pixel_y / 4
- Compute cache set = (block_x[7:0] ^ block_y[7:0]) (XOR set indexing, 8-bit for 256 sets)
- Compare tags across 4 ways in the sampler's cache
- **HIT:** Read 4 bilinear texels from interleaved banks (1 cycle)
- **MISS:** Stall pipeline, execute cache fill (see below), then read texels

**Stage 2: Texture Sampling (per enabled texture unit, up to 2):**
- On cache hit: read decompressed RGBA5652 texels directly from cache banks
- On cache miss: fetch 4x4 block from SDRAM via burst read, decompress, fill cache line:
  - FORMAT=00 (RGBA4444): Burst read 32 bytes from SDRAM (burst_len=16), convert to RGBA5652
  - FORMAT=01 (BC1): Burst read 8 bytes from SDRAM (burst_len=4), decompress to RGBA5652
- Apply swizzle pattern (REQ-011, TEXn_FMT.SWIZZLE)

**Stage 3: Format Promotion (RGBA5652 → 10.8):**
- Promote texture data to 10.8 fixed-point via `texel_promote.sv` (combinational):
  - R5→R10: `{R5, R5}` (left shift 5, replicate MSBs)
  - G6→G10: `{G6, G6[5:2]}` (left shift 4, replicate MSBs)
  - B5→B10: `{B5, B5}` (left shift 5, replicate MSBs)
  - A2→A10: expand (00→0, 01→341, 10→682, 11→1023)
- Fractional bits are zero after promotion
- Also compute Z_COLOR: extract fragment Z high byte [15:8], promote to 10.8 (used for fog/depth-based effects in the color combiner)

**Stage 4: Color Combiner (10.8 precision, REQ-009):**
- The color combiner replaces the previous sequential 4-texture blend stage.
- It accepts up to 7 color inputs, each in 10.8 format:
  - **TEX_COLOR0**: Output from texture unit 0 (or white if TEX0 disabled)
  - **TEX_COLOR1**: Output from texture unit 1 (or white if TEX1 disabled)
  - **VER_COLOR0**: Interpolated primary vertex color from rasterizer (diffuse)
  - **VER_COLOR1**: Interpolated secondary vertex color from rasterizer (specular/emissive)
  - **MAT_COLOR0**: Material-wide color 0 from register MAT_COLOR0 (promoted to 10.8)
  - **MAT_COLOR1**: Material-wide color 1 from register MAT_COLOR1 (promoted to 10.8)
  - **Z_COLOR**: Depth-derived color from fragment Z high byte (for fog effects)
- The combiner evaluates a programmable equation per channel (RGB and A separately):
  - `output = (A - B) * C + D` where A, B, C, D are each selected from the 7 inputs above plus constants ZERO and ONE
  - Input selection is configured via COMBINER_RGB and COMBINER_ALPHA registers (see INT-010)
  - This single-cycle equation supports common effects:
    - **Modulate (diffuse × texture):** A=TEX_COLOR0, B=ZERO, C=VER_COLOR0, D=ZERO → `TEX0 * VER0`
    - **Decal (texture only):** A=TEX_COLOR0, B=ZERO, C=ONE, D=ZERO → `TEX0`
    - **Add specular:** A=TEX_COLOR0, B=ZERO, C=VER_COLOR0, D=VER_COLOR1 → `TEX0 * VER0 + VER1`
    - **Dual-texture blend:** A=TEX_COLOR0, B=TEX_COLOR1, C=VER_COLOR0.A, D=TEX_COLOR1 → `lerp(TEX1, TEX0, VER0.A)`
    - **Fog:** A=result, B=Z_COLOR_LUT, C=Z_COLOR, D=Z_COLOR_LUT → `lerp(FOG_COLOR, result, fog_factor)`
- Blend operations use 18×18 DSP multipliers:
  - **MULTIPLY:** `result = (a * b) >> 8`
  - **ADD:** `result = saturate(a + b)` at 10-bit integer max (1023)
  - **SUBTRACT:** `result = saturate(a - b)` at 0

**Stage 5: Alpha Blending (10.8 precision):**
- For alpha blending (REQ-013):
  1. Read destination pixel from framebuffer (RGB565)
  2. Promote to 10.8 via `fb_promote.sv`: same MSB replication as texture promotion, alpha defaults to 1023
  3. Blend in 10.8: `result = (src * alpha + dst * (1023 - alpha)) >> 8`
- Note: Vertex color modulation is now handled by the color combiner in Stage 4.
  The alpha value used for framebuffer blending comes from the combiner alpha output.

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
  1. **Block fetch:** Read 8 bytes from SDRAM via burst read (burst_len=4 on 16-bit bus)
  2. **Color palette generation:** RGB565 decode + interpolation
  3. **Index extraction:** 2-bit lookup from 32-bit index word
  4. **Color output:** Select palette entry, apply alpha
- RGB565 -> RGB888 conversion using shift and replicate
- Color interpolation using fixed-point dividers (divide-by-3 or divide-by-2)
- Alpha mode detection: compare color0 vs color1 as u16

**Texture Cache Architecture (REQ-131):**

Each of the 2 samplers has an independent 4-way set-associative texture cache with 16384 texels (16K) capacity:

```
Per-Sampler Cache (2 samplers total):
  4 x EBR blocks (4096x18-bit each), interleaved by texel parity:
    Bank 0: (even_x, even_y) texels — 4 per cache line, 4096 entries
    Bank 1: (odd_x, even_y)  texels — 4 per cache line, 4096 entries
    Bank 2: (even_x, odd_y)  texels — 4 per cache line, 4096 entries
    Bank 3: (odd_x, odd_y)   texels — 4 per cache line, 4096 entries

  1024 cache lines = 256 sets x 4 ways
  Cache line = 4x4 block of RGBA5652 (18 bits/texel)
  Tag = texture_base[31:12] + mip_level[3:0] + block_addr (sufficient bits)

  Set index = block_x[7:0] ^ block_y[7:0]  (XOR-folded, 8-bit for 256 sets)
  Replacement: pseudo-LRU per set

Cache Fill State Machine (same clock domain as SDRAM controller, no CDC):
  IDLE → FETCH → DECOMPRESS → WRITE_BANKS → IDLE
  - FETCH issues a burst SDRAM read request to UNIT-007 with the required
    transfer length (burst_len), eliminating per-word address setup overhead.
    The arbiter streams sequential 16-bit words back on consecutive cycles
    after an initial CAS latency delay.
  - BC1:      burst_len=4 (8 bytes) → ~11 cycles (110 ns at 100 MHz)
             (ACTIVATE + tRCD + READ + CL=3 + 4 data cycles, plus decompress + write)
  - RGBA4444: burst_len=16 (32 bytes) → ~23 cycles (230 ns at 100 MHz)
             (ACTIVATE + tRCD + READ + CL=3 + 16 data cycles,
              plus convert + write overlapped with final data cycles)

Invalidation:
  - TEXn_BASE or TEXn_FMT write → clear all valid bits for sampler N (N=0..1)
```

**EBR Budget Note:** Each 4096x18-bit bank requires 4 physical EBR blocks (each EBR is 1024x18).
Per sampler: 4 banks × 4 EBR = 16 EBR.
Two samplers: 32 EBR total for texture cache.
The ECP5-25K has 56 EBR blocks; the texture cache consumes 32, leaving 24 for dither (1), scanline FIFO (1), LUT (1), and other uses.
This is a significant increase from the previous 16 EBR (4 samplers × 4 EBR), but the 4× larger per-sampler cache substantially improves hit rates, reducing SDRAM bandwidth pressure.

**Estimated FPGA Resources:**
- RGBA4444 decoder: ~20 LUTs, 0 DSPs
- BC1 decoder: ~150-200 LUTs, 2-4 DSPs (for division)
- Texture cache (per sampler): 16 EBR blocks (4×4096x18), ~300-500 LUTs (tags, comparators, FSM)
- Texture cache (both samplers): 32 EBR blocks total (576 Kbits), ~600-1000 LUTs
- Color combiner: ~4-6 DSP slices (18×18 multipliers for (A-B)*C+D per channel), ~800-1200 LUTs (input muxes, saturation)
- 10.8 alpha blend pipeline: ~2-4 DSP slices, ~500-800 LUTs
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
- `spi_gpu/src/render/color_combiner.sv`: Programmable color combiner with (A-B)*C+D equation (REQ-009, REQ-134)
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
- Cache fill test: verify burst SDRAM read + decompress + bank write pipeline
- Burst read test: verify correct burst_len issued for BC1 (4) and RGBA4444 (16)
- Burst latency test: verify cache fill completes within expected SDRAM latency (accounting for row activate + CAS delay)
- Early Z-test: verify discard before texture fetch when Z-test fails
- Early Z-test bypass: verify passthrough when Z_TEST_EN=0 or Z_COMPARE=ALWAYS
- Depth range test: verify discard when fragment Z outside [Z_RANGE_MIN, Z_RANGE_MAX]
- Depth range test disabled: verify passthrough when Z_RANGE_MIN=0x0000, Z_RANGE_MAX=0xFFFF
- COLOR_WRITE_EN: verify Z-only prepass (Z writes without color writes)
- Color combiner: verify (A-B)*C+D equation for modulate mode (TEX0 * VER_COLOR0)
- Color combiner: verify decal mode (TEX0 passthrough with C=ONE, B=D=ZERO)
- Color combiner: verify dual-texture lerp (lerp between TEX0 and TEX1 using VER_COLOR0.A)
- Color combiner: verify fog mode (lerp between scene color and Z_COLOR-derived fog color)
- Color combiner: verify add-specular mode (TEX0 * VER_COLOR0 + VER_COLOR1)
- Color combiner: verify MAT_COLOR0 and MAT_COLOR1 inputs are correctly promoted to 10.8
- Color combiner: verify saturation at 10-bit max (1023) and clamping at 0

## Design Notes

The pipeline operates at 100 MHz in a unified clock domain with the SDRAM controller.
This eliminates CDC FIFOs and synchronizers for all memory transactions (framebuffer, Z-buffer, texture), simplifying the design and reducing latency.
The early Z-test (Stage 0) reads the Z-buffer synchronously, and framebuffer writes (Stage 6) complete in the same domain, avoiding multi-cycle CDC handshakes.

The cache fill FSM issues burst SDRAM read requests to UNIT-007, specifying a burst length equal to the number of 16-bit words needed for the texture block (4 for BC1, 16 for RGBA4444).
Burst reads eliminate the per-word address setup overhead present in single-word accesses, though SDRAM introduces additional latency from row activation and CAS delay compared to async SRAM.
The burst length is determined by the texture format register (TEXn_FMT) and does not change during a cache fill operation.
Cache miss latency is higher than with async SRAM due to SDRAM row activate and CAS latency overhead, but burst throughput is comparable once the first word arrives.

Migrated from speckit module specification. Updated for RGBA4444/BC1 texture formats (v3.0). Updated for SDRAM burst read support (v3.2).

**v10.0 dual-texture + color combiner update:** Reduced from 4 texture units to 2 per pass.
Increased per-sampler cache from 4096 to 16384 texels (16K), using 16 EBR per sampler (32 EBR total for 2 samplers).

**Architectural separation (v10.0):** The pixel pipeline is being decomposed into separate units:

1. **UNIT-006 (this unit):** Depth range clipping, early Z-test, texture sampling (2 units with cache), texture format promotion.
   Outputs TEX_COLOR0, TEX_COLOR1 (plus VER_COLOR0, VER_COLOR1, Z value passthrough) to UNIT-010 via a fragment FIFO.
2. **UNIT-010 (Color Combiner, NEW):** Pipelined programmable color combiner.
   Takes TEX_COLOR0, TEX_COLOR1, VER_COLOR0, VER_COLOR1, MAT_COLOR0, MAT_COLOR1, Z_COLOR as inputs.
   Exact combiner equation and register interface are WIP — see UNIT-010 for details.
   Outputs combined fragment color to a fragment FIFO.
3. **Fragment Output unit (TBD):** Alpha blending with framebuffer, frame/Z buffer read/write.
   Consumes combined fragments from UNIT-010's output FIFO.

The `texture_blend.sv` file is replaced by `color_combiner.sv` (owned by UNIT-010).
Stages 4 (color combiner) and 5/6 (alpha blend, framebuffer write) described in the Algorithm section above will migrate to UNIT-010 and the fragment output unit respectively once those specs are finalized.
