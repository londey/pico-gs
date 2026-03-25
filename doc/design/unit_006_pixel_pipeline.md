# UNIT-006: Pixel Pipeline

## Purpose

Stipple test, depth range clipping, early Z-test, texture dispatch to UNIT-011, color combination, alpha blending, ordered dithering, and framebuffer write.
UNIT-006 is a thin pipeline orchestrator: it sequences fragment processing stages and passes UV/LOD/configuration signals to UNIT-011 (Texture Sampler), receiving back Q4.12 texel data for the color combiner.

## Implements Requirements

- REQ-002.02 (Gouraud Shaded Triangle)
- REQ-004.01 (Color Combiner)
- REQ-004.02 (Extended Precision Fragment Processing)
- REQ-005.01 (Framebuffer Management)
- REQ-005.02 (Depth Tested Triangle)
- REQ-005.03 (Alpha Blending)
- REQ-005.04 (Enhanced Z-Buffer)
- REQ-005.06 (Framebuffer Format)
- REQ-005.07 (Z-Buffer Operations)
- REQ-005.09 (Double-Buffered Rendering) — writes to off-screen render target via FB_CONFIG
- REQ-005.10 (Ordered Dithering)
- REQ-004 (Fragment Processor / Color Combiner)
- REQ-005 (Blend / Frame Buffer Store)
- REQ-011.01 (Performance Targets)
- REQ-011.02 (Resource Constraints)

## Interfaces

### Provides

None (texture cache architecture is now provided by UNIT-011).

### Consumes

- INT-010 (GPU Register Map) — non-texture registers (RENDER_MODE, Z_RANGE, FB_CONFIG, FB_CONTROL, CC_MODE, CONST_COLOR, STIPPLE_PATTERN)
- INT-011 (SDRAM Memory Layout)

### Internal Interfaces

- Receives fragment data (position, UV, color, Z) from UNIT-005 (Rasterizer)
- Forwards UV coordinates, LOD, and TEXn_CFG configuration to UNIT-011 (Texture Sampler); receives Q4.12 RGBA texel results
- Reads/writes Z-buffer via UNIT-007 (Z-buffer tile cache)
- Reads framebuffer pixel for alpha blending via UNIT-007
- Receives render mode, dither, blend, scissor, and Z-range configuration from UNIT-003 (Register File)
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
- Perspective-correct UV coordinates per texture unit (up to 2 sets: UV0, UV1), each component in Q4.12 signed fixed-point (16-bit: sign at [15], integer bits [14:12], fractional bits [11:0]); these are true U, V values — perspective correction is performed inside the rasterizer (UNIT-005.05) before emission
- Per-pixel level-of-detail `frag_lod` (UQ4.4) from rasterizer (UNIT-005); integer part selects the mip level, fractional part is the trilinear blend weight
- Interpolated vertex colors (SHADE0, SHADE1) as Q4.12 from rasterizer (UNIT-005)
- Interpolated Z depth value (16-bit unsigned)
- Register state (CC_MODE, CONST_COLOR, RENDER_MODE, Z_RANGE, FB_CONFIG, FB_CONTROL, STIPPLE_PATTERN)

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

UNIT-011 delivers texel data to UNIT-006 already in Q4.12 format; UNIT-006 passes these values unchanged to UNIT-010.

### Internal State

- Z-buffer tile cache (4-way, 16 sets, 4×4 tiles, write-back)
- Hi-Z metadata update channel: on every Z-write (when `Z_WRITE_EN=1` and the fragment passes all tests), the pixel pipeline sends the written Z value and tile index to UNIT-005.06 (Hi-Z Block Metadata); if the new Z is less than the stored `min_z` bucket value, the metadata entry is updated to `min_z = new_z[15:8]`

### Algorithm / Behavior

The pixel pipeline processes rasterized fragments through a staged pipeline.
Texture operations are delegated to UNIT-011, which delivers Q4.12 RGBA texel results back to UNIT-006.
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

**Stage 1–3: Texture Sampling (delegated to UNIT-011):**

UNIT-006 forwards the fragment's UV coordinates, `frag_lod`, and register-file configuration (TEX0_CFG, TEX1_CFG) to UNIT-011.
UNIT-011 performs UV coordinate processing, cache lookup, block decompression, and format promotion, then returns TEX_COLOR0 and TEX_COLOR1 in Q4.12 RGBA format.
If UNIT-011 encounters a cache miss, it stalls the UNIT-006 pipeline until the fill completes.
See UNIT-011 for the detailed texture sampling design.

**Output to UNIT-010 (Color Combiner):**

- TEX_COLOR0, TEX_COLOR1 (Q4.12 RGBA from UNIT-011, or Q4.12 white/zero if unit disabled)
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
- If RENDER_MODE.Z_WRITE_EN=1: write Z value to Z-buffer tile cache (write-back to SDRAM); additionally, send the written Z and tile index to UNIT-005.06 (Hi-Z Block Metadata) via the Hi-Z update channel — if `new_z[15:8] < stored_min_z` (or `valid=0`), the metadata entry is updated to record the new minimum
- Alpha channel is discarded (RGB565 has no alpha storage)

### Tiled Framebuffer Address Calculation

The framebuffer and Z-buffer use 4×4 block-tiled layout (INT-011).
For a pixel at (x, y) in a surface with width `2^WIDTH_LOG2` pixels, where `WIDTH_LOG2 = fb_width_log2` from UNIT-003 (Register File):

```
block_x   = x >> 2
block_y   = y >> 2
local_x   = x & 3
local_y   = y & 3
block_idx = (block_y << (WIDTH_LOG2 - 2)) | block_x
byte_addr = base + block_idx * 32 + (local_y * 4 + local_x) * 2
```

`WIDTH_LOG2` is taken from the `fb_width_log2` output of UNIT-003 at the time of the write.
It is never hardcoded; different render passes (e.g. rendering to a 256-wide off-screen target vs. the 512-wide display framebuffer) use whatever value FB_CONFIG.WIDTH_LOG2 holds.

Both color and Z values are 16 bits per pixel; each 4×4 block occupies 32 bytes.

## Implementation

- `shared/fp_types_pkg.sv`: Q4.12 fixed-point type, constants, and promotion functions (shared package)
- `components/pixel-write/rtl/pixel_pipeline.sv`: Main implementation
- `components/pixel-write/rtl/fb_promote.sv`: RGB565→Q4.12 framebuffer readback promotion (REQ-004.02)
- `components/alpha-blend/rtl/alpha_blend.sv`: Q4.12 alpha blend operations (REQ-004.02)
- `components/dither/rtl/dither.sv`: Ordered dithering with blue noise EBR (REQ-005.10)
- `components/early-z/rtl/early_z.sv`: Depth range test + early Z-test logic
- `components/stipple/rtl/stipple.sv`: Stipple pattern test

Texture sampling RTL (texture decoders, texture cache, texel promotion) is owned by UNIT-011.

## Verification

- **VER-002** (`tb_early_z` — Verilator unit testbench; covers REQ-005.02 early Z-test path)
- **VER-010** (Gouraud Triangle Golden Image Test)
- **VER-011** (Depth-Tested Overlapping Triangles Golden Image Test)
- **VER-012** (Textured Triangle Golden Image Test)
- **VER-013** (Color-Combined Output Golden Image Test)
- **VER-014** (Textured Cube Golden Image Test)

## Design Notes

**Arbiter port ownership:** UNIT-006 owns arbiter ports 1, 2, and 3 (UNIT-007):
- Port 1: framebuffer write (RGB565, tiled 4×4)
- Port 2: Z-buffer read/write (tile-cache backed, write-back)
- Port 3: texture cache fill reads (burst, format-dependent burst_len) — issued on behalf of UNIT-011

Port 3 is shared with `PERF_TIMESTAMP` writes initiated by `gpu_top.sv` on behalf of UNIT-003.
Timestamp writes are fire-and-forget single-word writes at the lowest priority on port 3; the pixel pipeline's texture burst requests have effective precedence because the arbiter serves port 3 requests in arrival order and texture bursts hold port 3 for up to 32 words.
See DD-026 for the port 3 sharing rationale and the latch-and-serialize scheme used in `gpu_top.sv`.

The pipeline operates at 100 MHz in a unified clock domain with the SDRAM controller.
This eliminates CDC FIFOs and synchronizers for all memory transactions (framebuffer, Z-buffer, texture), simplifying the design and reducing latency.

All color data in the pipeline uses Q4.12 signed fixed-point (16-bit per channel, 64-bit for RGBA).
UNORM inputs (vertex colors, material constants) are promoted to Q4.12 at pipeline entry.
UNIT-011 promotes texture samples to Q4.12 before delivering them to UNIT-006.
The signed representation naturally handles the `(A-B)` subtraction in the color combiner, and the 3-bit integer headroom above 1.0 accommodates additive blending without premature saturation.

The framebuffer and Z-buffer use 4×4 block-tiled layout (INT-011).
The tiled address calculation uses only shifts and masks; no multiply hardware is required.
Render targets with power-of-two dimensions can be bound directly as texture sources (format RGB565 tiled) with no copy or conversion step.

**Fragment bus UV semantics:** UNIT-006 receives true perspective-correct U, V coordinates in Q4.12 format on the fragment bus.
Perspective correction (1/Q division and UV reconstruction) is fully handled by UNIT-005.05 before fragment emission.
UNIT-006 forwards UV values to UNIT-011 unchanged; no perspective division occurs within the pixel pipeline.

**Architectural separation:** The pixel pipeline is decomposed into peer units:

1. **UNIT-011 (Texture Sampler):** UV coordinate processing, two-level texture cache (L1 decoded + L2 compressed), block decompression for all eight texture formats, format promotion to Q4.12.
   Delivers TEX_COLOR0, TEX_COLOR1 in Q4.12 RGBA to UNIT-006.
2. **UNIT-006 (this unit):** Stipple test, depth range clipping, early Z-test, dispatches fragment UV/LOD to UNIT-011, receives Q4.12 texel results, passes them to UNIT-010.
3. **UNIT-010 (Color Combiner):** Two-stage pipelined programmable color combiner `(A-B)*C+D`.
   Takes TEX_COLOR0, TEX_COLOR1, SHADE0, SHADE1, CONST0, CONST1, COMBINED as inputs.
   Outputs combined fragment color downstream.
4. **Fragment Output (alpha blend + dither + write):** Alpha blending with framebuffer, frame/Z buffer read/write, ordered dithering, pixel write (implemented within UNIT-006).

**Estimated FPGA Resources (UNIT-006 only, excluding UNIT-011):**

- Q4.12 alpha blend pipeline: ~2-4 DSP slices, ~500-800 LUTs
- FB promotion: ~200-400 LUTs (combinational)
- Dither module: 1 EBR block (256×18 blue noise), ~100-200 LUTs
- Total pipeline latency: ~13-16 cycles at 100 MHz (130-160 ns), fully pipelined, 1 pixel/cycle throughput (100 Mpixels/sec peak)
