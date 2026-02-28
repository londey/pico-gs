# UNIT-020: Core 0 Scene Manager

## Purpose

Scene graph management and animation

## Parent Requirement Area

- Area 8: Scene Graph/ECS

## Implements Requirements

- REQ-008.01 (Scene Management) — Area 8: Scene Graph/ECS
- REQ-008.02 (Render Pipeline Execution) — Area 8: Scene Graph/ECS
- REQ-007.01 (Matrix Transformation Pipeline) — Area 7: Vertex Transformation
- REQ-008.03 (Scene Graph Management) — Area 8: Scene Graph/ECS
- REQ-008 (Scene Graph / ECS)

Note: REQ-100 (Host Firmware Architecture), REQ-111 (Dual-Core Architecture), and REQ-120 (Async Data Loading) are retired; their references have been removed.
Note: This unit's name reflects its RP2350 dual-core origin. In a future change it may be merged with UNIT-021 into a single-threaded execution unit; for now it is re-parented under Area 8 without functional change.

## Interfaces

### Provides

None

### Consumes

- INT-020 (GPU Driver API)
- INT-021 (Render Command Format)
- INT-013 (GPIO Status Signals)

### Internal Interfaces

- **UNIT-026 (Inter-Core Queue)**: Owns the `CommandProducer` end of the SPSC queue; enqueues `RenderCommand` variants via `enqueue_blocking()`.
- **UNIT-025 (USB Keyboard Handler)**: Calls `input::poll_keyboard()` each frame to receive `KeyEvent::SelectDemo` events.
- **UNIT-027 (Demo State Machine)**: Reads `Scene.active_demo` to determine per-frame rendering; calls `Scene::switch_demo()` on keyboard input.
- **UNIT-023 (Transformation Pipeline)**: Calls `transform::perspective()`, `transform::look_at()`, `transform::rotate_y()` to build MVP matrices for the teapot demo.
- **UNIT-024 (Lighting Calculator)**: Lighting parameters are passed through RenderMeshPatch commands to Core 1, which calls `compute_lighting()` per vertex.

## Design Description

### Inputs

- **USB keyboard events**: `input::poll_keyboard()` returns `Option<KeyEvent>` (keys 1/2/3 select demos).
- **Static mesh descriptors**: `MeshPatchDescriptor` arrays from const flash data. No runtime mesh generation.
- **Pre-built demo vertices**: `gouraud_triangle_vertices()` and `textured_triangle_vertices()` return `[GpuVertex; 3]` arrays.

### Outputs

- **Render commands**: `RenderCommand` variants enqueued to the inter-core SPSC queue via `CommandProducer`. Commands include `ClearFramebuffer`, `SetTriMode`, `SubmitScreenTriangle`, `UploadTexture`, and `WaitVsync`.
  - `RenderFlags` includes a `color_write` field. When `color_write` is false, the GPU writes only to the Z-buffer (RENDER_MODE bit 4 = 0). This enables Z-prepass rendering where depth is established first, then a second color pass writes only to visible pixels.
- **defmt log messages**: Diagnostic output for demo switches and teapot mesh statistics.

### Internal State

- **`Scene`** struct (`scene/mod.rs`):
  - `active_demo: Demo` -- currently active demo variant.
  - `needs_init: bool` -- set true on demo switch, cleared after one-time initialization runs.
- **`producer: CommandProducer<'static>`** -- owned producer end of the SPSC queue.
- **`angle: f32`** -- current Y-axis rotation angle for the teapot demo (wraps at 2*pi).
- **`projection: Mat4`, `view: Mat4`** -- camera matrices, computed once at startup.
- **`lights: [DirectionalLight; 4]`, `ambient: AmbientLight`** -- lighting parameters, constant.
- **`frustum_planes: [Vec4; 6]`** -- frustum planes extracted from MVP each frame.
- **`gouraud_verts`, `textured_verts`** -- pre-packed `[GpuVertex; 3]` for the simple triangle demos.

### Algorithm / Behavior

1. **Initialization** (platform-specific):
   - **RP2350**: Configure clocks, SPI0, GPIO pins. Call `GpuDriver::new()` to verify GPU. Split SPSC queue. Spawn Core 1 with consumer and GPU handle.
   - **PC**: Open FT232H device. Call `GpuDriver::new()` to verify GPU. No queue or core spawning needed.
   - **Common**: Initialize `Scene::new()` (defaults to `GouraudTriangle`) and input subsystem. Pre-generate mesh data and camera matrices.
2. **Main loop** (runs indefinitely on Core 0):
   a. **Poll input**: Call `input::poll_keyboard()`; on `SelectDemo` event, call `scene.switch_demo()`.
   b. **One-time init on demo switch**: If `scene.needs_init` is true, perform demo-specific setup (e.g., upload checkerboard texture for `TexturedTriangle`, reset angle for `SpinningTeapot`). Clear the flag.
   c. **Per-frame rendering**: Match on `scene.active_demo`:
      - `GouraudTriangle`: Enqueue clear (black) + SetTriMode(gouraud) + 1 ScreenTriangle.
      - `TexturedTriangle`: Enqueue clear (black) + SetTriMode(textured) + 1 ScreenTriangle.
      - `SpinningTeapot`: Build MVP from incrementing angle. Enqueue clear + SetTriMode. Call `submit_mesh_patches()` which:
        1. Test overall mesh AABB against frustum; skip if outside.
        2. For each patch: test patch AABB against frustum planes.
           - Fully outside: skip.
           - Partially inside: compute 6-bit clip_flags bitmask.
        3. Enqueue `RenderMeshPatch { patch, mvp, mv, lights, ambient, flags, clip_flags }` per visible patch (~20-29 commands vs ~144 SubmitScreenTriangle previously).
        4. *(Optional Z-prepass)*: When enabled, the SpinningTeapot demo performs two passes:
           - **Z-prepass**: Enqueue `SetTriMode` with `z_test=true, z_write=true, color_write=false`. Enqueue all visible `RenderMeshPatch` commands. The GPU writes only depth, establishing the Z-buffer without color writes.
           - **Color pass**: Enqueue `SetTriMode` with `z_test=true, z_write=false, color_write=true`. Re-enqueue visible patches. Fragments that fail the Z-test are rejected early, reducing overdraw.
   d. **End frame**: Enqueue `WaitVsync` to signal Core 1 to sync and swap buffers.
3. **Backpressure**: `enqueue_blocking()` spins with NOP when the SPSC queue is full, providing flow control between Core 0 (producer) and Core 1 (consumer).

## Implementation

- `crates/pico-gs-core/src/scene/mod.rs`: `Scene` struct and `switch_demo()` logic (platform-agnostic)
- `crates/pico-gs-core/src/scene/demos.rs`: Demo vertex data, lighting parameters, constants (platform-agnostic)
- `crates/pico-gs-rp2350/src/main.rs`: RP2350 main loop orchestration, `enqueue_blocking()`

## Verification

- **Unit tests**: Verify `Scene::new()` defaults to `GouraudTriangle` with `needs_init = true`. Verify `switch_demo()` sets `needs_init` and returns true only on actual change.
- **Integration tests**: Confirm that each demo variant enqueues the expected sequence of `RenderCommand`s per frame (clear + mode + triangles + vsync).
- **Backpressure test**: Verify `enqueue_blocking()` retries when the queue is full and succeeds when space becomes available.
- **Demo switch test**: Verify that switching demos triggers one-time init (e.g., texture upload for `TexturedTriangle`, angle reset for `SpinningTeapot`).

## Design Notes

Migrated from speckit module specification.
