# UNIT-021: Core 1 Render Executor

## Purpose

Render command queue consumer

## Parent Requirement Area

- Area 8: Scene Graph/ECS

## Implements Requirements

- REQ-008.01 (Scene Management) — Area 8: Scene Graph/ECS
- REQ-008.02 (Render Pipeline Execution) — Area 8: Scene Graph/ECS
- REQ-007.01 (Matrix Transformation Pipeline) — Area 7: Vertex Transformation
- REQ-007.02 (Render Mesh Patch) — Area 7: Vertex Transformation
- REQ-013.02 (Upload Texture) — Area 1: GPU SPI Controller
- REQ-013.03 (VSync Synchronization) — Area 6: Screen Scan Out
- REQ-005.08 (Clear Framebuffer) — Area 5: Blend/Frame Buffer Store
- REQ-005.09 (Double-Buffered Rendering) — Area 5: Blend/Frame Buffer Store
- REQ-014.01 (Lightmapped Static Mesh) — host-side render command dispatch for dual-texture rendering
- REQ-014 (Render Modes)
- REQ-008 (Scene Graph / ECS)

Note: REQ-100 (Host Firmware Architecture) and REQ-111 (Dual-Core Architecture) are retired; their references have been removed.
Note: This unit's name reflects its RP2350 dual-core origin. In a future change it may be merged with UNIT-020 into a single-threaded execution unit; for now it is re-parented under Area 8 without functional change.

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
      - `SetTriMode` -- writes RENDER_MODE register (0x30) with gouraud/z_test/z_write/color_write flags.
      - `SubmitScreenTriangle` -- writes COLOR, UV0 (if textured), and VERTEX registers for 3 vertices. Retained for simple triangle demos.
      - `RenderMeshPatch` -- **full vertex processing pipeline**:
        1. DMA prefetch patch data from flash into inactive input buffer (double-buffered).
        2. Vertex processing: unpack u16/i16 SoA blob (positions, normals, UVs), convert to f32 (positions via VCVT, normals divide by 32767.0, UVs divide by 8192.0), transform (MVP with quantization bias), perspective divide, viewport map, compute lighting, pack GpuVertex into 16-entry cache.
        3. RENDER_MODE configuration: write RENDER_MODE register (0x30) with flags from the command (gouraud, z_test, z_write, color_write). The `color_write` flag (bit 4) controls whether color buffer writes are enabled; when false, the GPU performs Z-only rendering for prepass.
        4. Optional Z_RANGE write: if the command includes z_range parameters (z_range_min, z_range_max), write the Z_RANGE register (0x31) with `{z_range_max[15:0], z_range_min[15:0]}`. This restricts Z-test to a sub-range of the depth buffer.
        5. Triangle submission: for each u8 strip entry, extract vertex_idx and kick, back-face cull, optionally clip, pack GPU register writes into active output buffer.
        6. SPI output: submit filled output buffer to BufferedSpiTransport. Swap buffers.
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
| Input buffers (x2) | 608 B |
| Clip-space vertex cache | 640 B |
| Triangle clip workspace | 280 B |
| SPI output buffers (x2) | 1,620 B |
| Matrices + lights | 224 B |
| Core 1 stack | 4,096 B |
| DMA descriptors + misc | 192 B |
| **Total** | **~7.5 KB** (1.4% of 520 KB) |

## Design Notes

**Platform scope:** This unit describes the RP2350-specific Core 1 render executor. On the PC platform, command execution is performed synchronously in the main loop (no separate core/thread). The command dispatch logic (`render::commands::execute()`) is shared and lives in pico-gs-core.

Migrated from speckit module specification.
