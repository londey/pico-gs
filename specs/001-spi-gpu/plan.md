# Technical Implementation Plan: ICEpi SPI GPU

**Branch**: 001-spi-gpu  
**Date**: January 2026  
**Spec**: [spec.md](./spec.md)

---

## Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Target FPGA | Lattice ECP5-25K | ICEpi Zero board, 24K LUTs, adequate DSP/BRAM |
| External Memory | 32MB SRAM (16-bit @ 100MHz) | High bandwidth for framebuffer and textures |
| HDL | SystemVerilog | Improved constructs over Verilog, yosys compatible |
| Synthesis | Yosys | Open source, ECP5 support |
| Place & Route | nextpnr-ecp5 | Open source, timing-driven |
| Simulation | Verilator + cocotb | Fast simulation with Python testbenches |
| Programming | openFPGALoader | Open source, ICEpi compatible |
| Host MCU | RP2350 | Hardware float, dual core, SPI master |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                           ICEpi GPU                                  │
│                                                                      │
│  ┌──────────┐    ┌──────────┐    ┌─────────────────────────────┐   │
│  │   SPI    │───▶│ Command  │───▶│      Register File          │   │
│  │  Slave   │    │  FIFO    │    │  (vertex state, config)     │   │
│  └──────────┘    └──────────┘    └──────────────┬──────────────┘   │
│       │                                          │                   │
│       │ GPIO                          ┌──────────▼──────────┐       │
│       │ (FULL,EMPTY,VSYNC)            │  Triangle Setup     │       │
│       ▼                               │  (edge equations)   │       │
│  ┌──────────┐                         └──────────┬──────────┘       │
│  │  Host    │                                    │                   │
│  │ RP2350   │                         ┌──────────▼──────────┐       │
│  └──────────┘                         │  Rasterizer         │       │
│                                       │  (scanline walker)  │       │
│                                       └──────────┬──────────┘       │
│                                                  │                   │
│                                       ┌──────────▼──────────┐       │
│                                       │  Pixel Pipeline     │       │
│                                       │  ┌────────────────┐ │       │
│                                       │  │ UV interpolate │ │       │
│                                       │  │ 1/W divide     │ │       │
│                                       │  │ Texture fetch  │ │       │
│                                       │  │ Color blend    │ │       │
│                                       │  │ Z test/write   │ │       │
│                                       │  └────────────────┘ │       │
│                                       └──────────┬──────────┘       │
│                                                  │                   │
│  ┌───────────────────────────────────────────────▼───────────────┐  │
│  │                      SRAM Arbiter                              │  │
│  │   Priority: Display Read > Texture Read > FB Write > Z R/W    │  │
│  └───────────────────────────────────────────────┬───────────────┘  │
│                                                  │                   │
│  ┌──────────────┐    ┌──────────────┐    ┌──────▼───────┐          │
│  │ Display      │◀───│ Scanline     │◀───│   SRAM       │          │
│  │ Controller   │    │ FIFO (BRAM)  │    │ Controller   │          │
│  └──────┬───────┘    └──────────────┘    └──────┬───────┘          │
│         │                                        │                   │
└─────────┼────────────────────────────────────────┼───────────────────┘
          │                                        │
          ▼                                        ▼
    ┌──────────┐                            ┌──────────┐
    │   DVI    │                            │  32MB    │
    │ Output   │                            │  SRAM    │
    └──────────┘                            └──────────┘
```

---

## Module Breakdown

### Top Level: `gpu_top`

Instantiates all subsystems and connects clocks/resets.

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| clk_50 | in | 1 | Main system clock |
| clk_100 | in | 1 | SRAM clock |
| rst_n | in | 1 | Active-low reset |
| spi_sck | in | 1 | SPI clock |
| spi_mosi | in | 1 | SPI data in |
| spi_miso | out | 1 | SPI data out |
| spi_cs_n | in | 1 | SPI chip select |
| gpio_cmd_full | out | 1 | Command buffer near-full |
| gpio_cmd_empty | out | 1 | Command buffer empty |
| gpio_vsync | out | 1 | Vertical sync pulse |
| sram_* | inout | various | SRAM interface |
| tmds_* | out | various | DVI output |

---

### Module: `spi_slave`

Deserializes 72-bit SPI transactions.

**Inputs**: SPI signals  
**Outputs**: Valid pulse, R/W flag, 7-bit address, 64-bit data

**Implementation Notes**:
- Shift register clocked on SPI_SCK rising edge
- Transaction complete when 72 bits received and CS rises
- Double-register outputs into clk_50 domain

---

### Module: `cmd_fifo`

Buffers register writes for asynchronous processing.

**Parameters**: DEPTH=16 (configurable)

**Ports**:
- Write side: SPI clock domain
- Read side: Main clock domain
- Status: count, full, empty, almost_full

**Implementation Notes**:
- Async FIFO with gray-code pointers for CDC
- Almost_full threshold: DEPTH - 2

---

### Module: `register_file`

Holds GPU state and decodes commands.

**Key Registers**:

| Addr | Name | Bits | Description |
|------|------|------|-------------|
| 0x00 | COLOR | 31:0 | RGBA8888 vertex color |
| 0x01 | UV | 47:0 | {Q[15:0], V[15:0], U[15:0]} 1.15 fixed |
| 0x02 | VERTEX | 56:0 | {Z[24:0], Y[15:0], X[15:0]} 12.4 fixed |
| 0x04 | TRI_MODE | 7:0 | Flags: gouraud, textured, z_test, z_write |
| 0x05 | TEX_BASE | 31:12 | Texture address >> 12 |
| 0x06 | TEX_FMT | 7:0 | {height_log2[3:0], width_log2[3:0]} |
| 0x08 | FB_DRAW | 31:12 | Draw target address >> 12 |
| 0x09 | FB_DISPLAY | 31:12 | Scanout source address >> 12 |
| 0x0A | CLEAR_COLOR | 31:0 | RGBA8888 clear color |
| 0x0B | CLEAR | - | Write triggers clear operation |
| 0x10 | STATUS | 15:0 | {vblank, busy, fifo_depth[7:0]} |
| 0x7F | ID | 31:0 | Read-only: GPU version identifier |

**Vertex State Machine**:
```
State: vertex_count (0, 1, 2)

On VERTEX write:
  latch X, Y, Z from data
  latch COLOR → vertex[vertex_count].color  
  latch UV → vertex[vertex_count].uvq
  vertex_count++
  
  if vertex_count == 3:
    emit triangle_valid pulse
    vertex_count = 0
```

---

### Module: `triangle_setup`

Computes edge equations and attribute gradients.

**Inputs**: Three vertices (x, y, z, color, uvq)  
**Outputs**: Edge coefficients, attribute gradients, bounding box

**Edge Equation** (for edge from V0 to V1):
```
E01(x,y) = (y0 - y1) * x + (x1 - x0) * y + (x0*y1 - x1*y0)
```

Pixel is inside triangle if E01 ≥ 0, E12 ≥ 0, E20 ≥ 0 (assuming CCW winding).

**Gradient Computation**:
For attribute A with values A0, A1, A2 at vertices:
```
dA/dx = (A0*(y1-y2) + A1*(y2-y0) + A2*(y0-y1)) / (2 * area)
dA/dy = (A0*(x2-x1) + A1*(x0-x2) + A2*(x1-x0)) / (2 * area)
```

**Implementation Notes**:
- Use DSP blocks for multiplications
- Pipeline over 4-6 cycles
- Output bounding box: min/max of vertex X/Y, clamped to screen

---

### Module: `rasterizer`

Walks scanlines and generates pixel coordinates.

**Algorithm**: Scanline with active edge list

```
for y = bbox.y_min to bbox.y_max:
  for x = bbox.x_min to bbox.x_max:
    if inside_triangle(x, y):
      emit pixel(x, y)
```

**Optimizations**:
- Skip entire scanlines outside triangle (edge tracking)
- Start X at left edge intersection, end at right edge
- Emit pixels in bursts for SRAM write efficiency

**Implementation Notes**:
- State machine: IDLE → SETUP → SCANLINE → PIXEL → (next scanline or DONE)
- Output: stream of (x, y, valid) tuples

---

### Module: `pixel_pipeline`

Computes final pixel color for each rasterized coordinate.

**Pipeline Stages**:

| Stage | Operation | Cycles |
|-------|-----------|--------|
| 1 | Interpolate Q, UQ, VQ, R, G, B, A, Z | 1 |
| 2 | Compute 1/Q (reciprocal) | 2-4 |
| 3 | U = UQ * (1/Q), V = VQ * (1/Q) | 1 |
| 4 | Texture address calculation | 1 |
| 5 | Texture fetch (SRAM read) | 2-4 |
| 6 | Texel × vertex color | 1 |
| 7 | Z-test, conditional write | 1 |

**Reciprocal Unit**:
- 256-entry LUT for initial estimate (8-bit index → 16-bit result)
- One Newton-Raphson iteration: r' = r * (2 - Q * r)
- 2 DSP multiplies per pixel

**Interpolation**:
```
A(x,y) = A(x0,y0) + dA/dx * (x - x0) + dA/dy * (y - y0)
```

Use incremental update along scanline:
```
A(x+1, y) = A(x, y) + dA/dx
```

---

### Module: `sram_arbiter`

Multiplexes SRAM access between requestors.

**Requestors** (priority order):
1. Display scanout (highest - must not stall)
2. Texture fetch
3. Framebuffer write
4. Z-buffer read/write

**Interface**:
```
input  [N-1:0] req;        // Request signals
input  [N-1:0][23:0] addr; // Addresses from each requestor
input  [N-1:0][31:0] wdata;
input  [N-1:0] we;         // Write enable
output [N-1:0] grant;      // Grant signals
output [31:0] rdata;       // Shared read data
```

**Implementation Notes**:
- Fixed priority arbiter (display always wins)
- Single-cycle arbitration
- Back-pressure lower priority requestors via grant deassertion

---

### Module: `sram_controller`

Interfaces with external 16-bit SRAM.

**Timing** (100 MHz clock, 10ns cycle):
- Read: Address → 1 cycle → Data valid (for 10ns SRAM)
- Write: Address + Data + WE → 1 cycle
- 32-bit access requires two 16-bit cycles

**Burst Support**:
- Sequential addresses can pipeline
- Effective bandwidth: ~180 MB/s for sequential access

---

### Module: `display_controller`

Generates video timing and fetches scanlines.

**Timing Generator** (640×480 @ 60Hz):

| Parameter | Value |
|-----------|-------|
| Pixel clock | 25.175 MHz |
| H visible | 640 |
| H front porch | 16 |
| H sync | 96 |
| H back porch | 48 |
| H total | 800 |
| V visible | 480 |
| V front porch | 10 |
| V sync | 2 |
| V back porch | 33 |
| V total | 525 |

**Scanline FIFO**:
- Dual-port BRAM, 2 scanlines deep (2 × 640 × 4 = 5,120 bytes)
- Read side: pixel clock domain (25 MHz)
- Write side: SRAM clock domain (100 MHz)
- Prefetch: stay 1+ scanlines ahead of display position

---

### Module: `dvi_encoder`

TMDS encoding and serialization.

**TMDS Encoding**:
- 8-bit pixel → 10-bit TMDS symbol
- DC balancing and transition minimization
- Standard algorithm per DVI specification

**Serialization**:
- ECP5 SERDES in 10:1 mode
- Bit clock: 251.75 MHz (10 × pixel clock)
- Use PLL to generate from 50 MHz input

**Outputs**:
- TMDS channels: Red, Green, Blue
- TMDS clock: Directly from PLL

---

## Clock Domains

| Domain | Frequency | Source | Usage |
|--------|-----------|--------|-------|
| clk_50 | 50 MHz | Board oscillator | Main logic, SPI interface |
| clk_100 | 100 MHz | PLL from clk_50 | SRAM controller |
| clk_pixel | 25.175 MHz | PLL from clk_50 | Display timing |
| clk_tmds | 251.75 MHz | PLL from clk_50 | DVI serializer |
| spi_sck | ≤40 MHz | External (host) | SPI slave |

**Clock Domain Crossings**:
- SPI → clk_50: Async FIFO for commands
- clk_100 → clk_pixel: Async FIFO for scanline data
- clk_50 → clk_100: Synchronizer for control signals

---

## Memory Map (32 MB SRAM)

| Start | End | Size | Usage |
|-------|-----|------|-------|
| 0x000000 | 0x12BFFF | 1.2 MB | Framebuffer A (color) |
| 0x12C000 | 0x257FFF | 1.2 MB | Framebuffer B (color) |
| 0x258000 | 0x33FFFF | 0.9 MB | Z-buffer |
| 0x340000 | 0x3FFFFF | 0.75 MB | Texture memory |
| 0x400000 | 0x1FFFFFF | 28 MB | Reserved / future use |

---

## Resource Estimates

| Module | LUTs | BRAM (kbit) | DSP |
|--------|------|-------------|-----|
| spi_slave | 200 | 0 | 0 |
| cmd_fifo | 150 | 4 | 0 |
| register_file | 400 | 0 | 0 |
| triangle_setup | 2,000 | 0 | 8 |
| rasterizer | 1,500 | 0 | 2 |
| pixel_pipeline | 3,000 | 4 (LUT) | 10 |
| sram_arbiter | 300 | 0 | 0 |
| sram_controller | 200 | 0 | 0 |
| display_controller | 500 | 40 (FIFO) | 0 |
| dvi_encoder | 400 | 0 | 0 |
| **Total** | **~8,650** | **~48** | **20** |

Headroom: 57% LUT, 95% BRAM, 29% DSP

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| SRAM timing closure | Medium | High | Conservative timing constraints, SRAM at 80MHz fallback |
| DVI signal integrity | Medium | Medium | Proper termination, short traces |
| Reciprocal precision | Low | Medium | Extra Newton-Raphson iteration if needed |
| Fill rate insufficient | Low | Medium | Reduce resolution to 320×240 if necessary |
| SPI throughput bottleneck | High | Low | Expected; design accepts this as host-limited |

---

## Implementation Order

See [tasks.md](./tasks.md) for detailed breakdown. High-level sequence:

1. **Infrastructure**: Clocks, resets, SPI interface, register file
2. **Memory Path**: SRAM controller, basic read/write verification
3. **Display**: Timing generator, DVI encoder, static test pattern
4. **Framebuffer**: Clear command, single pixel write, display from SRAM
5. **Rasterizer**: Flat triangle, then Gouraud, then Z-buffer
6. **Texturing**: UV interpolation, perspective divide, texture fetch
7. **Integration**: Full pipeline, performance validation

---

## Test Strategy

See [quickstart.md](./quickstart.md) for validation scenarios.

**Unit Tests** (cocotb):
- SPI transaction decode
- FIFO behavior (full, empty, overflow)
- Edge equation computation
- Reciprocal accuracy
- TMDS encoding

**Integration Tests**:
- Register write → pixel appears at expected coordinate
- Triangle rasterization matches reference image
- Z-buffer occlusion correctness
- Texture mapping accuracy

**Hardware Tests**:
- SPI communication with RP2350
- Display output on monitor
- Rotating cube demo
- Teapot rendering
