# Architecture

*A hobby 3D graphics processor on a small FPGA, named after the PS2 Graphics Synthesizer.*

## System Description

pico-gs is an educational/hobby 3D GPU implemented on the ICEpi Zero v1.3 development board (Lattice ECP5-25K FPGA, CABGA256) with 32 MiB of SDRAM (Winbond W9825G6KH-6).
It outputs 640x480 at 60 Hz as DVI on the board's HDMI port.

The GPU is driven over SPI from a Raspberry Pi Pico 2 (RP2350, dual Cortex-M33) host.
The same host software also runs on a PC via an FT232H USB-to-SPI adapter for desktop debugging.
Two GPIO lines provide hardware flow control: one signals when the command FIFO is nearly full, the other delivers a VSYNC pulse for frame synchronization.

The framebuffer is RGB565, the Z-buffer is 16-bit unsigned, and the pixel pipeline supports two independent texture units per pixel in a single pass.
The pipeline is fixed-function, inspired by the Nintendo 64 RDP's programmable color combiner — `(A-B)*C+D` applied independently to RGB and alpha — with additional features including blue noise dithering, per-channel color grading LUTs, DOT3 bump mapping, octahedral UV wrapping, and stipple-pattern fragment discard for order-independent transparency without framebuffer reads.

## Design Philosophy

The architecture is a hybrid of two classic console GPUs: the PS2 Graphics Synthesizer's register-driven vertex submission model and the N64 RDP's fixed-function pixel pipeline.
Rendering is strictly immediate mode — no display lists, no tile-based deferred rendering.

The host handles all vertex transformation, lighting, back-face culling, and clipping in software (Rust, `no_std`, using the RP2350's hardware FPU).
The GPU handles rasterization, texturing, depth testing, color combining, and scanout.
This split keeps the FPGA fabric focused on per-pixel throughput while the host's dual cores manage scene complexity.

Fragment processing uses Q4.12 signed fixed-point arithmetic (16-bit) as the pipeline-wide format, with colors normalized to 0.0–1.0.
All UNORM inputs — vertex colors, material constants, and texture samples — are promoted to Q4.12 at pipeline entry; output converts back to UNORM after optional dithering.
The signed representation naturally handles the `(A-B)` subtraction in the color combiner, and the 3-bit integer headroom above 1.0 (range up to ~8.0) accommodates additive blending without premature saturation.
The 12 fractional bits reduce accumulated quantization error through chained combiner stages and alpha blending, preserving gradient fidelity in dark tones.
Alpha blending promotes the framebuffer's UNORM value to Q4.12 before blending; the result follows the normal dither-and-write path.
The 16-bit operands fit within the ECP5's native 18×18 DSP multipliers; bilinear texture filtering still uses the 9×9 DSP sub-mode, as its inputs (≤8-bit texels and fractional UV weights) remain narrow enough to pack two multiplies per slice.
Memory bandwidth is managed through a 4-way set-associative texture cache (>90% hit rate), early Z rejection before texture fetch, and burst-oriented scanline-order traversal.

## Component Interactions

The host submits triangles as a stream of 72-bit register writes over SPI.
Each write carries a 7-bit register address and 64-bit data payload.
Per-vertex state (color, UVs, position) is accumulated in the register file (UNIT-003); the third vertex write triggers the hardware rasterizer.

The SPI slave (UNIT-001) feeds an asynchronous command FIFO (UNIT-002) that bridges the SPI clock domain to the 100 MHz core domain.
When the FIFO approaches capacity, the CMD_FULL GPIO tells the host to pause.

Triangle setup (UNIT-004) computes edge coefficients and performs backface culling.
The rasterizer (UNIT-005) walks the bounding box using edge-function increments, interpolating Z, two vertex colors, and two UV coordinate pairs per fragment.
The pixel pipeline (UNIT-006) performs early Z testing and dual-texture sampling through per-sampler caches.
The color combiner (UNIT-010) is a two-stage pipeline running at one pixel per clock: each stage evaluates `(A-B)*C+D` independently for RGB and alpha, selecting from texture colors, vertex colors, per-draw-call constant colors, and a combined-output feedback path.
Stage 0's output feeds stage 1 via the COMBINED source, enabling multi-texture blending, fog, and specular-add in a single pass; for simple single-equation rendering, stage 1 is configured as a pass-through.
After optional alpha blending and ordered dithering, fragments are written to the double-buffered framebuffer in SDRAM.

A four-port fixed-priority memory arbiter (UNIT-007) manages all SDRAM traffic: display scanout (highest), framebuffer writes, Z-buffer access, and texture cache fills (lowest).
The display controller (UNIT-008) prefetches scanlines into a FIFO and drives the DVI/TMDS encoder (UNIT-009) for 640x480 output.
Frame presentation is double-buffered — the host writes to one framebuffer while the display controller scans out the other, swapping atomically at VSYNC.

## Host Interface

The FPGA's SPI slave accepts standard SPI Mode 0 at up to 62.5 MHz from the RP2350's hardware SPI peripheral, or 30 MHz from the FT232H MPSSE (PC debug path).
At 62.5 MHz, the 72-bit transaction format yields approximately 868K register writes per second — roughly 960 non-textured or 640 textured triangles per frame at 60 fps.
SPI bandwidth, not vertex compute, is the primary throughput bottleneck.

A future upgrade path widens the interface to quad SPI via the RP2350's PIO, using four data lines at 37.5 MHz for approximately 2M register writes per second (2.4x improvement) with only two additional GPIO pins.
The FPGA slave change is minimal: widening the shift register input from 1 to 4 bits.
The FT232H debug path would remain on standard SPI.

## Rendering Techniques

The color combiner's `(A-B)*C+D` equation, combined with dual texture units and two pipelined combiner stages, supports several classic rendering techniques in a single pass:

- **Textured Gouraud:** `TEX0 * SHADE` — diffuse texture modulated by per-vertex lighting.
- **Lightmapping:** `TEX0 * TEX1` — diffuse texture (UV0) multiplied by a pre-computed lightmap (UV1).
  Unlike the N64 RDP, both texture units are sampled in a single pipeline pass with no throughput penalty.
- **Lightmap + dynamic fill light:** `TEX0 * TEX1 + SHADE` — additive per-vertex contribution on top of lightmapped surfaces.
- **Fog (two-stage):** Stage 0 computes lit/textured color; stage 1 blends COMBINED toward CONST1 (fog color) using vertex alpha as the fog factor.
- **Decal / solid color:** `TEX0 * ONE` or `CONST0 * ONE` — trivial pass-through configurations.

Multi-pass rendering extends the repertoire to environment mapping over lightmapped surfaces and similar effects that require more than two texture samples.

---

<!-- syskit-arch-start -->
### Block Diagram

```mermaid
flowchart LR
    UNIT_001["UNIT-001: SPI Slave Controller"]
    UNIT_002["UNIT-002: Command FIFO"]
    UNIT_003["UNIT-003: Register File"]
    UNIT_004["UNIT-004: Triangle Setup"]
    UNIT_005["UNIT-005: Rasterizer"]
    UNIT_006["UNIT-006: Pixel Pipeline"]
    UNIT_007["UNIT-007: Memory Arbiter"]
    UNIT_008["UNIT-008: Display Controller"]
    UNIT_009["UNIT-009: DVI TMDS Encoder"]
    UNIT_010["UNIT-010: Color Combiner"]
    UNIT_020["UNIT-020: Core 0 Scene Manager"]
    UNIT_021["UNIT-021: Core 1 Render Executor"]
    UNIT_022["UNIT-022: GPU Driver Layer"]
    UNIT_023["UNIT-023: Transformation Pipeline"]
    UNIT_024["UNIT-024: Lighting Calculator"]
    UNIT_025["UNIT-025: USB Keyboard Handler"]
    UNIT_026["UNIT-026: Inter-Core Queue"]
    UNIT_027["UNIT-027: Demo State Machine"]
    UNIT_030["UNIT-030: PNG Decoder"]
    UNIT_031["UNIT-031: OBJ Parser"]
    UNIT_032["UNIT-032: Mesh Patch Splitter"]
    UNIT_033["UNIT-033: Codegen Engine"]
    UNIT_034["UNIT-034: Build.rs Orchestrator"]
    UNIT_035["UNIT-035: PC SPI Driver (FT232H)"]
    UNIT_036["UNIT-036: PC Input Handler"]
    UNIT_009 -->|INT-002| UNIT_009
    UNIT_003 -->|INT-010| UNIT_001
    UNIT_003 -->|INT-010| UNIT_004
    UNIT_003 -->|INT-010| UNIT_005
    UNIT_003 -->|INT-010| UNIT_006
    UNIT_003 -->|INT-010| UNIT_008
    UNIT_003 -->|INT-010| UNIT_010
    UNIT_003 -->|INT-010| UNIT_022
    UNIT_022 -->|INT-020| UNIT_021
    UNIT_026 -->|INT-021| UNIT_020
    UNIT_026 -->|INT-021| UNIT_021
    UNIT_026 -->|INT-021| UNIT_027
    UNIT_006 -->|INT-032| UNIT_006
    UNIT_036 -->|INT-040| UNIT_022
```

### Software Units

| Unit | Title | Purpose |
|------|-------|---------|
| UNIT-001 | SPI Slave Controller | Receives 72-bit SPI transactions and writes to register file |
| UNIT-002 | Command FIFO | Buffers GPU commands with flow control and provides autonomous boot-time command execution via pre-populated FIFO entries. |
| UNIT-003 | Register File | Stores GPU state and vertex data |
| UNIT-004 | Triangle Setup | Prepares triangle for rasterization |
| UNIT-005 | Rasterizer | Edge-walking rasterization engine |
| UNIT-006 | Pixel Pipeline | Depth range clipping, early Z-test, texture sampling, blending, framebuffer write |
| UNIT-007 | Memory Arbiter | Arbitrates SDRAM access between display and render |
| UNIT-008 | Display Controller | Scanline FIFO and display pipeline |
| UNIT-009 | DVI TMDS Encoder | TMDS encoding and differential output |
| UNIT-010 | Color Combiner | Pipelined programmable color combiner that produces a final fragment color from multiple input sources. |
| UNIT-020 | Core 0 Scene Manager | Scene graph management and animation |
| UNIT-021 | Core 1 Render Executor | Render command queue consumer |
| UNIT-022 | GPU Driver Layer | Platform-agnostic GPU register protocol and flow control, generic over SPI transport |
| UNIT-023 | Transformation Pipeline | MVP matrix transforms |
| UNIT-024 | Lighting Calculator | Gouraud shading calculations |
| UNIT-025 | USB Keyboard Handler | USB HID keyboard input processing |
| UNIT-026 | Inter-Core Queue | SPSC queue for render command dispatch (Core 0→Core 1 on RP2350; single-threaded equivalent on other platforms) |
| UNIT-027 | Demo State Machine | Demo selection and switching logic |
| UNIT-030 | PNG Decoder | PNG file loading, RGBA conversion, and texture format encoding (RGBA4444/BC1) |
| UNIT-031 | OBJ Parser | OBJ file parsing and geometry extraction |
| UNIT-032 | Mesh Patch Splitter | Mesh splitting with vertex/index limits |
| UNIT-033 | Codegen Engine | Rust source and binary data generation for compiled assets |
| UNIT-034 | Build.rs Orchestrator | Asset pipeline entry point |
| UNIT-035 | PC SPI Driver (FT232H) | SPI transport implementation for PC platform via Adafruit FT232H breakout board |
| UNIT-036 | PC Input Handler | Terminal keyboard input handling for the PC debug host platform. |
<!-- syskit-arch-end -->
