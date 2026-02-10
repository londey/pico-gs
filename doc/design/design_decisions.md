# Design Decisions

This document records significant design decisions using a lightweight Architecture Decision Record (ADR) format.

## Template

When adding a new decision, copy this template:

```markdown
## DD-NNN: <Title>

**Date:** YYYY-MM-DD  
**Status:** Proposed | Accepted | Superseded by DD-XXX

### Context

<What is the issue or question that needs a decision?>

### Decision

<What is the decision that was made?>

### Rationale

<Why was this decision made? What alternatives were considered?>

### Consequences

<What are the implications of this decision?>
```

---

## Decisions

<!-- Add decisions below, newest first -->


## DD-010: Per-Sampler Texture Cache Architecture

**Date:** 2026-02-10
**Status:** Accepted

### Context

Bilinear texture sampling with 4 texture units requires up to 16 SRAM reads per pixel (4 texels x 4 units). At 200 MB/s peak SRAM bandwidth shared with display scanout, Z-buffer, and framebuffer writes, texture fetch bandwidth is the primary bottleneck for textured rendering. The 30 MB/s texture fetch budget (INT-011) is insufficient for multi-textured bilinear sampling.

### Decision

Add a 4-way set-associative texture cache per sampler (4 caches total):
- 4 x 1024 x 18-bit EBR banks per cache, interleaved by texel (x%2, y%2) for single-cycle bilinear reads
- Cache line = decompressed 4x4 RGBA5652 block (18 bits per texel)
- 64 sets with XOR-folded indexing (set = block_x ^ block_y) to prevent row aliasing
- Implicit invalidation on TEXn_BASE/TEXn_FMT register writes
- 16 EBR blocks total (288 Kbits, 33% of BRAM budget)

### Rationale

- **4-way associativity**: Handles block-boundary bilinear (2 ways for adjacent blocks), mip-level block (1 way), and one spare. 2-way would thrash at block boundaries; 8-way has diminishing returns with higher LUT cost for tag comparison
- **RGBA5652 (18-bit)**: Matches ECP5 EBR native 1024x18 configuration (zero wasted bits). RGB565 base is framebuffer-compatible. 2-bit alpha covers BC1 punch-through alpha
- **XOR set indexing**: Linear indexing maps every block row (e.g., 64 blocks for 256-wide texture) to the same 64 sets, causing vertically adjacent blocks to always alias. XOR is zero-cost in hardware (XOR gates on address bits) and eliminates this systematic aliasing. No impact on asset pipeline or physical memory layout
- **Per-sampler caches**: Avoids contention between texture units; each cache operates independently with its own tags and replacement policy

### Consequences

- +16 EBR blocks consumed (28.6% of ECP5-25k's 56 EBR). Leaves 37 EBR blocks free
- +~800-1600 LUTs total for tag storage, comparison, control logic, and fill FSMs across all 4 samplers
- Enables single-cycle bilinear texture sampling at >85% cache hit rate
- BC1 decompression cost amortized over cache line lifetime (16 texels per decompress)
- RGBA4444 alpha precision reduced from 4-bit to 2-bit in cache (acceptable: framebuffer has no alpha channel)
- Texture SRAM bandwidth reduced from ~30 MB/s to ~5-15 MB/s average, freeing ~15-25 MB/s for other consumers

---


## DD-011: 10.8 Fixed-Point Fragment Processing

**Date:** 2026-02-10
**Status:** Accepted

### Context

8-bit integer fragment processing (RGBA8) causes visible banding artifacts in smooth gradients due to cumulative quantization errors across multiple blending stages (texture blend × vertex color × alpha blend). Each multiply reduces precision, and truncation compounds errors through the chain. The ECP5-25K FPGA has 28 DSP slices with native 18×18 multipliers.

### Decision

Use always-on 10.8 fixed-point format (18 bits per channel) for all internal fragment processing:
- 10 integer bits: 8 for the [0,255] input range + 2 bits overflow headroom for additive blending
- 8 fractional bits: preserve precision through multiply chains
- No configurable mode — always-on replaces RGBA8 math permanently

### Rationale

- **Matches hardware**: ECP5 DSP slices are 18×18 — wider inputs are free in silicon, no reason for a narrow mode
- **Overflow headroom**: 2 extra integer bits prevent clipping during additive texture blending (ADD, SUBTRACT modes)
- **Precision preservation**: 8 fractional bits retain sub-pixel accuracy through multiply chains (8×8→16-bit result retained)
- **Simplicity**: No configurable precision mode reduces hardware complexity and validation effort
- **Alternatives considered**: RGBA8 (insufficient for cumulative blending), 16-bit integer (doesn't match DSP width), floating-point (too expensive in FPGA LUTs)

### Consequences

- +6-12 DSP slices for 18×18 multipliers (texture blend, vertex color, alpha blend)
- +~1500-2500 LUTs for wider datapaths and saturation logic
- Eliminates visible banding in multi-stage blend chains
- Vertex color input (ABGR8888 register) promoted to 10.8 on entry: `value_10_8 = {2'b0, value_8, 8'b0}`
- See REQ-134 for full specification

---


## DD-012: Blue Noise Dithering for RGB565 Conversion

**Date:** 2026-02-10
**Status:** Accepted

### Context

Converting 10.8 fixed-point fragment colors to RGB565 format discards fractional bits and reduces integer precision (10→5/6/5 bits), causing visible banding in smooth gradients. Dithering trades spatial resolution for color resolution, creating the perception of smoother gradients than the output format can represent.

### Decision

Use a 16×16 blue noise dither pattern stored in 1 EBR block:
- 256 entries × 18 bits (native ECP5 1024×18 configuration)
- 6 bits stored per component (R, G, B) packed into 18 bits per entry
- Channel-specific scaling: top 3 bits for R/B (losing 3 bits in 8→5), top 2 bits for G (losing 2 bits in 8→6)
- Pattern indexed by `{screen_y[3:0], screen_x[3:0]}`
- Baked into EBR at synthesis time (not runtime-configurable)
- Enabled by default; can be disabled via DITHER_MODE register (0x32)

### Rationale

- **Blue noise**: Minimizes low-frequency artifacts (less perceptible than Bayer or white noise). Pushes quantization error to high spatial frequencies
- **16×16 pattern**: Small enough for 1 EBR, large enough to avoid visible tiling at normal viewing distance
- **Channel-specific scaling**: Matches actual quantization step size per channel (R/B lose 3 bits, G loses 2 bits)
- **Alternatives considered**: Bayer ordered dither (visible cross-hatch pattern), white noise (uniform but more visible), error diffusion (sequential dependency, not pipelinable)

### Consequences

- +1 EBR block (total EBR: 17→18 of 56, 32.1%)
- +1 pipeline cycle latency (EBR read, fully pipelined — no throughput reduction)
- +~100-200 LUTs for dither scaling and addition
- Smooth gradients in RGB565 output even with large flat-shaded or textured surfaces
- See REQ-132 for full specification

---


## DD-013: Color Grading LUT at Display Scanout

**Date:** 2026-02-10
**Status:** Accepted

### Context

Post-processing effects like gamma correction, color temperature adjustment, and artistic color grading are traditionally applied by re-rendering or using compute shaders. For a fixed-function GPU without compute shaders, a hardware LUT provides real-time color transformation.

The LUT can be placed either at pixel write (in the render pipeline) or at display scanout (in the display controller). Placement at scanout means the LUT operates on the final framebuffer content, after all rendering is complete.

### Decision

Place 3× 1D color grading LUTs at display scanout in the display controller (UNIT-008):
- Red LUT: 32 entries × RGB888 (indexed by R5 of RGB565 pixel)
- Green LUT: 64 entries × RGB888 (indexed by G6 of RGB565 pixel)
- Blue LUT: 32 entries × RGB888 (indexed by B5 of RGB565 pixel)
- Outputs summed with saturation per channel: `final = clamp(R_LUT[R5] + G_LUT[G6] + B_LUT[B5])` at 8-bit (255)
- Double-buffered (write inactive bank, swap at vblank)
- 1 EBR block total (512×36 configuration), bypass when disabled
- Host upload via COLOR_GRADE_LUT_ADDR/DATA registers (0x45/0x46)

### Rationale

- **Scanout placement**: No overdraw waste (each pixel processed exactly once), alpha blending operates in linear space (correct), LUT can be changed without re-rendering
- **RGB565-native indices**: 32/64/32 entries with RGB888 output fit in 1 EBR (512×36 config) (vs 256 entries per channel = 3 EBR for 8-bit indices)
- **Cross-channel output**: Each LUT produces RGB output, enabling effects like color tinting (red input influences green output)
- **Double-buffering**: Prevents tearing during LUT updates
- **Alternatives considered**: Per-pixel LUT at render time (wastes work on overdraw), single per-channel LUT (no cross-channel effects), 3D LUT (too large for EBR)

### Consequences

- +1 EBR block (total EBR: 18 of 56, 32.1%)
- +2 cycles scanout latency (1 EBR read + 1 sum/saturate — fits within pixel period at 100MHz)
- +~230 LUTs for summation and saturation (8-bit adders)
- +~100 FFs for control FSM (upload, bank swap)
- Real-time gamma correction, color temperature, artistic grading with no render overhead
- See REQ-133 for full specification

---


## DD-001: PS2 Graphics Synthesizer Reference

**Date:** 2026-02-08
**Status:** Accepted

### Context

The project needed an architectural reference for a fixed-function 3D GPU targeting a small FPGA. The PS2 Graphics Synthesizer (GS) provides a well-documented model of a register-driven, triangle-based rasterizer with texture mapping — closely matching the capabilities achievable on an ECP5-25K.

### Decision

Use the PS2 GS architecture as the primary design reference: register-driven vertex submission, fixed-function triangle rasterization with Gouraud shading, hardware Z-buffering, and multi-texture support via independent texture units.

### Rationale

The PS2 GS is well-documented, uses a register-based command interface (suitable for SPI), and its feature set (textured triangles, alpha blending, Z-buffer) maps well to ECP5 resources. More complex GPU architectures (unified shaders, tile-based rendering) exceed the FPGA budget.

### Consequences

- Fixed-function pipeline limits flexibility but simplifies hardware and verification
- Register-driven interface maps naturally to SPI command transactions
- Feature scope bounded by PS2 GS capabilities (no programmable shaders, no tessellation)

---


## DD-002: ECP5 FPGA Resources

**Date:** 2026-02-08
**Status:** Accepted

### Context

The GPU must fit within a Lattice ECP5-25K FPGA. Resource budgets constrain every architectural decision.

### Decision

Target the ECP5-25K (LFE5U-25F) with the following resource budget: ~24K LUTs, 56 EBR blocks (1,008 Kbits BRAM), 28 DSP slices (18×18 multipliers), and 4 SERDES channels for DVI output.

### Rationale

The ECP5-25K is the smallest ECP5 variant with enough resources for a basic 3D pipeline, and has full open-source toolchain support (Yosys + nextpnr). Larger variants (45K, 85K) cost more and aren't needed for the target feature set.

### Consequences

- All hardware features must fit within 24K LUTs, 56 EBR, 28 DSP budget
- EBR blocks are the scarcest resource — texture cache, dither matrix, color LUT, and FIFOs compete for 56 blocks
- DSP slices enable hardware multiply for barycentric interpolation and fixed-point math
- SERDES provides DVI/HDMI output without external serializer chips

---


## DD-003: DVI/HDMI Output

**Date:** 2026-02-08
**Status:** Accepted

### Context

The GPU needs a video output standard compatible with common monitors. Options include VGA (analog), DVI (digital), and HDMI (digital + audio).

### Decision

Use DVI TMDS output at 640×480@60Hz over an HDMI-compatible connector, using the ECP5 SERDES for serialization.

### Rationale

DVI is electrically compatible with HDMI for video-only output. 640×480@60Hz requires a 25.175 MHz pixel clock, well within ECP5 PLL range. The ECP5 SERDES handles 10:1 serialization at 251.75 MHz (10× pixel clock). VGA was rejected due to requiring external DAC.

### Consequences

- Requires PLL configuration for 25.175 MHz pixel clock and 251.75 MHz SERDES clock
- HDMI monitors accept DVI signals natively (video-only, no audio)
- Resolution fixed at 640×480 to stay within SRAM bandwidth limits
- 4 SERDES channels used (R, G, B, clock)

---


## DD-004: Rust with rp235x-hal

**Date:** 2026-02-08
**Status:** Accepted

### Context

The RP2350 host firmware needs a language and HAL. Rust was specified as the language. The choice is between bare-metal HAL and async frameworks.

### Decision

Use Rust with `rp235x-hal` (bare-metal, no Embassy). Direct access to SPI, DMA, GPIO, and multicore primitives with deterministic timing.

### Rationale

`rp235x-hal` is the community-standard HAL for RP2350, based on the mature `rp2040-hal`. A bare-metal approach (vs Embassy async) gives deterministic timing essential for 30+ FPS real-time rendering on the render core. Embassy's cooperative scheduling adds unpredictable latency.

### Consequences

- Deterministic timing for render loop on Core 1
- No async runtime overhead; interrupt-driven where needed
- Must manually manage concurrency between cores
- Ecosystem limited to `no_std` crates

---


## DD-005: Cortex-M33 Target and Toolchain

**Date:** 2026-02-08
**Status:** Accepted

### Context

The RP2350 has dual Cortex-M33 cores (with hardware FPU) and dual RISC-V cores. A target and toolchain must be chosen.

### Decision

Use `thumbv8m.main-none-eabihf` target (Cortex-M33 with hardware FPU). Build with `probe-rs` for flash/debug, `flip-link` for stack overflow protection, and `defmt` for logging.

### Rationale

The Cortex-M33 cores have a single-precision hardware FPU and DSP extensions. The `eabihf` target enables hardware float calling conventions, critical for matrix math and lighting performance.

### Consequences

- Hardware float for matrix/lighting calculations (no software emulation overhead)
- `probe-rs` enables SWD debug and flash programming
- `flip-link` provides stack overflow detection in debug builds
- `defmt` provides efficient logging over RTT

---


## DD-006: Dual-Core Communication via heapless SPSC Queue

**Date:** 2026-02-08
**Status:** Accepted

### Context

Core 0 (scene manager) must send render commands to Core 1 (render executor). The RP2350 hardware SIO FIFOs are only 8-deep × 32-bit, too small for render commands.

### Decision

Use `heapless::spsc::Queue` for the inter-core render command queue, with SIO FIFO doorbell signaling to wake Core 1.

### Rationale

`heapless::spsc::Queue` is a proven lock-free single-producer single-consumer queue requiring no allocator or mutexes. SIO FIFO signals "new commands available" to avoid busy-polling.

### Consequences

- Lock-free, wait-free command submission from Core 0
- Fixed queue capacity must be sized at compile time
- SIO doorbell avoids Core 1 busy-polling (power savings)
- Queue overflow must be handled by Core 0 (back-pressure)

---


## DD-007: PNG Decoding with image Crate

**Date:** 2026-02-08
**Status:** Accepted

### Context

The asset build tool needs to decode PNG textures and convert them to GPU-native formats (RGBA4444, BC1). A Rust PNG/image library is needed.

### Decision

Use the `image` crate (v0.25+) for PNG decoding in the asset build tool.

### Rationale

The `image` crate is the de facto standard for image processing in Rust. It provides `open()` and `to_rgba8()` for automatic color space conversion, handles PNG and other formats, and is actively maintained (10M+ downloads).

### Consequences

- Simple API for loading any image format to RGBA8
- Large dependency tree (acceptable for host-side build tool, not embedded)
- Future format support (JPEG, etc.) available without additional crates

---


## DD-008: OBJ Parsing with tobj Crate

**Date:** 2026-02-08
**Status:** Accepted

### Context

The asset build tool needs to parse Wavefront OBJ mesh files and extract vertex positions, normals, and UV coordinates.

### Decision

Use the `tobj` crate (v4.0+) for OBJ file parsing.

### Rationale

`tobj` is the most popular Rust OBJ parser (971K+ downloads). It supports triangulation, handles positions/normals/UVs, and provides a simple API.

### Consequences

- Automatic triangulation of non-triangle faces
- Handles all standard OBJ attributes needed (v, vt, vn, f)
- No MTL material support needed (textures assigned separately)

---


## DD-009: Greedy Sequential Triangle Packing

**Date:** 2026-02-08
**Status:** Accepted

### Context

Large meshes must be split into "patches" that fit within the GPU's per-draw vertex/index limits. A splitting algorithm is needed.

### Decision

Implement greedy sequential triangle packing: fill each patch with triangles in order until the next triangle would exceed vertex or index limits, then start a new patch.

### Rationale

- O(n) time complexity
- Deterministic output for the same input
- Simple to implement, debug, and maintain
- Accepts some vertex duplication at patch boundaries as an acceptable trade-off

### Consequences

- Vertex duplication at patch boundaries (~5-15% overhead for typical meshes)
- Triangle ordering preserved within patches (important for transparency)
- No spatial optimization (adjacent triangles may land in different patches)

---
