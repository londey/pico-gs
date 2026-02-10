# UNIT-027: Demo State Machine

## Purpose

Demo selection and switching logic

## Implements Requirements

- REQ-103 (Unknown)
- REQ-122 (Default Demo Startup)

## Interfaces

### Provides

None

### Consumes

- INT-021 (Render Command Format)

### Internal Interfaces

- **UNIT-020 (Core 0 Scene Manager)**: The main loop reads `scene.active_demo` to determine per-frame rendering behavior and calls `scene.switch_demo()` on keyboard input.
- **UNIT-025 (USB Keyboard Handler)**: `KeyEvent::SelectDemo(Demo)` events drive demo transitions via `Scene::switch_demo()`.

## Design Description

### Inputs

- **`Demo` variant** (via `Scene::switch_demo(demo)`): The requested demo to switch to, originating from keyboard input.
- **`Scene::new()` call**: Creates the initial scene with the default demo.

### Outputs

- **`Scene.active_demo: Demo`**: Read by the Core 0 main loop to determine which rendering path to execute each frame.
- **`Scene.needs_init: bool`**: Set `true` on demo switch; signals the main loop to perform one-time initialization for the new demo.
- **`switch_demo()` returns `bool`**: `true` if the demo actually changed, `false` if already active (no-op).
- **Demo data functions**: `gouraud_triangle_vertices()` returns `[GpuVertex; 3]`; `textured_triangle_vertices()` returns `[GpuVertex; 3]`; `teapot_lights()` returns `[DirectionalLight; 4]`; `teapot_ambient()` returns `AmbientLight`.
- **Demo constants**: `TEAPOT_COLOR: [u8; 4]` (surface color), `TEAPOT_ROTATION_SPEED: f32` (radians/frame).

### Internal State

- **`Demo` enum**: Three variants -- `GouraudTriangle` (default), `TexturedTriangle`, `SpinningTeapot`.
- **`Scene` struct** (defined in `scene/mod.rs`):
  - `active_demo: Demo` -- the currently running demo.
  - `needs_init: bool` -- one-shot flag for demo initialization.

### Algorithm / Behavior

1. **Default startup**: `Demo::default()` returns `GouraudTriangle`. `Scene::new()` sets `active_demo = GouraudTriangle` and `needs_init = true`.
2. **Demo switching** (`switch_demo()`): If the requested demo differs from `active_demo`, update `active_demo`, set `needs_init = true`, return `true`. If same demo, return `false` (no state change).
3. **One-time initialization**: The main loop checks `needs_init` each frame. When set:
   - `TexturedTriangle`: Enqueues `UploadTexture` command for checkerboard texture.
   - `SpinningTeapot`: Resets rotation angle to 0.
   - `GouraudTriangle`: No special init required.
   Clears `needs_init = false` after init runs.
4. **Per-frame rendering**: The main loop matches on `active_demo` and generates the appropriate render commands:
   - `GouraudTriangle`: 1 triangle, Gouraud-shaded RGB.
   - `TexturedTriangle`: 1 triangle, textured with UV coordinates.
   - `SpinningTeapot`: Full 3D mesh with MVP transform, Gouraud lighting, back-face culling (~144 visible triangles), incrementing rotation angle by `TEAPOT_ROTATION_SPEED` per frame.
5. **Demo data**: Pre-built vertex arrays and lighting parameters are provided as pure functions and constants in `scene/demos.rs`, generated once at startup and reused each frame.

## Implementation

- `host_app/src/scene/demos.rs`: `Demo` enum, vertex generators, lighting parameters, constants
- `host_app/src/scene/mod.rs`: `Scene` struct with `new()` and `switch_demo()`

## Verification

- **Default demo test**: Verify `Demo::default()` returns `GouraudTriangle`.
- **Switch test**: Verify `switch_demo()` with a different demo sets `needs_init = true` and returns `true`.
- **No-op switch test**: Verify `switch_demo()` with the same demo does not set `needs_init` and returns `false`.
- **Vertex data test**: Verify `gouraud_triangle_vertices()` returns 3 vertices with distinct non-zero colors and screen-space positions within 640x480.
- **Textured vertex test**: Verify `textured_triangle_vertices()` returns 3 vertices with valid UV coordinates and white vertex colors.
- **Lighting test**: Verify `teapot_lights()` returns normalized direction vectors and non-zero color for at least 2 lights.

## Design Notes

Migrated from speckit module specification.
