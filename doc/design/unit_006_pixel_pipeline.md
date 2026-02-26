# UNIT-006: Pixel Pipeline

## Purpose

Stipple test, depth range clipping, early Z-test, texture sampling, and format promotion to Q4.12

## Implements Requirements

- REQ-002.01 (Flat Shaded Triangle)
- REQ-002.02 (Gouraud Shaded Triangle)
- REQ-003.01 (Textured Triangle)
- REQ-003.02 (Multi-Texture Rendering — dual-texture per pass)
- REQ-003.03 (Compressed Textures)
- REQ-003.04 (Swizzle Patterns)
- REQ-003.05 (UV Wrapping Modes)
- REQ-003.06 (Texture Sampling)
- REQ-003.07 (Texture Mipmapping) — trilinear filtering between adjacent mip levels
- REQ-003.08 (Texture Cache)
- REQ-004.01 (Color Combiner)
- REQ-004.02 (Extended Precision Fragment Processing)
- REQ-005.01 (Framebuffer Management)
- REQ-005.02 (Depth Tested Triangle)
- REQ-005.03 (Alpha Blending)
- REQ-005.04 (Enhanced Z-Buffer)
- REQ-005.05 (Triangle-Based Clearing)
- REQ-005.06 (Framebuffer Format)
- REQ-005.07 (Z-Buffer Operations)
- REQ-005.09 (Double-Buffered Rendering) — writes to off-screen render target via FB_CONFIG
- REQ-005.10 (Ordered Dithering)
- REQ-014.01 (Lightmapped Static Mesh) — dual-texture blending supports lightmap compositing

## Interfaces

### Provides

- INT-032 (Texture Cache Architecture)

### Consumes

- INT-010 (GPU Register Map)
- INT-011 (SDRAM Memory Layout)
- INT-014 (Texture Memory Layout)

### Internal Interfaces

- Receives fragment data (position, UV, color, Z) from UNIT-005 (Rasterizer)
- Reads texture data from SDRAM via UNIT-007 (Memory Arbiter) texture port
- Reads/writes Z-buffer via UNIT-007 (Z-buffer tile cache)
- Reads framebuffer pixel for alpha blending via UNIT-007
- Receives texture configuration (TEX0_CFG, TEX1_CFG) from UNIT-003 (Register File)
- Receives render mode, dither, blend, scissor, and Z-range configuration from UNIT-003
- Receives CC_MODE and CONST_COLOR from UNIT-003 for UNIT-010 (Color Combiner)
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
- Interpolated vertex colors (SHADE0, SHADE1) as Q4.12 from rasterizer (UNIT-005)
- Interpolated Z depth value (16-bit unsigned)
- Register state (TEX0_CFG, TEX1_CFG, CC_MODE, CONST_COLOR, RENDER_MODE, Z_RANGE, FB_CONFIG, FB_CONTROL, STIPPLE_PATTERN)

### Outputs

- Pixel color (RGB565) to framebuffer via Memory Arbiter (if COLOR_WRITE_EN=1)
- Z value to Z-buffer (if Z_WRITE_EN=1)
- Fragment data (TEX_COLOR0, TEX_COLOR1, SHADE0, SHADE1, x, y, Z) to UNIT-010 (Color Combiner)

### Pipeline Data Format

All internal fragment processing uses **Q4.12 signed fixed-point format** (16 bits per channel):
- 1 sign bit, 3 integer bits, 12 fractional bits
- Range: approximately −8.0 to +7.999755859375 (signed)
- UNORM color range [0.0, 1.0] maps to [0x0000, 0x1000]
- 3-bit integer headroom above 1.0 accommodates additive blending without premature saturation
- Matches ECP5 DSP slice width (18×18 multipliers; 16-bit operands occupy the lower 16 bits)

### Internal State

- Texture decode pipeline registers
- Per-sampler texture cache (2 caches, each with 4x4096x18-bit EBR banks for 16384 texels per sampler)
- Cache tags, valid bits, and pseudo-LRU replacement state per sampler
- Cache fill state machine (burst SDRAM read + decompress + bank write)
- Burst length register driven to UNIT-007 memory arbiter (format-dependent, see cache miss handling)
- Z-buffer tile cache (4-way, 16 sets, 4×4 tiles, write-back)

### Algorithm / Behavior

The pixel pipeline processes rasterized fragments through a staged pipeline.
All texture operations deliver results in RGBA5652 cache format, which is promoted to Q4.12 before the color combiner.
Color operations in UNIT-010 and alpha blending use Q4.12 format (REQ-004.02).

**Stage 0a: Stipple Test:**
- If RENDER_MODE.STIPPLE_EN=1: Compute bit index = (y & 7) × 8 + (x & 7); read corresponding bit from STIPPLE_PATTERN register
- If bit is 0: discard fragment (no SDRAM access)
- If bit is 1 or STIPPLE_EN=0: continue

**Stage 0b: Depth Range Test + Early Z-Test:**
- **Depth Range Test** (Z Scissor): Compare fragment Z against Z_RANGE register (0x31):
  - If `fragment_z < Z_RANGE_MIN` or `fragment_z > Z_RANGE_MAX`: discard fragment immediately
  - No SDRAM access required (register comparison only)
  - When Z_RANGE_MIN=0x0000 and Z_RANGE_MAX=0xFFFF: all fragments pass (effectively disabled)
- **Early Z-Test** (REQ-005.07, RENDER_MODE.Z_COMPARE):
  - Read Z-buffer tile cache; issue SDRAM burst on miss
  - Compare fragment Z against Z-buffer using Z_COMPARE function
  - If test fails: discard fragment, skip all subsequent stages
  - **Bypass conditions**: Early Z-test is skipped (fragment always passes) when:
    - RENDER_MODE.Z_TEST_EN = 0 (depth testing disabled)
    - RENDER_MODE.Z_COMPARE = ALWAYS (3'd6)
  - Z-buffer write deferred to final stage (ensures only visible fragments update Z)

**Stage 1: Texture Cache Lookup (per enabled texture unit, up to 2, REQ-003.08):**
- Apply UV wrapping mode (REQ-003.05, TEXn_CFG.U_WRAP / V_WRAP) for TEX0 and TEX1
- Compute block_x = pixel_x >> 2, block_y = pixel_y >> 2
- Compute cache set = (block_x[7:0] ^ block_y[7:0]) (XOR set indexing, 8-bit for 256 sets)
- Compare tags across 4 ways in the sampler's cache
- **HIT:** Read 4 bilinear texels from interleaved banks (1 cycle)
- **MISS:** Stall pipeline, execute cache fill (see below), then read texels

**Stage 2: Texture Sampling (per enabled texture unit, up to 2):**
- On cache hit: read decompressed RGBA5652 texels directly from cache banks
- On cache miss: fetch 4×4 block from SDRAM via burst read, decompress/convert to RGBA5652, fill cache line:
  - FORMAT=BC1 (0): Burst read 8 bytes (burst_len=4), decompress 4-color/alpha blocks to RGBA5652
  - FORMAT=BC2 (1): Burst read 16 bytes (burst_len=8), decompress explicit alpha blocks to RGBA5652
  - FORMAT=BC3 (2): Burst read 16 bytes (burst_len=8), decompress interpolated alpha blocks to RGBA5652
  - FORMAT=BC4 (3): Burst read 8 bytes (burst_len=4), decompress single-channel to RGBA5652 (replicate R→RGB)
  - FORMAT=RGB565 (4): Burst read 32 bytes (burst_len=16), store as RGBA5652 (A=11 = opaque)
  - FORMAT=RGBA8888 (5): Burst read 64 bytes (burst_len=32), convert to RGBA5652 (truncate to RGBA5652 precision)
  - FORMAT=R8 (6): Burst read 16 bytes (burst_len=8), convert to RGBA5652 (R replicated to G and B, A=11)
- Apply swizzle pattern (REQ-003.04, TEXn_CFG.SWIZZLE)
- Trilinear filtering (FILTER=TRILINEAR): blend between adjacent mip levels (requires MIP_LEVELS > 1)

**Stage 3: Format Promotion (RGBA5652 → Q4.12):**
- Promote texture data to Q4.12 via `texel_promote.sv` (combinational):
  - R5 → Q4.12: `{3'b0, R5, 8'b0}` → value = R5/31.0 approximately; exact: `{3'b0, R5, R5[4:1], 3'b0}` to span [0, 1.0]
  - G6 → Q4.12: Expand G6 to Q4.12 in [0, 1.0] range
  - B5 → Q4.12: same as R5
  - A2 → Q4.12: expand (00→0x0000, 01→0x0555, 10→0x0AAA, 11→0x1000)
- Vertex colors (SHADE0, SHADE1) arrive from rasterizer already in Q4.12
- CONST0 and CONST1 (RGBA8888 UNORM8) are promoted to Q4.12 at combiner input
- Also compute Z_FACTOR: extract fragment Z high byte [15:8], scale to Q4.12 [0.0, 1.0] for fog

**Output to UNIT-010 (Color Combiner):**
- TEX_COLOR0, TEX_COLOR1 (Q4.12 RGBA, or Q4.12 white/zero if unit disabled)
- SHADE0, SHADE1 (Q4.12 RGBA passthrough from rasterizer)
- CONST0, CONST1 (Q4.12 promoted from CONST_COLOR register)
- Fragment position (x, y) and Z passthrough

**Alpha Blending (Q4.12 precision, UNIT-010 downstream):**
- For alpha blending (REQ-005.03) after the color combiner:
  1. Read destination pixel from framebuffer (RGB565), promote to Q4.12
  2. Blend in Q4.12 using RENDER_MODE.ALPHA_BLEND selection:
     - **DISABLED:** Overwrite destination
     - **ADD:** `result = saturate(src + dst)` at [0, 1.0]
     - **SUBTRACT:** `result = saturate(src - dst)` at [0.0, 0.0]
     - **BLEND:** `result = src * alpha + dst * (1.0 - alpha)` (Porter-Duff source-over)

**Ordered Dithering + Framebuffer Write + Z Write:**
- If RENDER_MODE.DITHER_EN=1 (REQ-005.10):
  1. Read dither matrix entry indexed by `{screen_y[3:0], screen_x[3:0]}` from EBR
  2. Add dither offset to the Q4.12 value before truncation to RGB565
- Extract UNORM: R5 = clamp(color.R × 31, 0, 31), G6 = clamp(color.G × 63, 0, 63), B5 = clamp(color.B × 31, 0, 31)
- Pack into RGB565
- If RENDER_MODE.COLOR_WRITE_EN=1 and pixel inside scissor: write color to tiled framebuffer at FB_CONFIG address
- If RENDER_MODE.Z_WRITE_EN=1: write Z value to Z-buffer tile cache (write-back to SDRAM)
- Alpha channel is discarded (RGB565 has no alpha storage)

### Tiled Framebuffer Address Calculation

The framebuffer and Z-buffer use 4×4 block-tiled layout (INT-011).
For a pixel at (x, y) in a surface with width 2^WIDTH_LOG2 pixels:

```
block_x   = x >> 2
block_y   = y >> 2
local_x   = x & 3
local_y   = y & 3
block_idx = (block_y << (WIDTH_LOG2 - 2)) | block_x
byte_addr = base + block_idx * 32 + (local_y * 4 + local_x) * 2
```

Both color and Z values are 16 bits per pixel; each 4×4 block occupies 32 bytes.

### Implementation Notes

**Texture Format Decoders:**

Each decoder converts a compressed or uncompressed 4×4 block to 16 RGBA5652 texels.

*BC1 Decoder:*
- Fetch 8 bytes: two 16-bit endpoint colors + 32-bit index word
- Generate 4-color palette: C0, C1, lerp(C0,C1,1/3), lerp(C0,C1,2/3); or C0, C1, lerp(C0,C1,1/2), transparent (if C0 ≤ C1)
- Assign palette entry to each of the 16 texels via 2-bit indices
- Alpha: 1-bit punch-through; 0 = transparent (A2=00), 1 = opaque (A2=11)

*RGB565 Decoder:*
- Fetch 32 bytes (16 × 16-bit pixels), store each as RGBA5652 with A2=11

*RGBA8888 Decoder:*
- Fetch 64 bytes (16 × 32-bit pixels), truncate each to RGBA5652 (R8→R5, G8→G6, B8→B5, A8→A2)

*R8 Decoder:*
- Fetch 16 bytes (16 × 8-bit values), replicate R8 to G and B channels, truncate to RGBA5652 (R8→R5, G=R5, B=R5, A2=11)

*BC2/BC3 Decoders:*
- 16-byte blocks; first 8 bytes encode alpha (explicit 4-bit for BC2, interpolated 8-bit for BC3), last 8 bytes encode RGB as BC1 (no punch-through)

**Texture Cache Architecture (REQ-003.08):**

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
  - FETCH issues a burst SDRAM read request to UNIT-007 with burst_len per format
  - BC1/BC4:       burst_len=4   (8 bytes)
  - BC2/BC3:       burst_len=8   (16 bytes)
  - RGB565:        burst_len=16  (32 bytes)
  - R8:            burst_len=8   (16 bytes)
  - RGBA8888:      burst_len=32  (64 bytes)

Invalidation:
  - TEXn_CFG write → clear all valid bits for sampler N (N=0..1)
```

**EBR Budget Note:** Each 4096x18-bit bank requires 4 physical EBR blocks (each EBR is 1024x18).
Per sampler: 4 banks × 4 EBR = 16 EBR.
Two samplers: 32 EBR total for texture cache.
The ECP5-25K has 56 EBR blocks; the texture cache consumes 32, leaving 24 for dither (1), scanline FIFO (1), command FIFO (2), and other uses.

**Estimated FPGA Resources:**
- BC1 decoder: ~150-200 LUTs, 2-4 DSPs (for division)
- RGB565 decoder: ~30 LUTs, 0 DSPs
- RGBA8888 decoder: ~50 LUTs, 0 DSPs
- R8 decoder: ~20 LUTs, 0 DSPs
- BC2/BC3 decoders: ~200-300 LUTs, 2-4 DSPs
- Texture cache (per sampler): 16 EBR blocks, ~300-500 LUTs (tags, comparators, FSM)
- Texture cache (both samplers): 32 EBR blocks total, ~600-1000 LUTs
- Q4.12 alpha blend pipeline: ~2-4 DSP slices, ~500-800 LUTs
- Texel/FB promotion: ~200-400 LUTs (combinational)
- Dither module: 1 EBR block (256×18 blue noise), ~100-200 LUTs
- Total pipeline latency: ~13-16 cycles at 100 MHz (130-160 ns), fully pipelined, 1 pixel/cycle throughput (100 Mpixels/sec peak)

## Implementation

- `spi_gpu/src/render/pixel_pipeline.sv`: Main implementation
- `spi_gpu/src/render/texture_bc1.sv`: BC1 decoder
- `spi_gpu/src/render/texture_bc2.sv`: BC2 decoder
- `spi_gpu/src/render/texture_bc3.sv`: BC3 decoder
- `spi_gpu/src/render/texture_bc4.sv`: BC4 (single-channel) decoder
- `spi_gpu/src/render/texture_rgb565.sv`: RGB565 uncompressed decoder
- `spi_gpu/src/render/texture_rgba8888.sv`: RGBA8888 uncompressed decoder
- `spi_gpu/src/render/texture_r8.sv`: R8 single-channel decoder
- `spi_gpu/src/render/texture_cache.sv`: Per-sampler texture cache (REQ-003.08)
- `spi_gpu/src/render/texel_promote.sv`: RGBA5652→Q4.12 promotion (REQ-004.02)
- `spi_gpu/src/render/fb_promote.sv`: RGB565→Q4.12 framebuffer readback promotion (REQ-004.02)
- `spi_gpu/src/render/alpha_blend.sv`: Q4.12 alpha blend operations (REQ-004.02)
- `spi_gpu/src/render/dither.sv`: Ordered dithering with blue noise EBR (REQ-005.10)
- `spi_gpu/src/render/early_z.sv`: Depth range test + early Z-test logic
- `spi_gpu/src/render/stipple.sv`: Stipple pattern test

## Verification

Planned formal testbenches (VER documents not yet created; see `doc/verification/README.md` for status):
- **VER-002** (`tb_early_z` — Verilator unit testbench; covers REQ-005.02 early Z-test path)
- **VER-005** (`texture_decoder_tb` — Verilator unit testbench; covers REQ-003.01 texture decode/sampling)
- **VER-010** through **VER-013** (golden image integration tests exercise the full pixel pipeline including texture cache and fragment output)

- Testbench for BC1 decoder: verify 4-color and 1-bit alpha modes
- Testbench for RGB565 decoder: verify all 16 pixels in a 4×4 block store as RGBA5652 with A=opaque
- Testbench for RGBA8888 decoder: verify truncation to RGBA5652 precision
- Testbench for R8 decoder: verify R channel replicated to RGB, A=opaque
- Testbench for BC2/BC3 decoders: verify explicit and interpolated alpha modes
- Integration test with rasterizer: render textured triangles and compare to reference
- Testbench for texture cache: verify hit/miss behavior, tag matching, and replacement
- Cache invalidation test: verify TEX0_CFG / TEX1_CFG writes invalidate the corresponding cache
- Bilinear interleaving test: verify 2x2 quad reads from 4 different banks
- XOR set indexing test: verify adjacent blocks map to different sets
- Cache fill test: verify correct burst_len issued for each texture format
- Early Z-test: verify discard before texture fetch when Z-test fails
- Early Z-test bypass: verify passthrough when Z_TEST_EN=0 or Z_COMPARE=ALWAYS
- Depth range test: verify discard when fragment Z outside [Z_RANGE_MIN, Z_RANGE_MAX]
- Stipple test: verify discard when bit is 0, pass when bit is 1 or STIPPLE_EN=0
- COLOR_WRITE_EN: verify Z-only prepass (Z writes without color writes)
- Q4.12 promotion test: verify RGBA5652 → Q4.12 promotion produces values in [0.0, 1.0]
- Alpha blend BLEND mode: verify Porter-Duff src-over at alpha=0.5 produces correct 50% mix
- Dithering: verify Q4.12-to-RGB565 dithering reduces banding
- VER-002 (Early Z-Test Unit Testbench)
- VER-005 (Texture Decoder Unit Testbench)
- VER-010 (Gouraud Triangle Golden Image Test)
- VER-011 (Depth-Tested Overlapping Triangles Golden Image Test)
- VER-012 (Textured Triangle Golden Image Test)
- VER-013 (Color-Combined Output Golden Image Test)

## Design Notes

**Verilator interactive simulator:** The interactive GPU simulator (REQ-010.02) substitutes a behavioral SDRAM model for the physical W9825G6KH.
The model must faithfully implement W9825G6KH burst mode, CAS latency (CL=3), row activation timing, and auto-refresh behavior so that texture cache fills, Z-buffer accesses, and framebuffer writes from this unit behave correctly in simulation.
A simplified or incorrectly-timed SDRAM model will cause the pixel pipeline to malfunction during interactive simulation; performance observations from the interactive sim (fill rate, frame time) will not precisely reflect hardware timing.
See UNIT-007 for the SDRAM controller interface signals that the behavioral model must implement.

The pipeline operates at 100 MHz in a unified clock domain with the SDRAM controller.
This eliminates CDC FIFOs and synchronizers for all memory transactions (framebuffer, Z-buffer, texture), simplifying the design and reducing latency.

All color data in the pipeline uses Q4.12 signed fixed-point (16-bit per channel, 64-bit for RGBA).
UNORM inputs (vertex colors, material constants, texture samples) are promoted to Q4.12 at pipeline entry.
The signed representation naturally handles the `(A-B)` subtraction in the color combiner, and the 3-bit integer headroom above 1.0 accommodates additive blending without premature saturation.

The cache fill FSM issues burst SDRAM read requests to UNIT-007, specifying burst_len equal to the number of 16-bit words for the texture block.
Burst lengths differ by format: 4 (BC1/BC4), 8 (BC2/BC3/R8), 16 (RGB565), 32 (RGBA8888).

The framebuffer and Z-buffer use 4×4 block-tiled layout (INT-011).
The tiled address calculation uses only shifts and masks; no multiply hardware is required.
Render targets with power-of-two dimensions can be bound directly as texture sources (format RGB565 tiled) with no copy or conversion step.

**Architectural separation:** The pixel pipeline is decomposed into:

1. **UNIT-006 (this unit):** Stipple test, depth range clipping, early Z-test, texture sampling (2 units with cache), format promotion.
   Outputs TEX_COLOR0, TEX_COLOR1 (plus SHADE0, SHADE1, Z value passthrough) to UNIT-010.
2. **UNIT-010 (Color Combiner):** Two-stage pipelined programmable color combiner `(A-B)*C+D`.
   Takes TEX_COLOR0, TEX_COLOR1, SHADE0, SHADE1, CONST0, CONST1, COMBINED as inputs.
   Outputs combined fragment color downstream.
3. **Fragment Output unit (alpha blend + dither + write):** Alpha blending with framebuffer, frame/Z buffer read/write, ordered dithering, pixel write.
