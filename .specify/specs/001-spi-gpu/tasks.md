# Implementation Tasks: ICEpi SPI GPU

**Branch**: 001-spi-gpu  
**Date**: January 2026  
**Plan**: [plan.md](./plan.md)

---

## Task Legend

- `[P]` = Can be parallelized with previous task
- `[ ]` = Not started
- `[~]` = In progress  
- `[x]` = Complete

---

## Phase 1: Infrastructure

### 1.1 Project Setup

- [ ] **T1.1.1** Create project directory structure
  ```
  rtl/
  tb/
  constraints/
  firmware/
  docs/
  ```

- [ ] **T1.1.2** Create Makefile for synthesis flow
  - Yosys synthesis target
  - nextpnr place-and-route target
  - openFPGALoader programming target
  - Verilator simulation target

- [ ] **T1.1.3** Create constraints file for ICEpi Zero
  - Pin assignments (SPI, GPIO, SRAM, DVI)
  - Clock constraints (50 MHz input)
  - IO standards (LVCMOS33)

### 1.2 Clock Generation

- [ ] **T1.2.1** Write `pll_core` module
  - Input: 50 MHz
  - Outputs: 100 MHz (SRAM), 25.175 MHz (pixel), 251.75 MHz (TMDS)
  - Use ECP5 PLL primitive

- [ ] **T1.2.2** Write cocotb test for PLL lock detection
  - Verify lock signal asserts
  - Verify output frequencies (simulation model)

### 1.3 Reset Generation

- [ ] **T1.3.1** Write `reset_sync` module
  - Synchronize external reset to each clock domain
  - Hold reset until PLL locked
  - Generate reset pulse on PLL unlock

- [ ] **T1.3.2** Write cocotb test for reset sequencing

---

## Phase 2: SPI Interface

### 2.1 SPI Slave

- [ ] **T2.1.1** Write `spi_slave` module
  - 72-bit shift register
  - Sample MOSI on SCK rising edge
  - Drive MISO for read transactions
  - Transaction complete on CS rising edge

- [ ] **T2.1.2** Write cocotb test for SPI transactions
  - Write transaction decode
  - Read transaction response
  - Back-to-back transactions
  - Varying SPI clock speeds

### 2.2 Command FIFO

- [ ] **T2.2.1** Write `async_fifo` module
  - Parameterized depth and width
  - Gray-code pointer CDC
  - Full, empty, almost_full flags

- [ ] **T2.2.2** [P] Write cocotb test for FIFO
  - Fill to capacity
  - Drain completely
  - Concurrent read/write
  - CDC verification

### 2.3 Register File

- [ ] **T2.3.1** Write `register_file` module
  - Decode address, dispatch to registers
  - Implement read-only registers (STATUS, ID)
  - Implement read-write registers
  - Generate vertex push logic

- [ ] **T2.3.2** Write cocotb test for register access
  - Write and readback all R/W registers
  - Verify read-only behavior
  - Verify vertex state machine

### 2.4 GPIO Outputs

- [ ] **T2.4.1** Add GPIO logic to top level
  - CMD_FULL from FIFO almost_full
  - CMD_EMPTY from FIFO empty AND not busy
  - VSYNC from display controller

- [ ] **T2.4.2** Write cocotb test for GPIO timing

---

## Phase 3: Memory Subsystem

### 3.1 SRAM Controller

- [ ] **T3.1.1** Write `sram_controller` module
  - 16-bit async SRAM interface
  - Read cycle state machine
  - Write cycle state machine
  - 32-bit word assembly/split

- [ ] **T3.1.2** Write cocotb test with SRAM model
  - Single read/write
  - Sequential burst
  - Random access pattern

### 3.2 Memory Arbiter

- [ ] **T3.2.1** Write `sram_arbiter` module
  - 4-port arbiter (display, texture, FB write, Z)
  - Fixed priority scheme
  - Request/grant interface

- [ ] **T3.2.2** [P] Write cocotb test for arbitration
  - Priority verification
  - Starvation prevention
  - Concurrent requests

### 3.3 Integration

- [ ] **T3.3.1** Integrate SRAM controller with arbiter
  - Connect request ports
  - Route addresses and data
  - Handle grant signals

- [ ] **T3.3.2** Write cocotb test for integrated memory path
  - Multiple requestors active
  - Verify no data corruption

---

## Phase 4: Display Pipeline

### 4.1 Timing Generator

- [ ] **T4.1.1** Write `timing_generator` module
  - 640×480 @ 60Hz timing
  - H/V sync generation
  - Blanking signals
  - Pixel coordinate output

- [ ] **T4.1.2** Write cocotb test for timing
  - Verify sync pulse widths
  - Verify blanking periods
  - Verify frame rate

### 4.2 Scanline FIFO

- [ ] **T4.2.1** Write `scanline_fifo` module
  - Dual-clock FIFO (100 MHz write, 25 MHz read)
  - 2 scanline depth (~5KB)
  - Underrun detection

- [ ] **T4.2.2** [P] Write cocotb test for scanline FIFO
  - Fill/drain at different rates
  - Verify no underrun under load

### 4.3 Display Controller

- [ ] **T4.3.1** Write `display_controller` module
  - Prefetch logic (stay ahead of scanout)
  - SRAM read requests
  - Feed scanline FIFO
  - Coordinate with timing generator

- [ ] **T4.3.2** Write cocotb test for display controller
  - Verify continuous scanout
  - Verify FB_DISPLAY switching

### 4.4 DVI Encoder

- [ ] **T4.4.1** Write `tmds_encoder` module
  - 8b/10b TMDS encoding
  - DC balance tracking
  - Control symbol insertion

- [ ] **T4.4.2** [P] Write `dvi_output` module
  - TMDS channel serialization
  - ECP5 SERDES instantiation
  - Clock channel generation

- [ ] **T4.4.3** Write cocotb test for TMDS encoding
  - Verify encoding correctness
  - Verify DC balance

### 4.5 Display Integration

- [ ] **T4.5.1** Integrate display pipeline
  - Connect timing → controller → FIFO → encoder
  - Wire to SRAM arbiter

- [ ] **T4.5.2** Hardware test: static test pattern
  - Synthesize with hardcoded pattern
  - Verify on monitor

---

## Phase 5: Basic Rendering

### 5.1 Clear Engine

- [ ] **T5.1.1** Write `clear_engine` module
  - Sequential SRAM write for framebuffer
  - Use CLEAR_COLOR value
  - Generate busy signal

- [ ] **T5.1.2** Write cocotb test for clear
  - Verify full buffer cleared
  - Verify correct color written
  - Measure cycle count

### 5.2 Pixel Write

- [ ] **T5.2.1** Add pixel write path to register file
  - Direct SRAM write from register
  - For testing/debugging

- [ ] **T5.2.2** Hardware test: single pixel
  - Write pixel via SPI
  - Verify on display

### 5.3 First Integration

- [ ] **T5.3.1** Integrate SPI + registers + clear + display
  - Full path from host to screen

- [ ] **T5.3.2** Hardware test: clear and swap
  - Clear to different colors
  - Double buffer swap
  - Verify no tearing

---

## Phase 6: Triangle Rasterization

### 6.1 Triangle Setup

- [ ] **T6.1.1** Write `edge_function` module
  - Compute edge equation coefficients
  - Handle all vertex orderings

- [ ] **T6.1.2** [P] Write `gradient_calc` module
  - Compute dA/dx, dA/dy for attributes
  - Use DSP blocks for multiplication

- [ ] **T6.1.3** Write `triangle_setup` module
  - Instantiate edge and gradient modules
  - Compute bounding box
  - Pipeline control

- [ ] **T6.1.4** Write cocotb test for triangle setup
  - Various triangle shapes
  - Degenerate cases (zero area)
  - Verify coefficients against reference

### 6.2 Rasterizer Core

- [ ] **T6.2.1** Write `rasterizer` module
  - Scanline iteration
  - Edge function evaluation
  - Pixel emission
  - Bounding box clipping

- [ ] **T6.2.2** Write cocotb test for rasterizer
  - Small triangles
  - Screen-filling triangles
  - Triangles crossing screen edge
  - Compare output to reference

### 6.3 Flat Shading

- [ ] **T6.3.1** Write `pixel_output` module (minimal)
  - Accept pixel coordinate and flat color
  - Generate SRAM write request

- [ ] **T6.3.2** Integrate rasterizer with pixel output

- [ ] **T6.3.3** Hardware test: flat triangle
  - Single triangle rendering
  - Multiple triangles
  - Edge accuracy verification

---

## Phase 7: Advanced Shading

### 7.1 Attribute Interpolation

- [ ] **T7.1.1** Write `interpolator` module
  - Incremental attribute update
  - Support RGBA channels
  - Fixed-point arithmetic

- [ ] **T7.1.2** Write cocotb test for interpolation
  - Linear ramp verification
  - Precision verification

### 7.2 Gouraud Shading

- [ ] **T7.2.1** Integrate interpolator with pixel output
  - Route vertex colors through setup
  - Interpolate R, G, B, A per pixel

- [ ] **T7.2.2** Hardware test: Gouraud triangle
  - RGB vertex colors
  - Verify smooth gradient

### 7.3 Z-Buffer

- [ ] **T7.3.1** Write `z_buffer` module
  - Z interpolation
  - Z read from SRAM
  - Z compare
  - Conditional write

- [ ] **T7.3.2** Add Z-buffer clear to clear engine

- [ ] **T7.3.3** Write cocotb test for Z-buffer
  - Overlapping triangles
  - Various depth orderings

- [ ] **T7.3.4** Hardware test: depth sorting
  - Two overlapping triangles
  - Verify correct occlusion

---

## Phase 8: Texturing

### 8.1 UV Interpolation

- [ ] **T8.1.1** Extend interpolator for UV coordinates
  - Interpolate U/W, V/W, 1/W

- [ ] **T8.1.2** Write cocotb test for UV interpolation

### 8.2 Perspective Division

- [ ] **T8.2.1** Write `reciprocal` module
  - LUT for initial estimate
  - Newton-Raphson refinement
  - Pipeline for throughput

- [ ] **T8.2.2** Write cocotb test for reciprocal
  - Accuracy across input range
  - Timing verification

- [ ] **T8.2.3** Integrate reciprocal into pixel pipeline
  - U = (U/W) / (1/W)
  - V = (V/W) / (1/W)

### 8.3 Texture Fetch

- [ ] **T8.3.1** Write `texture_unit` module
  - Address calculation from UV
  - SRAM read request
  - Texel return

- [ ] **T8.3.2** Write cocotb test for texture fetch
  - Various texture sizes
  - Wrap addressing

### 8.4 Texture Blending

- [ ] **T8.4.1** Write `color_blend` module
  - Texel × vertex color
  - Per-channel multiply

- [ ] **T8.4.2** Integrate full pixel pipeline
  - UV interp → recip → fetch → blend → Z test → write

- [ ] **T8.4.3** Hardware test: textured triangle
  - Checkerboard texture
  - Verify perspective correctness

---

## Phase 9: Integration & Optimization

### 9.1 Full Pipeline Integration

- [ ] **T9.1.1** Integrate all modules into `gpu_top`
  - All clock domains
  - All data paths
  - All control signals

- [ ] **T9.1.2** Write system-level cocotb test
  - Full triangle submission flow
  - Multiple triangles per frame
  - Double buffering

### 9.2 Resource Optimization

- [ ] **T9.2.1** Analyze synthesis reports
  - LUT usage by module
  - BRAM usage
  - DSP usage
  - Critical paths

- [ ] **T9.2.2** Optimize critical modules
  - Pipeline long paths
  - Share resources where possible
  - Reduce unnecessary logic

### 9.3 Timing Closure

- [ ] **T9.3.1** Run timing analysis
  - Identify failing paths
  - Add pipeline stages if needed

- [ ] **T9.3.2** Iterate until timing met
  - All clock domains passing
  - Adequate setup/hold margins

---

## Phase 10: Validation

### 10.1 Demo Applications

- [ ] **T10.1.1** Write rotating cube demo (host firmware)
  - Matrix math library
  - Cube geometry
  - Main loop with VSYNC

- [ ] **T10.1.2** [P] Write textured cube demo
  - Texture loading
  - UV coordinate setup

- [ ] **T10.1.3** Write teapot demo
  - Load teapot mesh
  - Implement lighting
  - Performance measurement

### 10.2 Stress Testing

- [ ] **T10.2.1** Maximum triangle throughput test
- [ ] **T10.2.2** Fill rate test
- [ ] **T10.2.3** Extended run stability test (hours)

### 10.3 Documentation

- [ ] **T10.3.1** Finalize register map documentation
- [ ] **T10.3.2** Write host driver API documentation
- [ ] **T10.3.3** Write "getting started" guide
- [ ] **T10.3.4** Record demo video

---

## Dependency Graph

```
Phase 1 (Infrastructure)
    │
    ├── Phase 2 (SPI) ──────────────────────────┐
    │                                           │
    └── Phase 3 (Memory) ──┬── Phase 4 (Display)│
                           │         │          │
                           │         ▼          │
                           │    [Monitor Test]  │
                           │                    │
                           └────────────────────┼── Phase 5 (Basic)
                                                │        │
                                                │        ▼
                                                │   [Clear Test]
                                                │        │
                                                ▼        ▼
                                           Phase 6 (Rasterizer)
                                                │
                                                ▼
                                           [Flat Triangle]
                                                │
                                    ┌───────────┴───────────┐
                                    ▼                       ▼
                              Phase 7 (Shading)       Phase 8 (Texture)
                                    │                       │
                                    └───────────┬───────────┘
                                                ▼
                                        Phase 9 (Integration)
                                                │
                                                ▼
                                        Phase 10 (Validation)
                                                │
                                                ▼
                                            [TEAPOT!]
```

---

## Time Estimates

| Phase | Estimated Effort | Dependencies |
|-------|------------------|--------------|
| 1. Infrastructure | 2-3 days | None |
| 2. SPI Interface | 3-4 days | Phase 1 |
| 3. Memory Subsystem | 4-5 days | Phase 1 |
| 4. Display Pipeline | 5-7 days | Phase 3 |
| 5. Basic Rendering | 2-3 days | Phases 2, 3, 4 |
| 6. Triangle Rasterization | 5-7 days | Phase 5 |
| 7. Advanced Shading | 4-5 days | Phase 6 |
| 8. Texturing | 5-7 days | Phase 7 |
| 9. Integration | 3-5 days | Phase 8 |
| 10. Validation | 3-5 days | Phase 9 |

**Total: ~40-55 days** (assuming part-time hobby project pace)

---

## Checkpoint Milestones

| Milestone | Target | Validates |
|-----------|--------|-----------|
| M1: First Light | End of Phase 4 | Display pipeline working |
| M2: First Pixel | End of Phase 5 | Full write path functional |
| M3: First Triangle | End of Phase 6 | Core rasterizer working |
| M4: Shaded Cube | End of Phase 7 | Gouraud + Z-buffer |
| M5: Textured Cube | End of Phase 8 | Full pipeline |
| M6: Teapot | End of Phase 10 | Project complete |
