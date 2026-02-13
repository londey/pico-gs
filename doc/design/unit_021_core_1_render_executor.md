# UNIT-021: Core 1 Render Executor

## Purpose

Render command queue consumer

## Implements Requirements

- REQ-100 (Host Firmware Architecture)
- REQ-101 (Scene Management)
- REQ-102 (Render Pipeline Execution)
- REQ-104 (Unknown)
- REQ-111 (Dual-Core Architecture)
- REQ-115 (Render Mesh Patch)
- REQ-116 (Upload Texture)
- REQ-117 (VSync Synchronization)
- REQ-118 (Clear Framebuffer)
- REQ-123 (Double-Buffered Rendering)

## Interfaces

### Provides

None

### Consumes

- INT-020 (GPU Driver API)
- INT-021 (Render Command Format)

### Internal Interfaces

- **UNIT-026 (Inter-Core Queue)**: Owns the `CommandConsumer` end of the SPSC queue; dequeues `RenderCommand` variants each iteration.
- **UNIT-022 (GPU Driver Layer)**: Owns the `GpuHandle`; passes it to `render::commands::execute()` for all GPU operations.

## Design Description

### Inputs

- **`consumer: CommandConsumer<'static>`**: Consumer end of the heapless SPSC queue, providing `RenderCommand` variants produced by Core 0.
- **`gpu: GpuHandle`**: Opaque handle owning SPI bus, CS pin, and GPIO flow-control/vsync pins.
- **`dma: D`** (DmaMemcpy): Asynchronous flash-to-SRAM copy for mesh patch prefetch (INT-040).
- **`spi_out: B`** (BufferedSpiTransport): Double-buffered SPI output for GPU register writes (INT-040).

### Outputs

- **GPU SPI writes**: Each dequeued command results in one or more SPI register writes to the GPU via `GpuHandle`.
- **GPIO side effects**: Vsync wait (polls VSYNC pin), framebuffer swap (writes FB_DRAW/FB_DISPLAY registers).
- **defmt performance logs**: Every `PERF_LOG_INTERVAL` (120) frames, logs frame count, commands-per-frame, and idle spin count.

### Internal State

- **`frame_count: u32`** -- total frames rendered since Core 1 started.
- **`cmds_this_frame: u32`** -- number of commands executed in the current frame (reset at vsync).
- **`idle_spins: u32`** -- number of times the consumer found the queue empty in the current frame (reset at vsync).

### Algorithm / Behavior

1. **Entry**: `core1_main()` is spawned by Core 0 with ownership of `GpuHandle` and `CommandConsumer`. Logs startup message.
2. **Render loop** (infinite):
   a. **Dequeue**: Attempt `consumer.dequeue()`. If `None`, increment `idle_spins` and execute a NOP (spin-wait).
   b. **Dispatch**: On successful dequeue, call `render::commands::execute(&mut gpu, &cmd)` which pattern-matches the `RenderCommand` variant:
      - `ClearFramebuffer` -- renders two full-screen triangles for color clear; optionally clears depth buffer with two more triangles at far plane.
      - `SetTriMode` -- writes TRI_MODE register with gouraud/z_test/z_write flags.
      - `SubmitScreenTriangle` -- writes COLOR, UV0 (if textured), and VERTEX registers for 3 vertices. Retained for simple triangle demos.
      - `RenderMeshPatch` -- **full vertex processing pipeline**:
        1. DMA prefetch patch data from flash into inactive input buffer (double-buffered).
        2. Vertex processing: unpack, transform (MVP), perspective divide, viewport map, compute lighting, pack GpuVertex into 16-entry cache.
        3. Triangle submission: for each u8 strip entry, extract vertex_idx and kick, back-face cull, optionally clip, pack GPU register writes into active output buffer.
        4. SPI output: submit filled output buffer to BufferedSpiTransport. Swap buffers.
      - `UploadTexture` -- uploads texture data via MEM_ADDR/MEM_DATA and configures TEX0 registers.
      - `WaitVsync` -- blocks on VSYNC pin edge, then swaps draw/display framebuffers.
   c. **Frame boundary**: After executing a `WaitVsync` command, increment `frame_count`, log performance stats every 120 frames, and reset per-frame counters.
3. **Flow control**: The GPU driver's `write()` method blocks when CMD_FULL GPIO is asserted, providing hardware-level backpressure. The SPSC queue provides software-level decoupling from Core 0.

## Implementation

- `crates/pico-gs-rp2350/src/core1.rs`: `core1_main()` entry point, dequeue loop, performance counters (RP2350-specific)
- `crates/pico-gs-core/src/render/commands.rs`: `execute()` dispatcher, per-command GPU interactions (shared)

## Verification

- **Command dispatch test**: Verify each `RenderCommand` variant maps to the correct sequence of GPU register writes.
- **Frame boundary test**: Verify `WaitVsync` triggers vsync wait + buffer swap and resets per-frame counters.
- **Idle spin test**: Verify the consumer increments `idle_spins` when the queue is empty and executes NOP.
- **Performance logging test**: Verify stats are logged every `PERF_LOG_INTERVAL` frames.

### Core 1 Working RAM

| Component | Size |
|-----------|------|
| Input buffers (x2) | 1,136 B |
| Clip-space vertex cache | 640 B |
| Triangle clip workspace | 280 B |
| SPI output buffers (x2) | 1,620 B |
| Matrices + lights | 224 B |
| Core 1 stack | 4,096 B |
| DMA descriptors + misc | 192 B |
| **Total** | **~8.0 KB** (1.5% of 520 KB) |

## Design Notes

**Platform scope:** This unit describes the RP2350-specific Core 1 render executor. On the PC platform, command execution is performed synchronously in the main loop (no separate core/thread). The command dispatch logic (`render::commands::execute()`) is shared and lives in pico-gs-core.

Migrated from speckit module specification.
