# Technical Report: GPU Feature Gap Analysis

Date: 2026-02-28
Status: Draft

## Background

The VER-014 textured cube integration test (`build/sim_out/textured_cube.png`) renders a correct cube shape but shows solid white instead of a checker texture pattern.
Investigation revealed this is not a test script bug — the test register commands are correct — but rather a systemic gap in the RTL pipeline.
This report catalogs all GPU features that are specified or have RTL modules written but are not yet integrated into the working pipeline.

## Scope

This report investigates:

1. Which GPU RTL modules exist but are not instantiated in `gpu_top.sv`?
2. Which register file outputs are declared but not consumed?
3. What is the architectural gap between the current rasterizer and the pixel pipeline?
4. What is the implementation status of each render-stage sub-module?

Out of scope: host firmware (Rust) feature gaps, asset pipeline gaps, verification coverage gaps beyond what is noted.
Register map correctness is assumed (INT-010 through INT-014 are authoritative).

## Investigation

### Files Examined

- `spi_gpu/src/gpu_top.sv` — top-level module, all instantiations and wiring
- `spi_gpu/src/render/rasterizer.sv` — current monolithic rasterizer
- `spi_gpu/src/render/pixel_pipeline.sv` — stub pixel pipeline
- `spi_gpu/src/render/color_combiner.sv` — two-stage programmable combiner
- `spi_gpu/src/render/texture_cache.sv` — 4-way set-associative cache with burst fill
- `spi_gpu/src/render/early_z.sv` — depth compare and range test
- `spi_gpu/src/render/stipple.sv` — 8x8 stipple pattern test
- `spi_gpu/src/render/dither.sv` — 16x16 Bayer ordered dither
- `spi_gpu/src/render/alpha_blend.sv` — 4-mode alpha blending
- `spi_gpu/src/render/texel_promote.sv` — RGBA5652 to Q4.12 promotion
- `spi_gpu/src/render/fb_promote.sv` — RGB565 to Q4.12 promotion
- `spi_gpu/src/render/texture_rgb565.sv` — RGB565 texel decoder
- `spi_gpu/src/render/texture_rgba8888.sv` — RGBA8888 texel decoder
- `spi_gpu/src/render/texture_r8.sv` — R8 (grayscale) texel decoder
- `spi_gpu/src/render/texture_bc2.sv` — BC2 block decoder
- `spi_gpu/src/render/texture_bc3.sv` — BC3 block decoder
- `spi_gpu/src/render/texture_bc4.sv` — BC4 block decoder
- `spi_gpu/src/spi/register_file.sv` — register decode and vertex state machine
- `spi_gpu/tests/harness/scripts/ver_014_textured_cube.cpp` — VER-014 command script

### Specification Documents Referenced

- UNIT-005 (Rasterizer), UNIT-006 (Pixel Pipeline), UNIT-010 (Color Combiner)
- INT-010 (GPU Register Map), INT-014 (Texture Memory Layout), INT-032 (Texture Cache Architecture)
- REQ-003 (Texture Requirements), REQ-004 (Color Combiner), REQ-005 (Fragment Operations)

## Findings

### Finding 1: Monolithic Rasterizer — The Central Architectural Gap

The rasterizer (`rasterizer.sv`) is a self-contained pipeline that performs edge walking, barycentric interpolation, Z-testing, color interpolation, and **direct FB/Z-buffer SDRAM writes** — all within a single module.
It owns arbiter ports 1 (framebuffer write) and 2 (Z-buffer read/write) directly.

**Critical missing interfaces on the rasterizer:**

| Missing Port | Purpose | Needed By |
|-------------|---------|-----------|
| UV0/UV1 per-vertex inputs | Texture coordinate interpolation | Pixel pipeline (texture sampling) |
| Q per-vertex input | Perspective-correct 1/W interpolation | Perspective-correct UV mapping |
| Color1 per-vertex input | Specular/secondary color | Color combiner (dual shade inputs) |
| Fragment output bus | Emit interpolated fragments | Pixel pipeline consumption |

The current data flow terminates at the rasterizer:

```
Register File → Rasterizer → SDRAM (direct write)
                   ↑ No fragment output
                   ↑ No UV interpolation
                   ↑ No specular color
```

The intended data flow per UNIT-005/UNIT-006 specs:

```
Register File → Rasterizer → Pixel Pipeline → Color Combiner → FB Write
                   ↓               ↓                ↓
              Interpolate:    Texture Cache     (A-B)*C+D
              Z, Color0/1,   → Texel Decode    → Alpha Blend
              UV0/1, Q       → Format Promote   → Dither
                                                 → FB/Z Write
```

**Implication:** Integrating the pixel pipeline requires refactoring the rasterizer to emit per-fragment data (position, depth, interpolated colors, UVs) and moving the FB/Z write logic out of the rasterizer into the pixel pipeline.
The arbiter port ownership must shift from the rasterizer to the pixel pipeline for ports 1 and 2.

**DSP budget constraint (cross-ref: `doc/reports/incremental_interpolation_redesign.md`):**
Adding UV interpolation to the current barycentric rasterizer is not feasible without first switching to incremental interpolation.
The current per-pixel barycentric approach uses 15 DSP multipliers (3 weights + 9 color + 3 Z).
Adding UV0 and UV1 would require ~6 more multipliers (3 per UV set), totalling ~23 per-pixel DSPs.
With texture filtering (8–16 DSPs) and the color combiner (2 DSPs), the full pipeline would need 33–41 multipliers — far exceeding the ECP5-25K's 56 MULT18X18D budget and the 16-slice pipeline target (REQ-011.02).
The incremental interpolation redesign eliminates all 15 per-pixel multipliers by replacing barycentric multiply-accumulate with per-pixel addition of precomputed attribute derivatives, dropping rasterizer per-pixel DSP usage to zero.
This redesign is therefore a **prerequisite** for the pixel pipeline integration described in this report.

### Finding 2: Module Implementation Status

Of 20 render-related RTL modules, 14 have complete logic but only 1 (rasterizer) is instantiated in `gpu_top.sv`:

| Module | Logic Status | In gpu_top? | Notes |
|--------|-------------|-------------|-------|
| `rasterizer.sv` | Complete | Yes | Monolithic; does its own Z/FB writes |
| `pixel_pipeline.sv` | **Stub** | **No** | Sub-modules wired but tex=0, mem outputs=0 |
| `color_combiner.sv` | Complete | **No** | Full (A-B)*C+D two-stage pipeline |
| `texture_cache.sv` | Complete | **No** | 4-way set-assoc, burst fill FSM |
| `early_z.sv` | Complete | Via stub | Instantiated inside pixel_pipeline |
| `stipple.sv` | Complete | Via stub | Instantiated inside pixel_pipeline |
| `dither.sv` | Complete | Via stub | Instantiated inside pixel_pipeline |
| `alpha_blend.sv` | Complete | Via stub | Instantiated inside pixel_pipeline |
| `texel_promote.sv` | Complete | Via stub | Instantiated inside pixel_pipeline (x2) |
| `fb_promote.sv` | Complete | Via stub | Instantiated inside pixel_pipeline |
| `texture_rgb565.sv` | Complete | **No** | Format decoder, not wired to cache |
| `texture_rgba8888.sv` | Complete | **No** | Format decoder, not wired to cache |
| `texture_r8.sv` | Complete | **No** | Format decoder, not wired to cache |
| `texture_bc2.sv` | Complete | **No** | Format decoder, not wired to cache |
| `texture_bc3.sv` | Complete | **No** | Format decoder, not wired to cache |
| `texture_bc4.sv` | Complete | **No** | Format decoder, not wired to cache |

Six texture format decoders (BC2, BC3, BC4, RGB565, RGBA8888, R8) exist as standalone modules but are not connected to the texture cache.
The texture cache currently handles only BC1 (inline) and RGBA4444 (inline) decoding.
Integrating the additional format decoders requires adding a format-select mux in the cache's decompress stage.

### Finding 3: Register File Outputs Not Consumed

The register file produces 17 signal groups that are declared in `gpu_top.sv` but have **no consumer module**:

**Vertex Data (from tri_* bus):**
- `tri_uv0[2:0][31:0]` — per-vertex TEX0 UV coordinates
- `tri_uv1[2:0][31:0]` — per-vertex TEX1 UV coordinates
- `tri_q[2:0][15:0]` — per-vertex perspective Q (1/W) values
- `tri_color1[2:0][31:0]` — per-vertex specular RGBA8888

**Render Mode Flags:**
- `mode_gouraud` — Gouraud enable (rasterizer always does Gouraud regardless)
- `mode_cull[1:0]` — backface culling mode
- `mode_alpha_blend[2:0]` — alpha blend function select
- `mode_dither_en` — ordered dither enable
- `mode_dither_pattern[1:0]` — dither pattern select
- `mode_stipple_en` — stipple test enable
- `mode_alpha_test[1:0]` — alpha test function
- `mode_alpha_ref[7:0]` — alpha test reference

**Texture Configuration:**
- `tex0_cfg[63:0]` — TEX0 enable, format, size, base, filter, wrap
- `tex1_cfg[63:0]` — TEX1 configuration
- `tex0_cache_inv` — TEX0 cache invalidation pulse
- `tex1_cache_inv` — TEX1 cache invalidation pulse

**Color Combiner:**
- `cc_mode[63:0]` — two-cycle combiner source selectors
- `const_color[63:0]` — CONST0/CONST1 RGBA8888 values

**Primitive:**
- `rect_valid` — rectangle kick (no rectangle rasterizer exists)

### Finding 4: Texture Cache Format Coverage Gap

The texture cache (`texture_cache.sv`) has **hardcoded format handling** for only two formats:
- `2'b00` = RGBA4444 (16 words burst)
- `2'b01` = BC1 (4 words burst)

The six standalone texture decoders handle the full format set from INT-014:
- BC2, BC3, BC4 (block-compressed)
- RGB565, RGBA8888 (uncompressed)
- R8 (single-channel grayscale)

These decoders all produce 18-bit RGBA5652 output but are not connected to the cache.
The cache's `tex_format` input is 2 bits wide, which cannot represent all 7 formats (needs at least 3 bits per `tex_format_e` in `gpu_regs.rdl`).

### Finding 5: SDRAM Arbiter Port 3 — Shared Timestamp/Texture

Arbiter port 3 is currently used exclusively for timestamp SDRAM writes (from the register file).
The texture cache requires burst reads on port 3.
The timestamp FSM in `gpu_top.sv` (lines 594–621) drives port 3 as write-only.
Multiplexing between timestamp writes and texture burst reads will require either time-sharing or a dedicated arbitration scheme on this port.

### Finding 6: pixel_pipeline.sv is a Well-Structured Stub

The pixel pipeline module has the correct port interface per UNIT-006 and instantiates all sub-modules with proper wiring:
- `stipple` → `early_z` → `texel_promote` (x2) → `fb_promote` → `alpha_blend` → `dither`

What it is missing:
- Texture cache instantiation and lookup FSM
- Texture format decoder multiplexing
- Pipeline control logic (stall propagation, valid chain)
- FB/Z address computation and write FSM
- Fragment acceptance backpressure to rasterizer
- Inter-stage pipeline registers for timing closure

The stub currently outputs `frag_ready = 1` (always accepts), `fb_write_req = 0` (never writes), and `zbuf_read_req = 0` (never reads Z).
Texture inputs are hardcoded to `18'b0`, which is why VER-014 shows solid white (all texels decode as black Q4.12 → MODULATE with white vertex color would produce black, but the combiner is not even in the path; the rasterizer writes white Gouraud color directly).

## Conclusions

### Answer to Q1: Features with no RTL or only stub RTL

Three features have RTL modules written but **no active logic path**:

1. **Texture sampling** — `texture_cache.sv` + 6 format decoders are complete modules but never instantiated.
   Blocked by: pixel_pipeline integration and rasterizer refactoring.

2. **Programmable color combining** — `color_combiner.sv` is fully implemented (456 lines, two-cycle pipeline) but never instantiated.
   Blocked by: pixel_pipeline integration.

3. **Post-shader fragment operations** — `alpha_blend.sv`, `dither.sv`, `stipple.sv`, `early_z.sv`, `fb_promote.sv`, `texel_promote.sv` are all complete but only instantiated inside the non-functional pixel pipeline stub.
   Blocked by: pixel_pipeline integration.

Features with **no RTL at all**:

4. **Rectangle rasterization** — `rect_valid` signal exists from the register file but no rect rasterizer module exists.

5. **Backface culling** — `mode_cull[1:0]` signal exists but no culling logic is present in any module.

6. **Alpha testing** — `mode_alpha_test[1:0]` and `mode_alpha_ref[7:0]` signals exist but no alpha test logic is present.

### Answer to Q2: Modules written but not integrated

13 out of 14 render modules with complete logic are not in the active data path.
See the table in Finding 2 for the complete list.

### Answer to Q3: VER-014 failure root cause

VER-014 renders solid white because:
1. The rasterizer directly writes Gouraud-interpolated vertex colors to the framebuffer.
2. All cube vertices use white (`0xFFFFFF`), producing solid white output.
3. The texture pipeline, color combiner, and all post-shader operations are bypassed.
4. UV coordinates written to registers reach the register file but go nowhere.

### What Remains Uncertain

- **ECP5 resource budget** — Whether the full pipeline fits within the ECP5-25K after all modules are instantiated.
  The texture cache uses 4 × 1024 × 18-bit EBR banks per sampler (two samplers required), which is significant.
  The incremental interpolation redesign (`doc/reports/incremental_interpolation_redesign.md`) addresses the DSP budget — see Finding 1 — but EBR and LUT usage remain unquantified.
- **Timing closure** — Whether the combinational paths through the texture cache tag comparison and color combiner multiply-accumulate chains meet 100 MHz timing.
- **Arbiter port 3 contention** — How timestamp writes and texture burst reads will coexist.

## Recommendations

Enabling textured rendering requires three coordinated changes to the rasterizer and pixel pipeline.
The incremental interpolation redesign (`doc/reports/incremental_interpolation_redesign.md`) is a prerequisite for step 1 because the current barycentric approach cannot accommodate UV interpolation within the DSP budget.

### Suggested sequencing

1. **Incremental interpolation redesign** (Phases 1–2 from `incremental_interpolation_redesign.md`).
   Replace per-pixel barycentric multiply-accumulate with precomputed attribute derivatives.
   Add UV0/UV1/Q derivative computation in the setup phase.
   This frees 13–14 DSP slices, creating headroom for downstream pipeline stages.

2. **Rasterizer fragment output interface.**
   Refactor the rasterizer to emit per-fragment data (x, y, z, color0, color1, uv0, uv1, q) via a valid/ready handshake instead of performing direct FB/Z writes.
   Move arbiter port 1 (FB) and port 2 (Z) ownership from the rasterizer to the pixel pipeline.

3. **Pixel pipeline integration.**
   Complete the pixel pipeline stub: add pipeline control FSM, texture cache instantiation, format decoder muxing, and FB/Z write logic.
   Instantiate the color combiner between texture output and the alpha blend stage.

4. **Resolve arbiter port 3 sharing** between timestamp writes and texture cache burst reads.

5. **Expand texture cache format support** from 2-bit to 3-bit format select and connect the six standalone format decoders.

### Affected specifications

Steps 1–3 all touch UNIT-004 (Triangle Setup), UNIT-005 (Rasterizer), and UNIT-006 (Pixel Pipeline), and could be analyzed as a single `/syskit-impact` run.

When ready to act on these findings, use this report and `doc/reports/incremental_interpolation_redesign.md` as context for `/syskit-impact`.
