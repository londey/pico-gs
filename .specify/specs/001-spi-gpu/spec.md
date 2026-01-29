# Feature Specification: ICEpi SPI GPU

**Branch**: 001-spi-gpu  
**Date**: January 2026  
**Status**: Draft

---

## Overview

### Problem Statement

Building 3D graphics applications on microcontrollers is constrained by limited CPU cycles for both geometry processing and pixel rendering. While the RP2350's dual M33 cores with hardware float can handle vertex transforms, the fill-rate demands of rasterization quickly become a bottleneck for anything beyond trivial scenes.

### Solution

A dedicated GPU implemented on the ICEpi Zero's ECP5 FPGA that offloads triangle rasterization, texture mapping, and framebuffer management from the host MCU. The host submits screen-space triangles over SPI; the GPU handles pixel-level operations and display output.

### Inspiration

The architecture draws from the PlayStation 2 Graphics Synthesizer (GS):
- Host performs transforms and submits primitives (like EE/VU → GS)
- GPU handles rasterization with perspective-correct texturing
- Register-based command interface with implicit state accumulation
- High memory bandwidth dedicated to fill rate

### Success Criteria

1. Render a lit, rotating Utah teapot at ≥30 FPS
2. Render a textured, rotating cube at ≥30 FPS
3. Stable 640×480 @ 60Hz DVI output with no tearing
4. Host CPU utilization ≤50% during rendering (leaving cycles for game logic)

---

## User Stories

### US-1: Basic Host Communication

**As a** firmware developer  
**I want to** write to GPU registers over SPI  
**So that** I can configure the GPU and submit primitives

**Acceptance Criteria:**
- [ ] SPI slave accepts 72-bit transactions (1 R/W + 7 addr + 64 data)
- [ ] Register writes complete within predictable cycle count
- [ ] CMD_FULL GPIO asserts when command buffer is near capacity
- [ ] CMD_EMPTY GPIO asserts when safe to read status registers
- [ ] VSYNC GPIO pulses at frame boundaries

---

### US-2: Framebuffer Management

**As a** firmware developer  
**I want to** configure draw target and display source addresses  
**So that** I can implement double-buffering without tearing

**Acceptance Criteria:**
- [ ] FB_DRAW register sets where triangles render
- [ ] FB_DISPLAY register sets which buffer is scanned out
- [ ] Buffer swap (changing FB_DISPLAY) takes effect at next VSYNC
- [ ] CLEAR command fills FB_DRAW with CLEAR_COLOR at full bandwidth
- [ ] 4K-aligned addresses allow multiple buffers in 32MB SRAM

---

### US-3: Flat-Shaded Triangle

**As a** firmware developer  
**I want to** submit a triangle with a single color  
**So that** I can render simple geometry without texture overhead

**Acceptance Criteria:**
- [ ] Set TRI_MODE to flat shading (GOURAUD=0, TEXTURED=0)
- [ ] Set COLOR register once (used for all three vertices)
- [ ] Write three VERTEX registers; third write triggers rasterization
- [ ] Triangle renders correctly for all orientations (CW/CCW)
- [ ] Subpixel precision prevents "dancing" vertices during animation

---

### US-4: Gouraud-Shaded Triangle

**As a** firmware developer  
**I want to** submit a triangle with per-vertex colors  
**So that** I can render smooth lighting gradients

**Acceptance Criteria:**
- [ ] Set TRI_MODE with GOURAUD=1
- [ ] Set COLOR register before each VERTEX write
- [ ] Colors interpolate linearly across triangle in screen space
- [ ] No banding artifacts visible in 8-bit per channel output

---

### US-5: Depth-Tested Triangle

**As a** firmware developer  
**I want to** enable Z-buffer testing  
**So that** overlapping triangles render in correct depth order

**Acceptance Criteria:**
- [ ] Set TRI_MODE with Z_TEST=1, Z_WRITE=1
- [ ] Z-buffer stored in SRAM (separate from color buffer)
- [ ] Depth comparison is less-than-or-equal (closer pixels win)
- [ ] Z values interpolate correctly across triangle
- [ ] Z-buffer can be cleared independently of color buffer

---

### US-6: Textured Triangle

**As a** firmware developer  
**I want to** submit a triangle with texture coordinates  
**So that** I can render textured surfaces

**Acceptance Criteria:**
- [ ] Set TRI_MODE with TEXTURED=1
- [ ] Set TEX_BASE to texture address in SRAM
- [ ] Set TEX_FMT with texture dimensions (power-of-two, log2 encoded)
- [ ] Set UV register (U/W, V/W, 1/W) before each VERTEX write
- [ ] Texture sampling is perspective-correct (no affine warping)
- [ ] Texture coordinates wrap or clamp (configurable)
- [ ] Final pixel = texture color × vertex color

---

### US-7: Display Output

**As a** user  
**I want** the GPU to output video to a standard monitor  
**So that** I can see the rendered graphics

**Acceptance Criteria:**
- [ ] 640×480 @ 60Hz resolution via DVI/HDMI
- [ ] TMDS encoding using ECP5 SERDES blocks
- [ ] Stable sync signals (no rolling, tearing, or flicker)
- [ ] Display refresh never stalls regardless of draw load

---

## Functional Requirements

### FR-1: SPI Interface

| Requirement | Description |
|-------------|-------------|
| FR-1.1 | SPI Mode 0 (CPOL=0, CPHA=0), active-low CS |
| FR-1.2 | Maximum SPI clock: 40 MHz |
| FR-1.3 | Transaction format: 72 bits (MSB first) |
| FR-1.4 | Bit 71: R/W̄ (1=read, 0=write) |
| FR-1.5 | Bits 70:64: Register address (7 bits, 128 registers) |
| FR-1.6 | Bits 63:0: Register value (64 bits) |
| FR-1.7 | Write transactions queue to command FIFO |
| FR-1.8 | Read transactions return register value on MISO |

### FR-2: Command Buffer

| Requirement | Description |
|-------------|-------------|
| FR-2.1 | FIFO depth: 8-16 commands minimum |
| FR-2.2 | CMD_FULL asserts when ≤2 slots remain |
| FR-2.3 | CMD_EMPTY asserts when FIFO is empty |
| FR-2.4 | Commands execute in FIFO order |
| FR-2.5 | Host may poll STATUS register for FIFO depth |

### FR-3: Vertex Submission

| Requirement | Description |
|-------------|-------------|
| FR-3.1 | GPU maintains internal vertex counter (0, 1, 2) |
| FR-3.2 | Writing COLOR latches color for next vertex |
| FR-3.3 | Writing UV latches texture coordinates for next vertex |
| FR-3.4 | Writing VERTEX latches position and increments counter |
| FR-3.5 | When counter reaches 3, triangle is queued for rasterization |
| FR-3.6 | Counter resets to 0 after triangle submission |
| FR-3.7 | TRI_MODE affects all subsequent triangles until changed |

### FR-4: Rasterization

| Requirement | Description |
|-------------|-------------|
| FR-4.1 | Edge-walking algorithm (not tile-based) |
| FR-4.2 | Top-left fill convention for consistent edges |
| FR-4.3 | Subpixel precision: 4 fractional bits minimum |
| FR-4.4 | Pixels outside 0 ≤ x < 640, 0 ≤ y < 480 are clipped |
| FR-4.5 | Degenerate triangles (zero area) produce no pixels |

### FR-5: Texture Sampling

| Requirement | Description |
|-------------|-------------|
| FR-5.1 | Texture dimensions: power-of-two, 8×8 to 256×256 |
| FR-5.2 | Texture format: RGBA8888 (32 bits per texel) |
| FR-5.3 | Addressing: U/W and V/W interpolated, divided by 1/W per pixel |
| FR-5.4 | Wrap mode: repeat (bitwise AND with dimension-1) |
| FR-5.5 | Filter mode: nearest neighbor (no bilinear) |
| FR-5.6 | Texture base address: 4K aligned |

### FR-6: Framebuffer

| Requirement | Description |
|-------------|-------------|
| FR-6.1 | Resolution: 640×480 |
| FR-6.2 | Color format: RGBA8888 (32 bits per pixel) |
| FR-6.3 | Size: 1,228,800 bytes per buffer |
| FR-6.4 | Z-buffer: 24 bits per pixel, same resolution |
| FR-6.5 | Z-buffer size: 921,600 bytes |
| FR-6.6 | Clear operation: fills at memory bandwidth (~3ms for color) |

### FR-7: Display Output

| Requirement | Description |
|-------------|-------------|
| FR-7.1 | Resolution: 640×480 @ 60Hz (pixel clock 25.175 MHz) |
| FR-7.2 | Interface: DVI (HDMI-compatible, no audio) |
| FR-7.3 | Encoding: TMDS via ECP5 SERDES |
| FR-7.4 | Timing: CEA-861 standard for 640×480p60 |
| FR-7.5 | Read-ahead FIFO: ≥1 scanline to mask SRAM latency |

---

## Non-Functional Requirements

### NFR-1: Performance

| Requirement | Target |
|-------------|--------|
| NFR-1.1 | Triangle throughput | ≥20,000 triangles/sec |
| NFR-1.2 | Fill rate | ≥25 Mpixels/sec |
| NFR-1.3 | Clear rate | Full screen in <5ms |
| NFR-1.4 | Register write latency | <100 cycles from CS↑ |

### NFR-2: Resource Utilization

| Requirement | Target |
|-------------|--------|
| NFR-2.1 | LUT usage | ≤20,000 |
| NFR-2.2 | BRAM usage | ≤100 kbytes |
| NFR-2.3 | DSP usage | ≤24 blocks |
| NFR-2.4 | SRAM bandwidth | ≤200 MB/s total |

### NFR-3: Reliability

| Requirement | Description |
|-------------|-------------|
| NFR-3.1 | No display corruption under sustained draw load |
| NFR-3.2 | FIFO overflow handled gracefully (stall, not corrupt) |
| NFR-3.3 | Deterministic behavior for same input sequence |

---

## Out of Scope

The following features are explicitly **not** included in this specification:

- Programmable shaders or compute capabilities
- Multiple texture units or multitexturing
- Stencil buffer operations
- Anti-aliasing (MSAA, FXAA, etc.)
- Alpha blending or transparency
- Line or point primitives (triangles only)
- Scissor rectangle / clipping planes
- Hardware cursors or sprites
- Audio output

These may be considered for future revisions after core functionality is validated.

---

## Open Questions

> Items requiring clarification before implementation

- [ ] **Q1**: Should texture coordinates clamp or wrap at boundaries? (Currently specified as wrap)
- [ ] **Q2**: Is 24-bit Z precision sufficient, or should we support 16-bit for bandwidth savings?
- [ ] **Q3**: Should CLEAR command clear both color and Z, or have separate commands?
- [ ] **Q4**: What pixel format for textures—RGBA8888 only, or also RGB565?
- [ ] **Q5**: Should we support a "kick" register for explicit draw trigger, vs implicit on third vertex?

---

## Review Checklist

- [ ] All user stories have measurable acceptance criteria
- [ ] Functional requirements are complete and unambiguous
- [ ] Non-functional requirements have quantified targets
- [ ] Out-of-scope items are explicitly listed
- [ ] Open questions are captured for clarification
- [ ] Constitution principles are not violated
