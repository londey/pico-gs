# UNIT-006: Pixel Pipeline

## Purpose

Stipple test, depth range clipping, early Z-test, texture dispatch to UNIT-011, color combination (three passes via UNIT-010), ordered dithering, and framebuffer write via the color tile cache (UNIT-013).
UNIT-006 is a thin pipeline orchestrator: it sequences fragment processing stages and passes UV/LOD/configuration signals to UNIT-011 (Texture Sampler), receiving back Q4.12 texel data for the color combiner.

UNIT-006 implements the **Pixel Pipeline** substage of the Render Pipeline as defined in ARCHITECTURE.md.
Fragments arrive from UNIT-005 having already passed through the Block Pipeline (Hi-Z Test, Z Tile Load, Color Tile Load, and Edge Test + Interpolation).
The color tile cache (UNIT-013) pre-fetches the current destination tile's RGB565 pixels from SDRAM; it feeds the `DST_COLOR` operand to the Pixel Pipeline's color combiner passes.
The Z tile pre-fetch (**Z Tile Load**) is performed by UNIT-012 (Z-Buffer Tile Cache) and supplies per-fragment stored Z values to the early Z-test stage of this unit.

## Implements Requirements

- REQ-002.02 (Gouraud Shaded Triangle)
- REQ-004.01 (Color Combiner)
- REQ-004.02 (Extended Precision Fragment Processing)
- REQ-005.01 (Framebuffer Management)
- REQ-005.02 (Depth Tested Triangle)
- REQ-005.03 (Alpha Blending)
- REQ-005.04 (Enhanced Z-Buffer)
- REQ-005.06 (Framebuffer Format)
- REQ-005.07 (Z-Buffer Operations) — early Z-test execution and Hi-Z metadata write path only; Z-cache and uninit flags owned by UNIT-012
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
- Reads/writes Z-buffer via UNIT-012 (Z-buffer tile cache); UNIT-012 arbitrates SDRAM access through UNIT-007
- Receives render mode, dither, blend, scissor, and Z-range configuration from UNIT-003 (Register File)
- Receives CC_MODE and CONST_COLOR from UNIT-003 for UNIT-010 (Color Combiner)
- Issues color read/write requests to UNIT-013 (Color Tile Cache) via tile_idx + pixel_off address; UNIT-013 manages SDRAM burst fills and writebacks through UNIT-007 Port 1

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
- Per-pixel level-of-detail `frag_lod` (UQ4.4) from rasterizer (UNIT-005); emitted by UNIT-005 but not consumed by UNIT-011 (mipmapping is not supported in the INDEXED8_2X2 architecture)
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

- Hi-Z metadata update channel: on every Z-write (when `Z_WRITE_EN=1` and the fragment passes all tests), the pixel pipeline sends the written Z value and tile index to UNIT-005.06 (Hi-Z Block Metadata); if the new Z is less than the stored `min_z` bucket value (`new_z[15:7] < stored_min_z`), the metadata entry is updated to `min_z = new_z[15:7]`

The Z-buffer tile cache, uninit flag EBR, and lazy-fill logic are owned by UNIT-012 (Z-Buffer Tile Cache).
UNIT-006 issues Z-read and Z-write requests to UNIT-012 and receives responses; it does not hold Z-buffer state internally.

### Algorithm / Behavior

The pixel pipeline processes rasterized fragments through a staged pipeline.
Texture operations are delegated to UNIT-011, which delivers Q4.12 RGBA texel results back to UNIT-006.
Color operations in UNIT-010 use Q4.12 format across all three passes (REQ-004.02).
The `DST_COLOR` source (destination pixel from the color tile buffer) is available to all three UNIT-010 passes.
Alpha blending (REQ-005.03) conventionally uses pass 2 (CC2), but the hardware does not enforce this assignment.

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
  - Issue a Z-read request to UNIT-012; UNIT-012 handles cache lookup, lazy-fill (uninit flag and 0xFFFF supply), and SDRAM burst fill on miss; returns the effective stored Z to UNIT-006
  - Compare fragment Z against Z-buffer using Z_COMPARE function
  - If test fails: discard fragment, skip all subsequent stages
  - **Bypass conditions**: Early Z-test is skipped (fragment always passes) when:
    - RENDER_MODE.Z_TEST_EN = 0 (depth testing disabled)
    - RENDER_MODE.Z_COMPARE = ALWAYS (3'd6)
  - Z-buffer write deferred to final stage (ensures only visible fragments update Z)

**Stage 1–3: Texture Sampling (delegated to UNIT-011):**

UNIT-006 forwards the fragment's UV coordinates and register-file configuration (TEX0_CFG, TEX1_CFG) to UNIT-011.
UNIT-011 performs UV coordinate processing (NEAREST point-sample), half-resolution index cache lookup, and palette LUT promotion, then returns TEX_COLOR0 and TEX_COLOR1 in Q4.12 RGBA format within 4 cycles (best case).
If UNIT-011 encounters an index cache miss or a palette slot not-ready condition, it stalls the UNIT-006 pipeline until the fill or load completes.
See UNIT-011 for the detailed texture sampling design.

**Output to UNIT-010 (Color Combiner):**

- TEX_COLOR0, TEX_COLOR1 (Q4.12 RGBA from UNIT-011, or Q4.12 white/zero if unit disabled)
- SHADE0, SHADE1 (Q4.12 RGBA passthrough from rasterizer)
- CONST0, CONST1 (Q4.12 promoted from CONST_COLOR register)
- Fragment position (x, y) and Z passthrough

**CC Pass 2 / Alpha Blending (Q4.12 precision, via UNIT-010 CC2):**

Alpha blending (REQ-005.03) is implemented as the third pass of UNIT-010 (CC pass 2), configured by RENDER_MODE.ALPHA_BLEND:

- UNIT-013 (Color Tile Cache) holds the current 4×4 framebuffer tile (16 RGB565 pixels) as the `DST_COLOR` source; UNIT-006 reads the cached destination pixel via a tile_idx + pixel_off read request to UNIT-013.
- On a cache miss, UNIT-013 fills the tile from SDRAM as a 16-word burst read (Port 1) before returning data to UNIT-006; on a cache hit, no SDRAM access occurs.
- The `DST_COLOR` source (promoted to Q4.12 via `fb_promote.sv`) is available to all CC passes; conventionally pass 2 computes the blend equation using the `(A-B)*C+D` combiner:
  - **DISABLED:** CC pass 2 is a passthrough; no framebuffer read is required.
  - **ADD:** `result = saturate(CC1_out + dst_color × 1.0)`
  - **SUBTRACT:** `result = saturate(dst_color − CC1_out × alpha)`
  - **BLEND:** `result = CC1_out × alpha + dst_color × (1.0 − alpha)` (Porter-Duff source-over)
- The updated RGB565 pixel is written back to UNIT-013 via a tile_idx + pixel_off write request; UNIT-013 marks the line dirty and writes back to SDRAM on eviction or flush.

**Ordered Dithering + Framebuffer Write + Z Write:**

- If RENDER_MODE.DITHER_EN=1 (REQ-005.10):
  1. Read dither matrix entry indexed by `{screen_y[3:0], screen_x[3:0]}` from EBR
  2. Add dither offset to the Q4.12 value before truncation to RGB565
- Extract UNORM: R5 = clamp(color.R × 31, 0, 31), G6 = clamp(color.G × 63, 0, 63), B5 = clamp(color.B × 31, 0, 31)
- Pack into RGB565
- If RENDER_MODE.COLOR_WRITE_EN=1 and pixel inside scissor: issue a color-write request to UNIT-013 (tile_idx, pixel_off, rgb565_value); UNIT-013 updates the cached tile and marks the line dirty
- If RENDER_MODE.Z_WRITE_EN=1: issue a Z-write request to UNIT-012 (write-back to SDRAM); additionally, send the written Z and tile index to UNIT-005.06 (Hi-Z Block Metadata) via the Hi-Z update channel — if `new_z[15:7] < stored_min_z`, the metadata entry is updated to record the new minimum
- Alpha channel is discarded (RGB565 has no alpha storage)

### Tiled Framebuffer Address Calculation

The Z-buffer uses 4×4 block-tiled layout (INT-011); its address calculation remains in UNIT-006 for Z-read and Z-write requests issued to UNIT-012.
Color framebuffer address calculation has moved into UNIT-013 (Color Tile Cache): UNIT-006 passes a `tile_idx` and `pixel_off` (sub-tile pixel index) to UNIT-013, which computes the full SDRAM byte address internally from FB_CONFIG.

For reference, the tile_idx and pixel_off encoding for a pixel at (x, y) in a surface with width `2^WIDTH_LOG2`:

```text
block_x   = x >> 2
block_y   = y >> 2
local_x   = x & 3
local_y   = y & 3
tile_idx  = (block_y << (WIDTH_LOG2 - 2)) | block_x
pixel_off = local_y * 4 + local_x
```

Both color and Z values are 16 bits per pixel; each 4×4 block occupies 32 bytes.

## Implementation

- `rtl/pkg/fp_types_pkg.sv`: Q4.12 fixed-point type, constants, and promotion functions (shared package)
- `twin/components/pixel-write/src/lib.rs`: Digital twin pixel-write stage (color cache read-modify-write, Hi-Z metadata update; Z-buffer I/O delegated to `gs-zbuf`; color cache I/O delegated to `gs-pixel-write` via UNIT-013)
- `twin/components/pixel-write/src/fb_promote.rs`: Digital twin RGB565→Q4.12 framebuffer readback promotion (matches `fb_promote.sv`)
- `rtl/components/pixel-write/src/pixel_pipeline.sv`: Main implementation
- `rtl/components/pixel-write/src/fb_promote.sv`: RGB565→Q4.12 framebuffer readback promotion (REQ-004.02)
- `rtl/components/dither/src/dither.sv`: Ordered dithering with blue noise EBR (REQ-005.10)
- `rtl/components/early-z/src/early_z.sv`: Depth range test + early Z-test logic
- `rtl/components/stipple/src/stipple.sv`: Stipple pattern test

Color tile cache RTL and digital twin are owned by UNIT-013.
Texture sampling RTL (texture decoders, texture cache, texel promotion) is owned by UNIT-011.

## Verification

- **VER-002** (`tb_early_z` — Verilator unit testbench; covers REQ-005.02 early Z-test path)
- **VER-010** (Gouraud Triangle Golden Image Test)
- **VER-011** (Depth-Tested Overlapping Triangles Golden Image Test)
- **VER-012** (Textured Triangle Golden Image Test)
- **VER-013** (Color-Combined Output Golden Image Test)
- **VER-014** (Textured Cube Golden Image Test)
- **VER-024** (Alpha Blend Modes Golden Image Test — covers REQ-005.03 via CC pass 2 and tile buffer)

## Design Notes

**Arbiter port ownership:** UNIT-006 owns arbiter port 3 only; UNIT-012 owns port 2; UNIT-013 owns port 1:

- Port 1: color tile cache burst fill and writeback (16-word) — owned by UNIT-013 (Color Tile Cache); UNIT-006 does not drive Port 1 directly
- Port 2: Z-buffer read/write — owned by UNIT-012 (Z-buffer tile cache)
- Port 3: texture index cache fill reads (8-word burst per 4×4 index block) and palette slot loads (multi-burst, 4096 bytes per slot) — issued on behalf of UNIT-011 via its internal 3-way arbiter

Port 3 is shared with `PERF_TIMESTAMP` writes initiated by `gpu_top.sv` on behalf of UNIT-003.
Timestamp writes are fire-and-forget single-word writes at the lowest priority on port 3; texture index cache fills hold port 3 for 8 words and palette load sub-bursts hold it for up to 32 words, giving texture operations effective precedence via arrival-order arbitration.
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

1. **UNIT-011 (Texture Sampler):** UV coordinate processing (NEAREST point-sample), half-resolution index cache (UNIT-011.03), palette LUT lookup (UNIT-011.06), and UQ1.8-to-Q4.12 promotion.
   Delivers TEX_COLOR0, TEX_COLOR1 in Q4.12 RGBA to UNIT-006.
2. **UNIT-006 (this unit):** Stipple test, depth range clipping, early Z-test, dispatches fragment UV/LOD to UNIT-011, receives Q4.12 texel results, passes them to UNIT-010.
3. **UNIT-010 (Color Combiner):** Single time-multiplexed programmable color combiner `(A-B)*C+D` executing three passes (CC0, CC1, CC2) per fragment within a 4-cycle/fragment throughput.
   CC0 and CC1 take TEX_COLOR0, TEX_COLOR1, SHADE0, SHADE1, CONST0, CONST1, COMBINED as inputs.
   CC2 (blend pass) additionally takes DST_COLOR (promoted destination pixel from the color tile buffer) and implements alpha blending via a CC equation template selected by RENDER_MODE.ALPHA_BLEND.
   Outputs the final blended color downstream.
4. **Fragment Output (dither + write via color tile cache):** Ordered dithering, pixel write to UNIT-013 (Color Tile Cache); burst tile fill/evict managed by UNIT-013, not UNIT-006.

**Estimated FPGA Resources (UNIT-006 only, excluding UNIT-010, UNIT-011, and UNIT-013):**

- FB promote (`fb_promote.sv`): ~200-400 LUTs (combinational)
- Dither module: 1 EBR block (256×18 blue noise), ~100-200 LUTs
- Total pipeline throughput: 1 fragment per 4 cycles at 100 MHz (25 Mfragments/sec), limited by the 3-pass CC schedule
