# UNIT-037: Verilator Interactive Simulator App

## Purpose

Standalone C++/Lua Verilator application for GPU development and debugging without FPGA hardware or an RP2350.
The simulator drives the GPU RTL model by injecting register writes directly into the command FIFO via sim-only injection ports (bypassing SPI serial framing), renders the display controller pixel output to an SDL3 framebuffer window, and executes programmable command sequences via a Lua scripting API.

## Implements Requirements

- REQ-010.02 (Verilator Interactive Simulator)
- REQ-010.02-LUA (Base Lua Register Helper Script)

## Interfaces

### Provides

None (standalone binary, no external interface).

### Consumes

- INT-012 (SPI Transaction Format) -- logical 72-bit transaction encoding (`{rw[0], addr[6:0], data[63:0]}`) used by the C++ injection layer and Lua scripting API to assemble FIFO write commands
- INT-013 (GPIO Status Signals) -- signal names (`CMD_FULL`/`wr_almost_full`, `CMD_EMPTY`/`rd_empty`, `VSYNC`/`disp_vsync_out`) observed by the C++ wrapper and exposed to the Lua scripting layer for backpressure and frame synchronization

### Internal Interfaces

- **UNIT-002 (Command FIFO) `SIM_DIRECT_CMD` injection ports** (via `gpu_top.sv`):
  The C++ wrapper drives the following signals each clock cycle, guarded by `` `ifdef SIM_DIRECT_CMD ``:

  | Signal | Width | Description |
  |--------|-------|-------------|
  | `sim_cmd_valid` | 1 | Sim write enable |
  | `sim_cmd_rw` | 1 | R/W flag (matches bit 71 of INT-012 logical encoding) |
  | `sim_cmd_addr` | 7 | Register address (matches bits 70:64 of INT-012) |
  | `sim_cmd_wdata` | 64 | Write data (matches bits 63:0 of INT-012) |

- **UNIT-008 (Display Controller) pixel tap signals** (on `gpu_top.sv`, after horizontal resize stage):
  The SDL3 display window reads these signals directly, bypassing UNIT-009 entirely:

  | Signal | Width | Description |
  |--------|-------|-------------|
  | `disp_pixel_red` | 8 | Red channel (RGB888) at display controller output |
  | `disp_pixel_green` | 8 | Green channel (RGB888) at display controller output |
  | `disp_pixel_blue` | 8 | Blue channel (RGB888) at display controller output |
  | `disp_enable` | 1 | Data enable -- high during active display region |
  | `disp_vsync_out` | 1 | Vertical sync output -- rising edge marks frame start |

- **UNIT-007 (Memory Arbiter) SDRAM interface**:
  A C++ behavioral SDRAM model substitutes for the physical W9825G6KH SDRAM controller.
  The model connects to the Verilated model's `mem_*` ports, presenting the same handshake interface consumed by UNIT-007.
  See UNIT-007 "SDRAM Behavioral Model for Verilator Simulation" for the complete signal table and timing requirements.

## Design Description

### Injection Path

The C++ wrapper assembles a 72-bit command from Lua-provided register address and data values:
`{sim_cmd_rw, sim_cmd_addr[6:0], sim_cmd_wdata[63:0]}`.
Each clock cycle, if a pending command exists and `wr_almost_full` is deasserted, the wrapper drives `sim_cmd_valid = 1` along with the decomposed command fields on the Verilated model's `SIM_DIRECT_CMD` ports.
When `SIM_DIRECT_CMD` is defined, `gpu_top.sv` multiplexes these signals onto the FIFO write port in place of UNIT-001's output.
In normal synthesis, the `ifdef` block is absent and UNIT-001 drives the FIFO exclusively.

### Backpressure

The injection layer polls `wr_almost_full` (the UNIT-002 FIFO almost-full flag) before each write.
When `wr_almost_full` is asserted, the wrapper holds `sim_cmd_valid` low and stalls command injection until the FIFO drains below the threshold.
This ensures commands are never dropped, matching the flow control behavior described in INT-012.

### SDL3 Display Loop

Each clock tick, the C++ main loop reads `disp_pixel_red`, `disp_pixel_green`, `disp_pixel_blue`, and `disp_enable` from the Verilated model.
When `disp_enable` is high, the current pixel's RGB888 values are written into a 640x480 RGBA8888 pixel buffer.
The pixel position `(x, y)` is tracked by counting `disp_enable` assertions within a frame (`x = count % 640`, `y = count / 640`).
On a rising edge of `disp_vsync_out`, the completed frame is uploaded to an SDL3 streaming texture via `SDL_UpdateTexture` and presented via `SDL_RenderPresent`.
SDL event polling (`SDL_PollEvent`) is performed periodically to handle window close events.

### Lua API

The [sol2](https://github.com/ThePhD/sol2) library binds a Lua interpreter to the C++ simulation loop.
The API exposes two core primitives:

- **`gpu.write_reg(addr, data)`** -- enqueues a pending FIFO write command (`rw=0`, `addr`, `data`) for injection on the next available clock cycle.
  The Lua script blocks until the command has been accepted (i.e., `wr_almost_full` deasserts and the injection occurs).
- **`gpu.wait_vsync()`** -- blocks the Lua script until the next rising edge of `disp_vsync_out`, enabling frame-synchronized rendering sequences.

User scripts load the base register helper library via `require "gpu_regs"` (see REQ-010.02-LUA).
The helper script provides one documented function per GPU register type, each accepting named fields, packing them into the correct 64-bit data word per `registers/rdl/gpu_regs.rdl`, and calling `gpu.write_reg()` with the correct address.

### SDRAM Behavioral Model

A C++ class (`SdramModelSim`) implements the full `mem_*` interface from UNIT-007, substituting for the physical W9825G6KH SDRAM controller.
The model must replicate the following timing behaviors to avoid masking real timing hazards in the display prefetch FSM (UNIT-008) and texture cache (UNIT-006):

- **CAS latency CL=3**: first `mem_burst_data_valid` arrives 3 cycles after the READ command cycle.
- **Row activation (tRCD=2)**: 2 additional cycles before READ/WRITE after ACTIVATE.
- **Auto-refresh**: periodic `mem_ready` deassertion (~1 per 781 cycles).
- **Burst cancel/PRECHARGE**: on `mem_burst_cancel`, complete the current 16-bit word, then assert `mem_ack` after a simulated PRECHARGE delay.

See UNIT-007 "SDRAM Behavioral Model for Verilator Simulation" for the complete signal table and required behaviors.
The model's timing parameters are not reproduced here to avoid duplication; UNIT-007 is the authoritative source.

### UNIT-009 Exclusion

`dvi_output.sv` and `tmds_encoder.sv` (UNIT-009) are not instantiated in the simulation top-level wrapper.
The SDL3 display window reads upstream pixel tap signals (`disp_pixel_red/green/blue`, `disp_enable`, `disp_vsync_out`) directly from `gpu_top.sv`, upstream of where UNIT-009 normally receives its inputs.
This avoids pulling in ECP5-specific TMDS differential output primitives that are not Verilator-compatible.
UNIT-009 RTL remains unchanged; its functionality is covered by its own unit testbench independently of the interactive sim.

## Implementation

- `spi_gpu/sim/gpu_sim.cpp`: Main C++ simulation application (SDL3 window, Verilated model, Lua interpreter, injection loop)
- `spi_gpu/sim/sdram_model_sim.hpp`: SDRAM behavioral model header
- `spi_gpu/sim/sdram_model_sim.cpp`: SDRAM behavioral model implementation
- `spi_gpu/sim/lua/gpu_regs.lua`: Base Lua register helper script (REQ-010.02-LUA)
- `spi_gpu/sim/gpu_sim_top.sv`: Simulation top-level wrapper (excludes UNIT-009, exposes pixel tap signals)
- `spi_gpu/sim/test_sdram_model.cpp`: SDRAM behavioral model smoke test
- `spi_gpu/Makefile`: `sim-interactive` build target with `-DSIM_DIRECT_CMD` and sim-specific Verilator file list

## Verification

- When the simulator is started, the SDL3 window opens and displays output from the GPU RTL model.
- When a Lua script submits a triangle render sequence via the FIFO injection API, the resulting pixels appear in the SDL3 window within the same rendered frame.
- When the command FIFO is full (`wr_almost_full` asserted), the Lua API and C++ injection layer apply backpressure (block the caller) rather than dropping commands.
- When `disp_vsync_out` asserts, the SDL3 window presents the completed frame.
- When `gpu_regs.lua` is loaded in the Lua interpreter, all helper functions listed in REQ-010.02-LUA are available and each function writes the correct register address with correctly packed field data.
- Lint check: `spi_gpu/sim/gpu_sim_top.sv` compiles cleanly under `verilator --lint-only -Wall -DSIM_DIRECT_CMD`.

## Design Notes

**SimTransport Integration:**
UNIT-037 does NOT implement a Rust `SimTransport` satisfying INT-040 in the initial version.
The Verilator interactive simulator is a standalone C++/Lua binary that drives the GPU RTL out-of-band via `SIM_DIRECT_CMD` ports.
See `design_decisions.md` for the formal decision and rationale.
A `SimTransport` wrapper could be added later if there is a demonstrated need to run `pico-gs-core` driver code (UNIT-022) against the sim without modification.

**Performance Measurement Caveat:**
The Verilator interactive simulator uses a behavioral SDRAM model and does not precisely reflect hardware timing.
Fill rate and frame time measurements from simulation should be treated as approximations only.
See REQ-011.01 for details on hardware performance targets and the simulation accuracy caveat.
