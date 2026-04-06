# Architecture

*A hobby 3D graphics processor on a small FPGA, named after the PS2 Graphics Synthesizer.*

## System Description

pico-gs is an educational/hobby 3D GPU implemented on the ICEpi Zero v1.3 development board (Lattice ECP5-25K FPGA, CABGA256) with 32 MiB of SDRAM (Winbond W9825G6KH-6).
It outputs 640x480 at 60 Hz as DVI on the board's HDMI port.

The GPU is driven over SPI by an external host that writes 72-bit register-write transactions per INT-012.
The reference host application is pico-racer (https://github.com/londey/pico-racer), which runs on a Raspberry Pi Pico 2 (RP2350) or on a PC via an FT232H USB-to-SPI adapter.
Three GPIO lines provide hardware status to the host: CMD_FULL warns when the command FIFO is nearly full (host must pause writes), CMD_EMPTY indicates the FIFO is empty and no command is executing (safe to issue register reads), and VSYNC delivers a pulse for frame synchronization.

The framebuffer is RGB565 in 4×4 block-tiled layout, the Z-buffer is 16-bit unsigned (also block-tiled), and the pixel pipeline supports two independent texture units per pixel in a single pass.
Render targets are power-of-two per axis (non-square permitted) and share the same tiled format as textures, enabling completed render targets to be sampled directly as texture sources with no copy or format conversion.
The pipeline is fixed-function, inspired by the Nintendo 64 RDP's programmable color combiner — `(A-B)*C+D` applied independently to RGB and alpha — with additional features including blue noise dithering, per-channel color grading LUTs, DOT3 bump mapping, octahedral UV wrapping, and stipple-pattern fragment discard for order-independent transparency without framebuffer reads.

## Design Philosophy

The architecture is a hybrid of two classic console GPUs: the PS2 Graphics Synthesizer's register-driven vertex submission model and the N64 RDP's fixed-function pixel pipeline.
Rendering is strictly immediate mode — no display lists, no tile-based deferred rendering.

The external host handles all vertex transformation, lighting, back-face culling, and clipping in software.
The GPU handles rasterization, texturing, depth testing, color combining, and scanout.
This split keeps the FPGA fabric focused on per-pixel throughput while the host manages scene complexity.

Fragment processing uses Q4.12 signed fixed-point arithmetic (16-bit) as the pipeline-wide format, with colors normalized to 0.0–1.0.
All UNORM inputs — vertex colors, material constants, and texture samples — are promoted to Q4.12 at pipeline entry; output converts back to UNORM after optional dithering.
The signed representation naturally handles the `(A-B)` subtraction in the color combiner, and the 3-bit integer headroom above 1.0 (range up to ~8.0) accommodates additive blending without premature saturation.
The 12 fractional bits reduce accumulated quantization error through chained combiner stages and alpha blending, preserving gradient fidelity in dark tones.
Alpha blending promotes the framebuffer's UNORM value to Q4.12 before blending; the result follows the normal dither-and-write path.
The 16-bit operands fit within the ECP5's native 18×18 DSP multipliers; bilinear texture filtering still uses the 9×9 DSP sub-mode, as its inputs (≤8-bit texels and fractional UV weights) remain narrow enough to pack two multiplies per slice.
Memory bandwidth is managed through native 16-bit pixel addressing (one SDRAM column per RGB565 or Z16 value), a 4-way set-associative texture cache (>90% hit rate; stores texels in UQ1.8 per channel format, 36 bits per texel; supports eight texture formats via a 4-bit format-select field), a Z-buffer tile cache (UNIT-012; 4-way, 16 sets, 4×4 tiles, 85–95% hit rate), early Z rejection before texture fetch, and write-coalescing burst output.

## Verification Strategy

The project uses a two-tier verification model with clearly separated responsibilities.

### Tier 1: Digital Twin (gs-twin) — Algorithmic Oracle

A bit-accurate, transaction-level Rust model of the GPU pipeline lives at `integration/gs-twin/`.
It models the register-write interface, integer rasterizer, and full pixel pipeline — everything from SPI register decode through framebuffer write — producing golden reference framebuffers that the RTL's output must match exactly at the RGB565 pixel level.

The twin answers: **"what should the output be?"**

Its role is algorithmic correctness: the rustdoc on each type and function is the authoritative design specification for the corresponding RTL module.
All fixed-point formats, bit widths, rounding behavior, and overflow conventions match the RTL exactly.

The twin is deliberately *not* cycle-accurate and does not model pipeline timing, valid/ready handshaking, stall propagation, cache miss penalties, or SDRAM arbitration contention.
These are hardware implementation concerns owned by the RTL and verified by Verilator.

For the module-to-RTL mapping, see `CLAUDE.md` (module mapping table) and the individual component twin crates under `components/*/twin/`.

### Tier 2: Verilator — Cycle-Accurate Verification

Verilator testbenches own all cycle-level concerns: pipeline stall propagation, backpressure handshaking, cache miss/evict timing, SDRAM arbitration, and clock-domain crossings.

Verilator answers: **"does the hardware produce the right answer with correct timing?"**

Both the Rust twin and Verilator testbenches consume the same `.hex` register-write scripts.
The `gs-twin-cli` binary renders scripts to PNG and compares against Verilator framebuffer dumps — any pixel mismatch is a real bug.
Component-level Verilator testbenches additionally verify RTL output against DT-generated test vectors for per-module correctness.

## Component Interactions

The host submits triangles as a stream of 72-bit register writes over SPI.
Each write carries a 7-bit register address and 64-bit data payload.
Per-vertex state (color, UVs, position) is accumulated in the register file (UNIT-003); the third vertex write triggers the hardware rasterizer.

The SPI slave (UNIT-001) feeds a 512-entry asynchronous command FIFO (UNIT-002, 2 EBR blocks, 72 bits wide) that bridges the SPI clock domain to the 100 MHz core domain.
Commands execute in strict FIFO order; a long-running operation such as rasterizing a large triangle stalls all subsequent commands until it completes.
At 62.5 MHz SPI this provides approximately 590 µs of host-side buffering (~170 triangles), decoupling the host's SPI burst rate from the GPU's variable per-command execution time.
When the FIFO approaches capacity, the CMD_FULL GPIO tells the host to pause.
The CMD_EMPTY GPIO indicates the FIFO is drained and no command is executing, which the host must check before issuing a register read (reads bypass the FIFO and require an idle register file).

Triangle setup (UNIT-005.01) computes edge coefficients and performs backface culling.
The rasterizer (UNIT-005) walks the bounding box in 4×4 tile order — aligned with the surface tiling and Z-cache block size — using incremental derivative-based traversal with 8 MULT18X18D DSP blocks (see UNIT-005 DSP Budget table for breakdown).
It interpolates Z, Q (1/W), two vertex colors, and two UV coordinate pairs (S×Q, T×Q perspective projections at vertices), then applies perspective correction internally using two dedicated reciprocal modules backed by ECP5 DP16KD block RAMs: one for the triangle-setup inv_area computation (`raster_recip_area.sv`, 36×512 mode, UQ4.14 output) and one for per-pixel 1/Q computation (`raster_recip_q.sv`, 18×1024 mode, UQ4.14 output).
A compile-time configurable register FIFO (default depth 2, ~730 bits wide) between setup and iteration enables triangle N+1 setup to overlap with triangle N iteration.
Four dedicated MULT18X18D blocks compute true U = S×(1/Q) and V = T×(1/Q) for both texture units.
The per-pixel level-of-detail (LOD) is derived from Q via CLZ and emitted on the fragment bus as `frag_lod` (UQ4.4).
All pixels within a tile are processed before advancing to the next, maximizing Z-cache locality.
The texture sampler (UNIT-011) performs dual-texture sampling through per-sampler two-level caches; it receives true perspective-correct U, V coordinates and frag_lod directly from the rasterizer, applies wrap/clamp/mirror UV processing (UNIT-011.01), fetches and bilinearly filters texels from the L1 decompressed cache (UNIT-011.03), decompresses blocks on miss via the block decompressor (UNIT-011.04), and fills the L1 cache from the L2 compressed cache (UNIT-011.05), returning decoded Q4.12 RGBA texel data to the pixel pipeline.
The pixel pipeline (UNIT-006) performs early Z testing, dispatches texture fetch requests to UNIT-011, and receives decoded Q4.12 texel data in return; it receives true perspective-correct U, V coordinates and frag_lod directly from the rasterizer — no per-pixel division is performed in the pixel pipeline.
The color combiner (UNIT-010) is a two-stage pipeline running at one pixel per clock: each stage evaluates `(A-B)*C+D` independently for RGB and alpha, selecting from texture colors, two interpolated vertex colors (SHADE0 for diffuse, SHADE1 for specular), per-draw-call constant colors, and a combined-output feedback path.
Stage 0's output feeds stage 1 via the COMBINED source, enabling multi-texture blending, fog, and specular-add in a single pass; for simple single-equation rendering, stage 1 is configured as a pass-through.
After optional alpha blending and ordered dithering, fragments are written to the double-buffered framebuffer in SDRAM.

The Z-buffer tile cache (UNIT-012) is an independent component that sits between the pixel pipeline and the SDRAM arbiter: it caches 4×4 tiles of 16-bit Z values in DP16KD BRAM (4-way, 16 sets, write-back), owns the per-tile uninitialized flag array (16,384 1-bit flags in DP16KD) for lazy-fill tracking, and supplies Z-read results and accepts Z-write requests from UNIT-006 while managing fill/evict bursts to SDRAM independently via arbiter port 2.
A four-port fixed-priority memory arbiter (UNIT-007) manages all SDRAM traffic: display scanout (highest), framebuffer writes, Z-buffer tile cache access, and texture cache fills (lowest).
The display controller (UNIT-008) reads from the block-tiled framebuffer surface, applies an optional color-grade LUT, stretches the image to 640×480 using nearest-neighbor horizontal scaling, and drives the DVI/TMDS encoder (UNIT-009).
The render framebuffer may be smaller than the display resolution (typically 512×480 or 256×240); the display controller stretches horizontally and optionally line-doubles to fill the 640×480 output.
Frame presentation is double-buffered — the host writes to one framebuffer while the display controller scans out the other, swapping atomically at VSYNC.

## Fragment Pipeline

The stages below trace a fragment from SPI command to DVI output.
Stages marked **✗** can kill the fragment, skipping all subsequent stages and SDRAM traffic.

```mermaid
flowchart TD
    subgraph front["Front End"]
        SPI["SPI Receive"] --> FIFO["Command FIFO"] --> REG["Register File"]
    end

    subgraph geom["Geometry · per triangle"]
        SETUP["Triangle Setup +<br/>Backface Cull ✗"] --> TILE["Tile Walk"] --> HIZ_CULL["Hi-Z Cull ✗"] --> EDGE["Edge Test +<br/>Interpolation"]
    end

    subgraph frag["Fragment · per pixel"]
        STIP["Stipple Test ✗"]
        ZRC["Depth Range Clip ✗"]
        EZ["Early Z Test ✗"]
        TEX0["TEX0 Sample + Cache"]
        TEX1["TEX1 Sample + Cache"]
        CC0["Color Combiner 0<br/>(A-B)*C+D"]
        CC1["Color Combiner 1<br/>(A-B)*C+D"]
        AT["Alpha Test ✗"]
        AB["Alpha Blend"]
        DITH["Dither"]
        PW["Pixel Write"]
        STIP --> ZRC --> EZ --> TEX0 --> CC0
        EZ --> TEX1 --> CC0
        CC0 -- "COMBINED" --> CC1 --> AT --> AB --> DITH --> PW
    end

    REG -- "vertex kick" --> SETUP
    EDGE --> STIP

    HIZ_META["Hi-Z Metadata<br/>(8 DP16KD)"]
    ZCACHE["Z-Buffer Tile Cache<br/>(4-way, 4×4 tiles)"]
    WBUF["Write-Coalescing<br/>Buffer"]
    ZBUF[("Z-Buffer<br/>SDRAM")]
    TEXMEM[("Texture Data<br/>SDRAM")]
    FB[("Framebuffer<br/>SDRAM")]

    HIZ_CULL <-. "tile Z query" .-> HIZ_META
    PW -. "Z-write update" .-> HIZ_META
    EZ <-. "Z read/write" .-> ZCACHE
    PW -. "Z update" .-> ZCACHE
    ZCACHE -. "fill/evict burst" .-> ZBUF
    TEXMEM -. "cache fill" .-> TEX0
    TEXMEM -. "cache fill" .-> TEX1
    FB -. "dst read" .-> AB
    PW -. "color write" .-> WBUF
    WBUF -. "burst write" .-> FB

    subgraph display["Display · per scanline"]
        SCAN["Scanline Prefetch<br/>(burst read)"]
        CLUT["Color Grade LUT<br/>R32 · G64 · B32<br/>RGB565 → RGB888"]
        HSCALE["Horizontal Scale<br/>(nearest-neighbor)"]
        TMDS["DVI TMDS Encode<br/>+ 10:1 Serialize"]
        SCAN --> CLUT --> HSCALE --> TMDS
    end

    FB -. "scanline burst" .-> SCAN
    TMDS -. "HDMI" .-> HDMI[("DVI Output<br/>640×480 @ 60 Hz")]
```

After framebuffer write, the display controller (UNIT-008) prefetches scanlines via burst reads from SDRAM, applies the optional color-grade LUT (three per-channel 1D tables producing RGB888 — see REQ-006.03), scales horizontally to 640 pixels (see [Display Scaling](#display-scaling)), and feeds the DVI TMDS encoder (UNIT-009) at 25 MHz pixel clock.
The LUT is double-buffered in EBR and auto-loaded from SDRAM via DMA during vblank.

### Per-fragment data lanes

Each column shows a value's lifetime from production (first ●) to last consumption (last ●).

| Stage | x, y | z | shade0 | shade1 | uv | lod | tex0 | tex1 | comb | color | SDRAM access |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|---|
| Rasterizer | ● | ● | ● | ● | ● | ● | | | | | |
| Stipple Test | ● | ● | ● | ● | ● | ● | | | | | |
| Depth Range Clip | ● | ● | ● | ● | ● | ● | | | | | |
| Early Z Test | ● | ● | ● | ● | ● | ● | | | | | Z-buffer read |
| Texture Sample | ● | ● | ● | ● | ● | ● | ● | ● | | | Texture read (cache miss) |
| Color Combiner 0 | ● | ● | ● | ● | | | ● | ● | ● | | |
| Color Combiner 1 | ● | ● | ● | ● | | | ● | ● | ● | ● | |
| Alpha Test | ● | ● | | | | | | | | ● | |
| Alpha Blend | ● | ● | | | | | | | | ● | Framebuffer read (dst) |
| Dither | ● | ● | | | | | | | | ● | |
| Pixel Write | ● | ● | | | | | | | | ● | FB write, Z write |

**Widths:** x, y are Q12.4 (32 bits total); z is 16-bit unsigned; uv is 4 × Q4.12 (64 bits for both TEX0 + TEX1 coordinates; each 16-bit component is Q4.12 signed, carrying true perspective-correct U, V ready for texel addressing); lod is UQ4.4 (8 bits: 4-bit integer mip level, 4-bit trilinear blend fraction, derived from interpolated Q = 1/W by the rasterizer); all colors (shade, tex, comb, color) are Q4.12 RGBA (4 × 16-bit = 64 bits).
Register-file values **CONST0**, **CONST1**, and **CC_MODE** are side inputs to the combiner, not per-fragment data.
After dither, color is truncated to RGB565 (16-bit) for framebuffer write.

## Host Interface

The FPGA's SPI slave accepts standard SPI Mode 0 at up to 62.5 MHz.
At 62.5 MHz, the 72-bit transaction format yields approximately 868K register writes per second — roughly 960 non-textured or 640 textured triangles per frame at 60 fps.
SPI bandwidth, not vertex compute, is the primary throughput bottleneck.

The reference host is pico-racer (https://github.com/londey/pico-racer), which supports both a Raspberry Pi Pico 2 (RP2350, 62.5 MHz SPI) and a PC via FT232H USB-to-SPI adapter (30 MHz).
All vertex transformation, lighting, back-face culling, clipping, and scene management run in the host application; the GPU receives pre-transformed register writes.

A future upgrade path widens the interface to quad SPI via the RP2350's PIO, using four data lines at 37.5 MHz for approximately 2M register writes per second (2.4x improvement) with only two additional GPIO pins.
The FPGA slave change is minimal: widening the shift register input from 1 to 4 bits.
The FT232H debug path would remain on standard SPI.

## Rendering Techniques

The color combiner's `(A-B)*C+D` equation, combined with dual texture units and two pipelined combiner stages, supports several classic rendering techniques in a single pass:

- **Textured Gouraud:** `TEX0 * SHADE0` — diffuse texture modulated by per-vertex lighting.
- **Lightmapping:** `TEX0 * TEX1` — diffuse texture (UV0) multiplied by a pre-computed lightmap (UV1).
  Unlike the N64 RDP, both texture units are sampled in a single pipeline pass with no throughput penalty.
- **Lightmap + dynamic fill light:** `TEX0 * TEX1 + SHADE0` — additive per-vertex contribution on top of lightmapped surfaces.
- **Specular highlight (two-stage):** Stage 0 computes `TEX0 * SHADE0` (diffuse); stage 1 adds the specular color via `COMBINED + SHADE1`.
  The host computes both diffuse and specular lighting per-vertex; the combiner composites them in a single pass.
- **Fog (two-stage):** Stage 0 computes lit/textured color; stage 1 blends COMBINED toward CONST1 (fog color) using vertex alpha as the fog factor.
- **Decal / solid color:** `TEX0 * ONE` or `CONST0 * ONE` — trivial pass-through configurations.

Multi-pass rendering extends the repertoire to environment mapping over lightmapped surfaces and similar effects that require more than two texture samples.

## Surface Tiling

All color buffers and Z-buffers use 4×4 block-tiled layout in SDRAM, matching the texture cache's native block format.
Pixels within each 4×4 block are stored in row-major order; blocks themselves are arranged in row-major order across the surface.
Surface dimensions must be power-of-two per axis (non-square permitted) — the tiled address calculation uses only shifts and masks, requiring no multiply hardware.

For a pixel at position (x, y) in a surface with width 2^WIDTH_LOG2:

```
block_x    = x >> 2
block_y    = y >> 2
local_x    = x & 3
local_y    = y & 3
block_idx  = (block_y << (WIDTH_LOG2 - 2)) | block_x
byte_addr  = base + block_idx * 32 + (local_y * 4 + local_x) * 2
```

This layout unifies framebuffers, Z-buffers, and textures: a completed render target can be bound directly as a texture source (format `RGB565` tiled) with no format conversion or copy.
The block-tiled layout also aligns with the texture cache's 4×4 block fetch unit, ensuring that render-target-as-texture sampling uses the same cache path as any other texture.

Because all blocks in a power-of-two surface are contiguous in SDRAM, the existing MEM_FILL command clears any render target with a single linear fill — no block-aware fill command is required.

## Render to Texture

The GPU supports rendering to off-screen power-of-two surfaces that can subsequently be sampled as textures.
FB_CONFIG specifies the active render target (color base, Z-base, and surface dimensions); the host reprograms it between passes.
A paired Z-buffer at Z_BASE always has the same dimensions as the color buffer.

Typical render-to-texture flow:

1. Write FB_CONFIG with the render target's base addresses and dimensions.
2. Clear color and Z via MEM_FILL (contiguous for any power-of-two surface).
3. Set scissor rectangle and render the off-screen scene.
4. Write FB_CONFIG back to the display framebuffer.
5. Write TEX0_CFG with the render target's base address, dimensions, and format (RGB565).
   This implicitly invalidates the texture cache for the sampler.
6. Render geometry that samples from the render target.
7. Write FB_DISPLAY to present the display framebuffer at VSYNC.

Since the display framebuffer is also a power-of-two tiled surface (typically 512×512), it can itself be bound as a texture source — enabling the front buffer to be sampled in a subsequent frame for effects such as motion blur or rear-view mirrors.

Self-referencing (sampling from the current render target while writing to it) is not supported.

## Display Scaling

The DVI output is fixed at 640×480 at 60 Hz.
The display framebuffer may be smaller than the display resolution: the display controller stretches the source image horizontally to fill 640 pixels per scanline.
Two display modes are supported:

| Mode | Source | Horizontal | Vertical | Use case |
|------|--------|------------|----------|----------|
| 512×480 | 512-wide surface, 480 active rows | 512→640 stretch | 1:1 row mapping | Default rendering |
| 256×240 | 256-wide surface, 240 active rows | 256→640 stretch | Line doubling (each row output twice) | Half-resolution / retro |

The framebuffer surface is always power-of-two (512×512 or 256×256).
In 512×480 mode, the bottom 32 rows of the 512×512 surface are not scanned out and may be left unused or repurposed by the host for small data.

Horizontal scaling uses nearest-neighbor interpolation via a Bresenham-style accumulator — no multiply hardware is required.
The scaling ratio for 512→640 is 4:5, producing a repeating 5-pixel pattern where one source pixel is doubled.
For 256→640 the ratio is 2:5.

Interpolation operates on UNORM8 values post color-grade LUT, ensuring that the LUT's tone mapping is applied before any pixel blending.

FB_DISPLAY latches the display mode fields (FB_WIDTH_LOG2, LINE_DOUBLE) atomically at VSYNC, independent of FB_CONFIG.
This allows the host to freely reprogram FB_CONFIG for render-to-texture passes during the frame without affecting the active scanout.

This approach mirrors classic console practice — many PS2 titles rendered at 512 pixels wide (a power-of-two convenient for the Graphics Synthesizer's block-based memory) and relied on the display output to scale to the television's native resolution.

## Memory System

### SDRAM Bus and Pixel Addressing

The GPU uses a single 16-bit SDRAM (Winbond W9825G6KH-6) at 100 MHz, providing a peak bandwidth of 200 MB/s.
This single bus is shared by four consumers in fixed-priority order: display scanout (highest), framebuffer writes, Z-buffer read/write, and texture cache fills (lowest).

Both the framebuffer (RGB565) and Z-buffer (16-bit depth) use **native 16-bit addressing**: each pixel occupies exactly one 16-bit SDRAM column.
This eliminates the waste of padding 16-bit values into 32-bit words — every SDRAM column transfer carries useful data.

Pixel and depth addresses are computed directly:

```
pixel_addr = FB_BASE + block_addr(x, y)    [16-bit word address]
z_addr     = Z_BASE  + block_addr(x, y)    [16-bit word address]
```

A 512×512 framebuffer occupies 512 KB; a double-buffered framebuffer plus Z-buffer totals ~1.5 MB, well within the 32 MiB SDRAM.

### Bandwidth Budget

| Consumer | Rate (512×480 @ 60 Hz) | Priority | Notes |
|---|---|---|---|
| Display scanout | ~30 MB/s | Highest | Burst reads, 1 word/pixel; rate scales with `1<<FB_WIDTH_LOG2` |
| FB color writes | Variable | 2 | Burst-coalesced |
| Z-buffer R/W | Variable | 3 | Cached (tile cache) |
| Texture fills | Variable | Lowest | Cached (texture cache) |

Display scanout consumes ~15% of peak bandwidth at 512×480 (the default configuration), leaving ~170 MB/s for rendering.
At 256×240 with LINE_DOUBLE enabled, display scanout halves to ~15 MB/s, freeing additional bandwidth for rendering.

### Z-Buffer Tile Cache

The Z-buffer has the worst per-fragment bandwidth profile: every visible fragment requires a read-compare-conditional-write cycle on the same address.
A small on-chip cache absorbs this traffic, following industry precedent (NVIDIA GeForce 256, ATI HyperZ).

**Geometry:** 4-way set-associative, 16 sets.
Each cache line holds a 4×4 tile of 16-bit Z values (256 bits = 32 bytes), aligned with the surface tiling format.

**Behavior:**
1. **Hit:** Z value read from on-chip EBR in 1 cycle. If the fragment passes, the cached value is updated and the line marked dirty. Zero SDRAM traffic.
2. **Miss:** Dirty line evicted as a 16-word burst write; new line filled as a 16-word burst read (~44 cycles total, amortized over up to 16 subsequent hits). After a Hi-Z fast clear, the first miss for any tile initializes the fill data to 0xFFFF (lazy initialization) rather than reading from SDRAM.
3. **Write-back policy:** Dirty lines are written to SDRAM only on eviction or explicit end-of-frame flush (before buffer swap).

Expected hit rate is 85–95% depending on scene complexity and overdraw, reducing Z-buffer SDRAM traffic by 5–7×.
The cache controller reuses the same set-associative structure, XOR set indexing, and burst fill/evict FSM proven in the texture cache.

**Cost:** 4–5 EBR, ~300–400 LUTs.

### Hierarchical Z (Hi-Z) Block Metadata

A second tier of depth culling operates at 4×4 tile granularity in the rasterizer (UNIT-005.05), upstream of the per-pixel early Z test in UNIT-006.
Eight DP16KD blocks store per-tile metadata: a 9-bit min_z value (Z[15:7] of the minimum Z written to the tile) per entry, packed four entries per 36-bit word.
A sentinel value of 9'h1FF (all-ones) means no Z-writes have occurred to that tile since the last clear.
The rasterizer's FSM enters the HIZ_TEST state after TILE_TEST passes; if the tile's stored min_z is not the sentinel and exceeds the incoming fragment Z[15:7] under the active comparison function, the entire tile is skipped without entering EDGE_TEST or emitting any fragments.

The Z-cache (UNIT-006) holds a companion 128×128 1-bit uninitialized flag array in a separate DP16KD (32-bit wide, 512 addresses, 16,384 flags).
This flag tracks whether each 4×4 tile has been written since the last clear; its ownership in UNIT-006 keeps it co-located with the Z-cache logic that consumes it for lazy initialization.

This enables two optimizations:

- **Hierarchical Z rejection:** Entire 4×4 tiles are discarded before SDRAM or texture traffic is generated, saving all downstream pipeline work for occluded geometry.
- **Fast Z clear:** A two-phase EBR invalidation replaces bulk SDRAM writes: UNIT-005.06 sweeps the Hi-Z metadata with the sentinel value 9'h1FF (~512 cycles), and UNIT-006 resets the uninitialized flag EBR to all-ones (~512 cycles, concurrently).
  The Z-buffer SDRAM region is initialized lazily: the first cache miss after a fast clear checks the uninitialized flag; if set, the Z-cache supplies 0xFFFF for the tile without reading SDRAM and clears the flag.
  Z-clear time is reduced by approximately 520× (from ~2.66 ms to ~5.12 µs).

The Hi-Z metadata is updated on every Z-write: if the written Z[15:7] is less than the stored min_z for that tile, the metadata min_z is updated.
Hi-Z is bypassed when Z_TEST_EN=0 or Z_COMPARE=ALWAYS (no rejection possible without a meaningful depth threshold).

**Cost:** 8 EBR (DP16KD, 36-bit wide) for Hi-Z metadata + 1 EBR (DP16KD, 32-bit wide) for Z-cache uninitialized flags, ~200–300 LUTs.

### Burst Coalescing

A write-coalescing buffer sits between the pixel pipeline and the SDRAM arbiter.
When the pixel pipeline emits a run of adjacent passing fragments on the same scanline (or within the same 4×4 tile), the buffer collects them and issues a single SDRAM burst write rather than individual single-word transactions.
The rasterizer walks tiles in 4×4 order and feeds fragments to the pixel pipeline; the coalescing buffer observes the output of the full pixel pipeline (post-depth-test, post-blend) rather than the raw rasterizer output.

Within an active SDRAM row, sequential 16-bit writes deliver 1 word/cycle after the initial overhead, so a 16-pixel tile write completes in ~24 cycles (1.5 cycles/pixel) versus ~9 cycles per individual write.

**Cost:** ~100–150 LUTs, zero EBR (distributed RAM).

### EBR Budget

The texture cache uses a two-level architecture per sampler: L1 decoded (PDPW16KD 512×36, UQ1.8) and L2 compressed (DP16KD 1024×16, format-aware packing).

| Component | EBR | Notes |
|---|---|---|
| Texture L1 decoded (2 samplers) | 8 | 4 per sampler; PDPW16KD 512×36 (UQ1.8) |
| Texture L2 compressed (2 samplers) | 8 | 4 per sampler; DP16KD 1024×16 (64-bit entries) |
| Z-buffer tile cache | 4–5 | 4-way, 16 sets, 4×4 tiles |
| Z-cache uninitialized flags | 1 | DP16KD 32-bit wide; 16,384 1-bit flags as 512 words (UNIT-006) |
| Hi-Z block metadata | 8 | DP16KD 36-bit wide; 9-bit min_z per tile (Z[15:7], sentinel 0x1FF), 4 entries per word |
| Command FIFO | 2 | 512×72 async CDC |
| Reciprocal LUT (area) | 1 | DP16KD 36×512, inv_area seed+delta |
| Reciprocal LUT (1/Q) | 1 | DP16KD 18×1024, per-pixel 1/Q |
| Dither matrix | 1 | 16×16 blue noise |
| Color grading LUT | 1 | 128-entry RGB |
| Scanline FIFO | 1 | 1024×16 display |
| FB write buffer | 1 | Single-tile coalescing buffer |
| **Total** | **37–38** | **of 56 available (ECP5-25K)** |

### Throughput

With native 16-bit addressing, burst coalescing, and Z-buffer caching, the pixel pipeline sustains approximately 28–35 Mpixels/sec output throughput for typical triangle workloads — sufficient for >1× overdraw at 640×480 @ 60 Hz (18.4 Mpixels/sec visible).
The rasterizer feeds the pixel pipeline at up to one fragment per clock; the pipeline may stall on texture cache misses, reducing effective throughput below this peak.

---

<!-- syskit-arch-start -->
### Block Diagram

```mermaid
flowchart LR
    UNIT_001["UNIT-001: SPI Slave Controller"]
    UNIT_002["UNIT-002: Command FIFO"]
    UNIT_003["UNIT-003: Register File"]
    subgraph UNIT_005["UNIT-005: Rasterizer"]
        UNIT_005_01["UNIT-005.01: Triangle Setup"]
        UNIT_005_02["UNIT-005.02: Edge Setup"]
        UNIT_005_03["UNIT-005.03: Derivative Pre-computation"]
        UNIT_005_04["UNIT-005.04: Attribute Accumulation"]
        UNIT_005_05["UNIT-005.05: Iteration FSM"]
        UNIT_005_06["UNIT-005.06: Hi-Z Block Metadata"]
    end
    UNIT_006["UNIT-006: Pixel Pipeline"]
    UNIT_007["UNIT-007: Memory Arbiter"]
    UNIT_008["UNIT-008: Display Controller"]
    UNIT_009["UNIT-009: DVI TMDS Encoder"]
    UNIT_010["UNIT-010: Color Combiner"]
    subgraph UNIT_011["UNIT-011: Texture Sampler"]
        UNIT_011_01["UNIT-011.01: UV Coordinate Processing"]
        UNIT_011_02["UNIT-011.02: Bilinear/Trilinear Filter"]
        UNIT_011_03["UNIT-011.03: L1 Decompressed Cache"]
        UNIT_011_04["UNIT-011.04: Block Decompressor"]
        UNIT_011_05["UNIT-011.05: L2 Compressed Cache"]
    end
    UNIT_012["UNIT-012: Z-Buffer Tile Cache"]
    UNIT_001 -->|INT-001| UNIT_001
    UNIT_009 -->|INT-002| UNIT_009
    UNIT_003 -->|INT-010| UNIT_001
    UNIT_003 -->|INT-010| UNIT_005
    UNIT_003 -->|INT-010| UNIT_006
    UNIT_003 -->|INT-010| UNIT_008
    UNIT_003 -->|INT-010| UNIT_010
    UNIT_003 -->|INT-010| UNIT_011_01
    UNIT_003 -->|INT-010| UNIT_011_02
    UNIT_003 -->|INT-010| UNIT_011_03
    UNIT_003 -->|INT-010| UNIT_011_04
    UNIT_003 -->|INT-010| UNIT_011_05
    UNIT_003 -->|INT-010| UNIT_011
```

### Software Units

| Unit | Title | Purpose |
|------|-------|---------|
| UNIT-001 | SPI Slave Controller | Receives 72-bit SPI transactions and writes to register file |
| UNIT-002 | Command FIFO | Buffers GPU commands with flow control and provides autonomous boot-time command execution via pre-populated FIFO entries. |
| UNIT-003 | Register File | Stores GPU state and vertex data |
| UNIT-005.01 | Triangle Setup | Validates incoming triangle data, computes the signed triangle area, performs backface culling, and passes vertex positions and attributes to the rasterizer pipeline. |
| UNIT-005.02 | Edge Setup | Computes edge function coefficients, bounding box, and the internal triangle area reciprocal for a triangle. |
| UNIT-005.03 | Derivative Pre-computation | Evaluates initial edge functions and computes per-attribute derivatives at the bounding box origin. |
| UNIT-005.04 | Attribute Accumulation | Maintains per-attribute accumulators and produces interpolated fragment values via incremental addition. |
| UNIT-005.05 | Iteration FSM | Drives the 4×4 tile-ordered bounding box walk, hierarchical tile rejection, edge testing, perspective correction pipeline, and fragment output handshake. |
| UNIT-005.06 | Hi-Z Block Metadata | Per-tile metadata store that enables two Z-buffer optimizations: fast clear (bulk-writing sentinel values to metadata in 512 cycles instead of filling SDRAM in ~266,000 cycles) and hierarchical Z (Hi-Z) tile rejection (rejecting entire 4x4 tiles in the rasterizer before any fragments are emitted). |
| UNIT-005 | Rasterizer | Incremental derivative-based rasterization engine with internal perspective correction. |
| UNIT-006 | Pixel Pipeline | Stipple test, depth range clipping, early Z-test, texture dispatch to UNIT-011, color combination, alpha blending, ordered dithering, and framebuffer write. |
| UNIT-007 | Memory Arbiter | Arbitrates SDRAM access between display and render |
| UNIT-008 | Display Controller | Scanline FIFO and display pipeline |
| UNIT-009 | DVI TMDS Encoder | TMDS encoding and differential output |
| UNIT-010 | Color Combiner | Two-stage pipelined programmable color combiner that produces a final fragment color from multiple input sources. |
| UNIT-011.01 | UV Coordinate Processing | Applies wrap mode, clamp, mirror-repeat, and swizzle pattern to incoming Q4.12 UV coordinates, then selects the final mip level by combining `frag_lod` with `TEXn_MIP_BIAS`. |
| UNIT-011.02 | Bilinear/Trilinear Filter | Fetches a 2×2 bilinear quad from the four interleaved L1 EBR banks (one texel per bank per cycle), computes bilinear interpolation weights from sub-texel UV fractions, and—when trilinear filtering is enabled—blends two bilinear results from adjacent mip levels using the fractional part of `frag_lod` as the blend weight. |
| UNIT-011.03 | L1 Decompressed Cache | Per-sampler 4-way set-associative cache storing decompressed 4×4 texel blocks in UQ1.8 format (36 bits per texel). |
| UNIT-011.04 | Block Decompressor | Decodes a compressed or uncompressed 4×4 texel block from its raw SDRAM format into 16 UQ1.8 RGBA texels for storage in UNIT-011.03 (L1 Decompressed Cache), then promotes the UQ1.8 output to Q4.12 via `texel_promote.sv` before passing texels to the color combiner pipeline. |
| UNIT-011.05 | L2 Compressed Cache | Per-sampler direct-mapped cache storing raw compressed or uncompressed 4×4 block data fetched from SDRAM. |
| UNIT-011 | Texture Sampler | Two-sampler texture pipeline providing decoded Q4.12 RGBA texel data to UNIT-006 (Pixel Pipeline). |
| UNIT-012 | Z-Buffer Tile Cache | 4-way set-associative write-back Z-buffer tile cache with per-tile uninitialized flag tracking. |
<!-- syskit-arch-end -->
