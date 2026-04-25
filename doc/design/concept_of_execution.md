# Concept of Execution

This document describes the runtime behavior of the GPU: how it starts up, how data flows through it, and how it responds to events.

## System Overview

The pico-gs GPU is a fixed-function 3D rendering pipeline implemented on a Lattice ECP5-25K FPGA (ICEpi Zero v1.3 board).
It receives rendering commands from an external SPI host over a 72-bit register-write protocol (INT-010, INT-012).
The GPU handles rasterization, texturing, depth testing, color combining, dithering, and scanout.
It drives a 640×480 DVI output from a double-buffered framebuffer stored in 32 MB of external SDRAM (Winbond W9825G6KH on the ICEpi Zero board).

The SPI host is an external system.
In production, this is a Raspberry Pi Pico 2 (RP2350) running the pico-racer application (https://github.com/londey/pico-racer).
For development and testing, the Verilator interactive simulator drives the GPU model directly via the SIM_DIRECT_CMD injection port, bypassing SPI serial framing.

Each SPI transaction is a 9-byte frame (1-byte address + 8-byte data) that writes to the GPU register file.
The register file accumulates vertex data and triggers rasterization on every third VERTEX write.

## Operational Modes

Reference: `doc/requirements/states_and_modes.md`

The GPU operates in three phases at runtime.
**FPGA Boot Screen** begins immediately after PLL lock: the command FIFO starts non-empty with ~18 pre-populated register writes baked into the bitstream (see DD-019), which the register file drains autonomously at the core clock rate (~0.18 us at 100 MHz).
This draws a black screen-clear followed by a Gouraud-shaded RGB triangle and presents the result, producing a visible self-test boot screen before any SPI traffic arrives.
**Host Initialization** covers the external host's GPU ID verification via SPI and framebuffer address configuration; by the time the host sends its first SPI transaction (~100 ms after power-on), the FPGA boot screen is already displayed.
**Active Rendering** is the steady-state loop where the external host submits register-write commands at up to 62.5 MHz SPI, synchronized to 60 Hz vsync.

## Startup Sequence

### FPGA Boot Screen (autonomous, no host involvement)

The FPGA executes a self-test boot screen immediately after PLL lock, before any SPI traffic:

1. **PLL lock and reset release**: The ECP5 PLL locks (50-500 ms after power-on) and reset synchronizers deassert across all clock domains.
2. **Boot command drain**: The command FIFO (UNIT-002) starts non-empty with ~18 pre-populated register writes embedded in the bitstream memory initialization (see DD-019).
   The register file (UNIT-003) begins consuming these commands at the system clock rate, one entry per cycle.
3. **Boot sequence content**: The pre-populated commands set FB_DRAW to Framebuffer A, draw two black screen-covering triangles (flat shading, screen clear), then set RENDER_MODE to Gouraud shading, draw a centered RGB triangle with red/green/blue vertex colors, and finally write FB_DISPLAY to present Framebuffer A.
4. **Completion**: All ~18 boot commands are consumed in ~0.18 us at 100 MHz (18 commands × 10 ns per cycle).
   CMD_EMPTY asserts, the boot screen is visible on the display output, and the GPU is ready for host SPI traffic.

## Data Flow

The GPU is organized into three top-level pipelines, as defined in ARCHITECTURE.md:

```
   External SPI Host                              ECP5 FPGA GPU
                                    ┌──────────────────────────────────────────┐
                                    │  ── Command Pipeline ──────────────────  │
                                    │                                          │
                                    │  SPI Slave ──► Command FIFO (32×72b)    │
                                    │                    │                     │
                                    │                    ▼                     │
  register writes     SPI 25 MHz   │  Register File (vertex accumulator)     │
 ──────────────────────────────────►│  ─────────────────┬──────────────────── │
   9-byte frames                    │  ── Render Pipeline│ ─────────────────  │
                                    │                    │ (3rd VERTEX write)  │
                                    │  [Triangle Setup]  ▼                    │
                                    │  Rasterizer (edge coeffs, bbox, deriv)  │
                                    │                    │ (tile kick)         │
                                    │  [Block Pipeline]  ▼                    │
                                    │  Hi-Z Test → Z Tile Load                │
                                    │           → Color Tile Load             │
                                    │           → Edge Test + Interpolation   │
                                    │                    │ (fragment stream)   │
                                    │  [Pixel Pipeline]  ▼                    │
                                    │  Early-Z / Stipple / Tex / CC / Blend   │
                                    │                    │      Mem Arbiter   │
                                    │                    ▼─────► (4 ports) ──►SDRAM│
                                    │  (FB/Z Write)               │     32 MB │
                                    │  ─────────────────────────────────────  │
                                    │  ── Display Pipeline ──────────────────  │
                                    │  Display Ctrl ◄─────────────────────────│
                                    │       │                                  │
                                    │       ▼                                  │
                                    │  Scanline FIFO ──► DVI Output           │
                                    │                     640×480 @ 60 Hz     │
                                    └──────────────────────────────────────────┘
```

**Command Pipeline**: The SPI slave deserializes 72 bits into a command FIFO (depth 32, custom soft FIFO backed by a regular memory array).
At power-on, the FIFO contains ~18 pre-populated boot commands from the bitstream that execute a self-test boot screen autonomously (see DD-019); during normal operation, only SPI-sourced commands flow through the FIFO.
The register file consumes FIFO entries, latching color/UV/position state.
Every third VERTEX write emits a `tri_valid` pulse that kicks off the Render Pipeline.

**Render Pipeline — Triangle Setup** (UNIT-005.01): The rasterizer computes edge-function coefficients, performs back-face culling, clamps the screen-space bounding box, precomputes attribute derivatives (dAttr/dx, dAttr/dy), and walks the bounding box in 4×4 tile order.

**Render Pipeline — Block Pipeline** (UNIT-005): For each 4×4 tile, the rasterizer performs a Hi-Z test against the block metadata.
Tiles that pass the Hi-Z test trigger a Z Tile Load and a Color Tile Load, pre-fetching the tile's depth and color entries into the tile buffers.
The rasterizer then runs per-pixel edge tests and interpolates Z, Q (1/W), vertex colors, and UV projections, applying perspective correction (1/Q via reciprocal LUT; true U, V reconstructed via DSP multipliers).

**Render Pipeline — Pixel Pipeline** (UNIT-006): The rasterizer emits per-fragment data (x, y, z, color0, color1, uv0, uv1, lod) via a valid/ready handshake to the pixel pipeline; `uv0` and `uv1` carry true perspective-correct U, V coordinates ready for texel addressing.
The pixel pipeline performs early Z testing, then dispatches UV coordinates to the texture sampler (UNIT-011) for index cache lookup and palette LUT lookup; UNIT-011 returns decoded Q4.12 RGBA texel data for each active sampler.
The pixel pipeline then drives the color combiner (UNIT-010) with the Q4.12 texel results, performs alpha blending, dithering, and writes passing pixels and updated depth values to the framebuffer and Z-buffer in SDRAM via the memory arbiter.

**Display Pipeline**: The display controller independently prefetches scanlines from the display framebuffer into a FIFO and outputs them through the DVI encoder at the 25 MHz pixel clock (synchronous 4:1 from the 100 MHz core clock).

## Event Handling

### Event: VSYNC (Frame Boundary)

- **Source:** GPU display controller asserts `gpio_vsync` at 60 Hz
- **Handler:** External host reads the VSYNC GPIO (gpio[25], per the ICEpi Zero LPF)
- **Response:** Host swaps the FB_DRAW and FB_DISPLAY register addresses via SPI, presenting the completed frame and directing the next frame to the back buffer.

### Event: CMD_FULL (GPU Backpressure)

- **Source:** FPGA command FIFO almost-full signal on `gpio_cmd_full`
- **Handler:** External host polls the CMD_FULL GPIO before each SPI write
- **Response:** Host pauses SPI transaction submission until CMD_FULL deasserts, preventing command FIFO overflow.

### Event: CMD_EMPTY (FIFO Drained)

- **Source:** FPGA command FIFO empty signal on `gpio_cmd_empty`
- **Handler:** External host polls CMD_EMPTY before issuing register reads
- **Response:** Register reads bypass the FIFO and require an idle register file; CMD_EMPTY confirms it is safe to read.

## Timing and Synchronization

**Frame rate**: The display controller generates a 640×480 @ 60 Hz VGA timing signal (25 MHz pixel clock, derived as a synchronous 4:1 divisor from the 100 MHz core clock).
VSYNC pulses define frame boundaries.

**Double-buffered framebuffer**: The GPU maintains separate draw and display framebuffer addresses in the FB_DRAW and FB_DISPLAY registers.
The display controller reads from FB_DISPLAY continuously, while the rasterizer writes to FB_DRAW.
The external host swaps these addresses via SPI at VSYNC, ensuring tear-free output.

**SPI bus timing**: The SPI bus runs at up to 62.5 MHz, MODE_0.
Each register write is a 9-byte (72-bit) transaction.
A triangle submission requires 6–9 register writes (COLOR + optional UV + VERTEX for each of 3 vertices).

## Resource Management

**GPU SDRAM layout** (32 MB external SDRAM, W9825G6KH, on the FPGA):

The layout below reflects the default 512×512 surface configuration (FB_CONFIG.WIDTH_LOG2=9, HEIGHT_LOG2=9).
See INT-011 for the canonical block-tiled address formula and alternative surface sizes.

| Region | Address | Size |
|--------|---------|------|
| Framebuffer A | `0x000000` | 524,288 bytes (512×512×2, RGB565) |
| Framebuffer B | `0x080000` | 524,288 bytes (512×512×2, RGB565) |
| Z-Buffer | `0x100000` | 524,288 bytes (512×512×2, Z16) |
| Texture Memory | `0x180000` | Remaining space |

**FPGA resources**: The command FIFO is 32 entries deep (72 bits each), implemented as a custom soft FIFO backed by a regular memory array (not a Lattice EBR FIFO macro) so that the bitstream can pre-populate the memory with boot commands (see DD-019).
The memory arbiter (UNIT-007) has 4 ports with fixed priority: display read (port 0, highest), framebuffer write (port 1, owned by pixel pipeline), Z-buffer read/write (port 2, owned by pixel pipeline), texture index cache fills / palette slot loads / timestamp writes (port 3, lowest — shared via the 3-way arbiter internal to texture_sampler.sv plus time-division with PERF_TIMESTAMP SDRAM writes; see UNIT-007 for the sharing policy).
The display controller's scanline FIFO holds ~1024 words (~1.6 scanlines) to absorb SDRAM access latency (including CAS latency and row activation overhead).

**SDRAM sequential access**: The external SDRAM (W9825G6KH) supports efficient sequential column reads and writes within an active row.
After the initial row activation (ACTIVATE + tRCD = 3 cycles) and CAS latency (CL=3 for reads), consecutive column accesses stream at 1 word per cycle.
The memory arbiter (UNIT-007) exploits this for sequential access patterns: display scanout (port 0) reads consecutive scanline pixels, framebuffer writes (port 1) write consecutive rasterized pixels, Z-buffer accesses (port 2) read/write consecutive depth values for scanline-order fragments, and texture cache fills (port 3) read consecutive block data on cache miss.
The SDRAM controller also manages auto-refresh (8192 refreshes per 64 ms) autonomously, temporarily blocking new arbiter grants during refresh cycles.
See INT-011 for the SDRAM bandwidth budget, and UNIT-007 for arbiter grant policy.
