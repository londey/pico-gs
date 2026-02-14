# Concept of Execution

This document describes the runtime behavior of the system: how it starts up, how data flows through it, and how it responds to events.

## System Overview

The pico-gs system is a two-chip 3D graphics pipeline. An RP2350 microcontroller (dual Cortex-M33, 150 MHz) acts as the host, Core 0 performs scene management and frustum culling, while Core 1 runs a DMA-pipelined vertex processing engine that transforms vertices, computes lighting, clips triangles, and drives the GPU over a 25 MHz SPI bus to a Lattice ECP5 FPGA. The FPGA implements a fixed-function triangle rasterizer with Gouraud shading, Z-buffering, and texture sampling. It drives a 640x480 DVI output from a double-buffered framebuffer stored in 32 MB of external async SRAM. The host and GPU communicate through a register-write protocol: each SPI transaction is a 9-byte frame (1-byte address + 8-byte data) that writes to the GPU register file, which accumulates vertex data and triggers rasterization on every third vertex write.

## Platform Variants

The pico-gs host software supports two execution platforms:

### RP2350 Platform (Production)

The primary platform, as described throughout this document. Dual Cortex-M33 cores running no_std Rust firmware, communicating with the GPU over hardware SPI0. See sections below for full details.

### PC Platform (Debug)

A secondary platform for GPU development and debugging. A standard PC running a Rust std binary communicates with the same spi_gpu FPGA hardware via an Adafruit FT232H USB-to-SPI adapter.

**Key differences from RP2350:**

| Aspect | RP2350 | PC |
|--------|--------|-----|
| Threading | Dual-core (Core 0 + Core 1) | Three threads (main + render + SPI) |
| SPI transport | rp235x-hal SPI0, 25 MHz | FT232H MPSSE SPI, configurable speed |
| Inter-stage comm | Lock-free SPSC queue (64 entries) | Direct function calls (synchronous) |
| Input | USB HID keyboard (TinyUSB) | Terminal keyboard (crossterm) |
| Logging | defmt over RTT | tracing with file/console output |
| Debug features | LED error indicator | Frame capture, command replay, full tracing |

**PC execution flow (3-thread model):**
1. Initialize FT232H SPI adapter and GPIO pins
2. Call `GpuDriver::new(ft232h_transport)` to verify GPU presence (ID register check)
3. Initialize scene state (same code as RP2350 Core 0)
4. Spawn 3 threads:
   - **Main thread** (scene/culling): Poll terminal keyboard input, update scene state, frustum cull mesh patches, enqueue RenderMeshPatch commands to a channel
   - **Render thread** (vertex processing): Dequeue commands, transform vertices, compute lighting, cull/clip, pack GPU register writes into output buffer
   - **SPI thread** (FT232H output): Consume packed register write buffers, send via FT232H SPI
5. Log all GPU register writes with timestamps for post-analysis

**Shared code path:** Scene management, vertex transformation, lighting calculation, GPU vertex packing, and render command generation are identical between platforms. Only the execution orchestration (threading, command dispatch, I/O) differs.

## Operational Modes

Reference: `doc/requirements/states_and_modes.md`

The system operates in four phases at runtime.
**FPGA Boot Screen** begins immediately after PLL lock: the command FIFO starts non-empty with ~18 pre-populated register writes baked into the bitstream (see DD-019), which the register file drains autonomously at the core clock rate (~0.18 us at 100 MHz).
This draws a black screen-clear followed by a Gouraud-shaded RGB triangle and presents the result, producing a visible self-test boot screen before any SPI traffic arrives.
**Host Initialization** covers clock/peripheral setup on the RP2350, GPU ID verification via SPI, framebuffer address configuration, and Core 1 spawn; by the time the host sends its first SPI transaction (~100 ms after power-on), the FPGA boot screen is already displayed.
**Active Rendering** is the steady-state loop where Core 0 generates render commands for the current demo and Core 1 executes them against the GPU, synchronized to 60 Hz vsync.
**Demo Switching** occurs when a USB keyboard event selects a new demo (GouraudTriangle, TexturedTriangle, or SpinningTeapot); the scene sets `needs_init = true`, triggering one-time setup (e.g., texture upload) before the new demo's per-frame rendering begins.

## Startup Sequence

### FPGA Boot Screen (autonomous, no host involvement)

The FPGA executes a self-test boot screen immediately after PLL lock, before any SPI traffic:

1. **PLL lock and reset release**: The ECP5 PLL locks (50-500 ms after power-on) and reset synchronizers deassert across all clock domains.
2. **Boot command drain**: The command FIFO (UNIT-002) starts non-empty with ~18 pre-populated register writes embedded in the bitstream memory initialization (see DD-019).
   The register file (UNIT-003) begins consuming these commands at the system clock rate, one entry per cycle.
3. **Boot sequence content**: The pre-populated commands set FB_DRAW to Framebuffer A, draw two black screen-covering triangles (flat shading, screen clear), then set RENDER_MODE to Gouraud shading, draw a centered RGB triangle with red/green/blue vertex colors, and finally write FB_DISPLAY to present Framebuffer A.
4. **Completion**: All ~18 boot commands are consumed in ~0.18 us at 100 MHz (18 commands x 10 ns per cycle).
   CMD_EMPTY asserts, the boot screen is visible on the display output, and the GPU is ready for host SPI traffic.

### Host Boot Sequence (Core 0)

The host boot sequence executes entirely on Core 0 before the render loop begins:

1. **Clock init**: Configure RP2350 system clocks from the 12 MHz crystal via PLL (`init_clocks_and_plls`).
2. **GPIO and SPI setup**: Initialize GPIO bank, configure SPI0 pins (GP2/3/4) at 25 MHz MODE_0, set manual CS pin (GP5) high, configure flow-control inputs: CMD_FULL (GP6), CMD_EMPTY (GP7), VSYNC (GP8), and error LED (GP25).
3. **GPU detection**: Call `gpu_init` which reads the ID register (addr `0x7F`) over SPI and verifies device ID `0x6702`. On mismatch, the system halts with a 100 ms LED blink loop. On success, it writes initial FB_DRAW (Framebuffer A at `0x000000`) and FB_DISPLAY (Framebuffer B at `0x12C000`).
   Note: by this point (~100 ms after power-on), the FPGA boot screen has long since completed and is visible on the display.
4. **Command queue split**: The statically-allocated 64-entry `heapless::spsc::Queue` is split into a `Producer` (for Core 0) and a `Consumer` (for Core 1). This is done exactly once before Core 1 starts.
5. **Core 1 spawn**: Core 1 is launched with a 4 KB stack, taking ownership of the `GpuHandle` and the queue `Consumer`. It enters `core1_main` and begins polling for commands immediately.
6. **Scene setup**: Core 0 initializes the `Scene` state machine (default demo: GouraudTriangle, `needs_init = true`), pre-generates mesh data (teapot vertices/triangles), sets up the projection and view matrices, and enters the main loop.

## Data Flow

```
            RP2350 Host                                ECP5 FPGA GPU
 ┌─────────────────────────────┐          ┌──────────────────────────────────────┐
 │  Core 0 (Scene / Transform) │          │                                      │
 │                              │          │  SPI Slave ──► Command FIFO (32x72b) │
 │  Scene state                 │          │                    │                  │
 │    │                         │          │                    ▼                  │
 │    ▼                         │          │  Register File (vertex accumulator)  │
 │  Transform vertices (MVP)    │          │       │ (3rd VERTEX write)           │
 │  Gouraud lighting            │          │       ▼                              │
 │  Pack into GpuVertex         │          │  Rasterizer (12-state FSM)           │
 │    │                         │          │       │                              │
 │    ▼                         │  SPI     │       ▼            SRAM Arbiter      │
 │  SPSC Queue ═══════════════╗ │  25MHz   │  FB Write ──────► (4 ports) ──► SRAM│
 │  (64 entries, ~5 KB)       ║ │ ──────►  │  ZB Read/Write ──►            32 MB │
 │                             ║ │  9-byte  │                    ▲                │
 │  Core 1 (GPU Driver)       ║ │  frames  │  Display Ctrl ─────┘                │
 │    ▲                        ║ │          │       │                              │
 │    ║ dequeue                ║ │          │       ▼                              │
 │    ╚════════════════════════╝ │          │  Scanline FIFO ──► DVI Output       │
 │    │                          │          │                     640x480 @ 60 Hz │
 │    ▼                          │          └──────────────────────────────────────┘
 │  gpu.write(addr, data)       │
 │  (CS low, 9 bytes, CS high)  │
 └──────────────────────────────┘
```

**Core 0** runs the scene loop each frame: poll keyboard input, update scene state, perform frustum culling (test overall mesh AABB then per-patch AABBs against the view frustum), and enqueue `RenderMeshPatch` commands for visible patches into the lock-free SPSC queue. **Core 1** dequeues commands and runs the full vertex processing pipeline: DMA-prefetch patch data from flash into a double-buffered SRAM input buffer, transform vertices (MVP), compute Gouraud lighting, perform back-face culling, optionally clip triangles (Sutherland-Hodgman) for patches crossing frustum planes, pack GPU register writes into a double-buffered SPI output buffer, and submit via DMA/PIO-driven SPI. Each register write is a 9-byte SPI transaction. **On the FPGA**, the SPI slave deserializes 72 bits into a command FIFO (depth 32, custom soft FIFO backed by a regular memory array). At power-on, the FIFO contains ~18 pre-populated boot commands from the bitstream that execute a self-test boot screen autonomously (see DD-019); during normal operation, only SPI-sourced commands flow through the FIFO. The register file consumes FIFO entries, latching color/UV/position state. Every third VERTEX write emits a `tri_valid` pulse to the rasterizer, which scans the bounding box, performs edge tests, interpolates Z and color, tests against the Z-buffer, and writes passing pixels to the framebuffer in SRAM. The display controller independently prefetches scanlines from the display framebuffer into a FIFO and outputs them through the DVI encoder at the 25 MHz pixel clock (synchronous 4:1 from the 100 MHz core clock).

## Event Handling

### Event: USB Keyboard Input (Demo Switch)

- **Source:** USB host stack via `input::poll_keyboard()` on Core 0
- **Handler:** `Scene::switch_demo()` in `host_app/src/scene/mod.rs`
- **Response:** Sets `active_demo` to the selected demo and `needs_init = true`. On the next frame iteration, demo-specific initialization runs (e.g., texture upload for TexturedTriangle, angle reset for SpinningTeapot), then per-frame rendering switches to the new demo.

### Event: VSYNC (Frame Boundary)

- **Source:** GPU display controller outputs `gpio_vsync` (GP8) at 60 Hz
- **Handler:** `GpuHandle::wait_vsync()` called from Core 1 when executing `RenderCommand::WaitVsync`
- **Response:** Core 1 blocks on the VSYNC GPIO rising edge, then calls `swap_buffers()` to exchange the draw and display framebuffer addresses. This ensures the completed frame is displayed and the next frame renders to the back buffer. Performance counters are logged every 120 frames.

### Event: CMD_FULL (GPU Backpressure)

- **Source:** FPGA command FIFO almost-full signal on `gpio_cmd_full` (GP6)
- **Handler:** `GpuHandle::write()` in `host_app/src/gpu/mod.rs`
- **Response:** Every register write spin-waits until CMD_FULL is deasserted before sending the 9-byte SPI transaction. This provides hardware flow control, preventing command FIFO overflow on the GPU side.

## Timing and Synchronization

**Frame rate**: The display controller generates a 640x480 @ 60 Hz VGA timing signal (25 MHz pixel clock, derived as a synchronous 4:1 divisor from the 100 MHz core clock). VSYNC pulses define frame boundaries. Core 1 blocks on VSYNC at the end of each frame, naturally limiting the system to 60 FPS.

**Inter-core synchronization**: Core 0 and Core 1 communicate through a `heapless::spsc::Queue<RenderCommand, 64>`, a lock-free single-producer single-consumer ring buffer using atomic head/tail pointers. No mutexes or critical sections are used. When the queue is full, Core 0 spin-waits with `nop()` (backpressure). When the queue is empty, Core 1 spin-waits with `nop()`.

**Double-buffered framebuffer**: The GPU maintains separate draw and display framebuffer addresses. The display controller reads from FB_DISPLAY continuously, while the rasterizer writes to FB_DRAW. At VSYNC, Core 1 swaps these addresses via register writes, ensuring tear-free output.

**SPI bus timing**: The SPI bus runs at 25 MHz, MODE_0. Each register write is a 9-byte (72-bit) transaction taking ~2.88 us. A triangle submission requires 6-9 register writes (COLOR + optional UV + VERTEX for each of 3 vertices), so ~17-26 us per triangle.

## Error Handling

**GPU ID mismatch**: During `gpu_init`, if the ID register does not return `0x6702`, the system logs an error via `defmt` and enters an infinite LED blink loop (100 ms on/off on GP25). This is a fatal, non-recoverable error indicating the FPGA is not programmed or not connected.

**CMD_FULL spin-wait**: If the GPU command FIFO is full, `GpuHandle::write()` busy-waits. There is no timeout or error escalation; the system assumes the GPU will always drain commands. Similarly, `enqueue_blocking` on Core 0 spin-waits if the inter-core queue is full.

**SPI bus errors**: SPI transfer results are silently discarded (`let _ = self.spi.write(&buf)`). There is no retry, CRC check, or error detection on the SPI link. A corrupted transaction could write incorrect data to any GPU register.

**Invalid texture ID**: `execute_upload_texture` bounds-checks the texture ID against the texture table length and logs a warning if out of range, but otherwise continues operation.

## Resource Management

**GPU SRAM layout** (32 MB external async SRAM on the FPGA):

| Region | Address | Size |
|--------|---------|------|
| Framebuffer A | `0x000000` | 1,228,800 bytes (640x480x4) |
| Framebuffer B | `0x12C000` | 1,228,800 bytes (640x480x4) |
| Z-Buffer | `0x258000` | 1,228,800 bytes (640x480x4, padded) |
| Texture Memory | `0x384000` | Remaining space |

**RP2350 SRAM** (~520 KB total): The firmware is entirely `no_std` with no heap allocator. All state is statically allocated: the command queue is a 64-entry static `spsc::Queue` (~16.5 KB at ~264 bytes per RenderMeshPatch), Core 1 has a 4 KB stack plus ~8 KB working RAM (DMA input buffers, vertex cache, clip workspace, SPI output buffers), and mesh data is const flash data from the asset pipeline (no runtime mesh generation). Texture data is stored in flash (linked into the firmware binary). The `GpuVertex` struct packs to ~24 bytes.

**FPGA resources**: The command FIFO is 32 entries deep (72 bits each), implemented as a custom soft FIFO backed by a regular memory array (not a Lattice EBR FIFO macro) so that the bitstream can pre-populate the memory with boot commands (see DD-019). The SRAM arbiter has 4 ports with fixed priority: display read (port 0, highest), framebuffer write (port 1), Z-buffer read/write (port 2), texture read (port 3, lowest/unused). The display controller's scanline FIFO holds ~1024 words (~1.6 scanlines) to absorb SRAM access latency.

**SRAM burst mode**: The external async SRAM supports burst read and burst write operations, allowing multiple sequential 16-bit words to be transferred without re-issuing the address between each word.
The SRAM arbiter (UNIT-007) exploits burst mode for sequential access patterns: display scanout (port 0) reads consecutive scanline pixels, framebuffer writes (port 1) write consecutive rasterized pixels, Z-buffer accesses (port 2) read/write consecutive depth values for scanline-order fragments, and texture cache fills (port 3) read consecutive block data on cache miss.
Burst transfers improve effective SRAM throughput by eliminating per-word address setup overhead, particularly benefiting display scanout (2560 bytes per scanline) and texture cache line fills (8-32 bytes per miss).
See INT-011 for the revised bandwidth budget under burst mode, and UNIT-007 for arbiter burst grant policy.
