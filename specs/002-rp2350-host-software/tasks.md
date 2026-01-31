# Tasks: RP2350 Host Software

**Input**: Design documents from `/specs/002-rp2350-host-software/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Tests**: Unit tests are included for math/packing modules as specified in plan.md (host-side `cargo test`). On-target hardware validation is manual.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Rust project initialization, toolchain configuration, and Cargo dependencies

- [x] T001 Create Cargo project structure with `firmware/Cargo.toml` including all dependencies: `rp235x-hal`, `cortex-m-rt`, `cortex-m`, `heapless`, `glam` (no_std + libm), `fixed`, `defmt`, `defmt-rtt`, `panic-probe`, `critical-section`
- [x] T002 Create `firmware/.cargo/config.toml` with target `thumbv8m.main-none-eabihf`, runner `probe-rs run --chip RP2350`, rustflags for `flip-link` and linker scripts
- [x] T003 [P] Create `firmware/memory.x` linker memory layout for RP2350 (520 KB SRAM, 4 MB flash)
- [x] T004 [P] Create `firmware/src/main.rs` with minimal `cortex-m-rt` entry point, HAL initialization (clocks, SIO, GPIO, SPI0), `defmt` logging, and Core 1 spawn via `rp235x-hal::multicore`
- [x] T005 [P] Create `firmware/src/core1.rs` with Core 1 entry function stub that logs startup via `defmt` and enters an infinite loop

**Checkpoint**: Project builds with `cargo build --release`, produces a flashable binary, and both cores start (verified via defmt log output).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: GPU driver, fixed-point math, register definitions, and render command types that ALL user stories depend on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T006 Create GPU register constants in `firmware/src/gpu/registers.rs` — all v2.0 register addresses (COLOR 0x00, UV0 0x01, VERTEX 0x05, TEX0_BASE 0x10, TEX0_FMT 0x11, TEX0_WRAP 0x14, TRI_MODE 0x30, ALPHA_BLEND 0x31, FB_DRAW 0x40, FB_DISPLAY 0x41, FB_ZBUFFER 0x42, MEM_ADDR 0x70, MEM_DATA 0x71, STATUS 0x7E, ID 0x7F) and bit-field helpers
- [x] T007 [P] Implement fixed-point conversion helpers in `firmware/src/math/fixed.rs` — `f32_to_12_4()` for vertex X/Y, `f32_to_1_15()` for UV/Q, `f32_to_z25()` for depth, and `rgba_to_packed()` for vertex color (ABGR u32)
- [x] T008 [P] Write unit tests for fixed-point conversions in `firmware/tests/packing_tests.rs` — test boundary values, zero, negative, max range for each format
- [x] T009 Implement GPU SPI driver in `firmware/src/gpu/mod.rs` — `gpu_init()` (configure SPI0 at 25 MHz Mode 0, GPIO pins for CS/CMD_FULL/CMD_EMPTY/VSYNC, read ID register and verify 0x6702, halt with LED blink on failure), `gpu_write()` (pack 9-byte transaction, poll CMD_FULL before write, toggle CS), `gpu_read()` (9-byte read transaction)
- [x] T010 Implement GpuVertex packing in `firmware/src/gpu/vertex.rs` — `pack_color()`, `pack_uv()`, `pack_vertex_position()` functions that convert f32 values to GPU register format using the fixed-point helpers
- [x] T011 Implement render command types in `firmware/src/render/mod.rs` — `RenderCommand` enum (RenderMeshPatch, UploadTexture, WaitVsync, ClearFramebuffer), `MeshPatchCommand`, `UploadTextureCommand`, `ClearCommand` structs, and SPSC queue type alias using `heapless::spsc::Queue`
- [x] T012 Implement `gpu_wait_vsync()` in `firmware/src/gpu/mod.rs` — poll VSYNC GPIO for rising edge
- [x] T013 Implement `gpu_swap_buffers()` in `firmware/src/gpu/mod.rs` — write FB_DISPLAY and FB_DRAW register addresses for double-buffered rendering (framebuffer A at 0x000000, B at 0x12C000)

**Checkpoint**: Foundation ready — GPU driver can init, write registers, read ID, wait for vsync, and swap buffers. Fixed-point conversions pass unit tests. Render command types are defined.

---

## Phase 3: User Story 1 — Gouraud-Shaded Triangle (Priority: P1) 🎯 MVP

**Goal**: Render a single Gouraud-shaded triangle on the display at ≥30 FPS. Validates the entire end-to-end pipeline.

**Independent Test**: Deploy firmware, power on, visually confirm a smoothly shaded triangle on the display within 2 seconds. Stable for 60 seconds with no tearing.

### Implementation for User Story 1

- [x] T014 [US1] Implement `ClearFramebuffer` command execution in `firmware/src/render/commands.rs` — set TRI_MODE to flat/no-Z, set COLOR, submit 2 full-viewport triangles (0,0)-(639,0)-(639,479) and (0,0)-(639,479)-(0,479) via `gpu_write()`. Include z-buffer clear path (ALWAYS compare, far-plane Z, restore LEQUAL)
- [x] T015 [US1] Implement `gpu_submit_triangle()` in `firmware/src/gpu/mod.rs` — write COLOR, UV0 (if textured), VERTEX for each of 3 vertices. Third VERTEX write triggers GPU rasterization
- [x] T016 [US1] Implement `WaitVsync` command execution in `firmware/src/render/commands.rs` — call `gpu_wait_vsync()` then `gpu_swap_buffers()` to present the completed frame
- [x] T017 [US1] Define Gouraud triangle demo data in `firmware/src/scene/demos.rs` — 3 hardcoded vertices with distinct colors (red, green, blue) at screen-space positions forming a visible triangle, and a `Demo::GouraudTriangle` variant
- [x] T018 [US1] Implement Core 0 main loop for single-demo mode in `firmware/src/main.rs` — initialize scene, generate render commands each frame (ClearFramebuffer → submit triangle vertices → WaitVsync), enqueue to SPSC queue
- [x] T019 [US1] Implement Core 1 render loop in `firmware/src/core1.rs` — dequeue render commands from SPSC queue, dispatch to command execution (clear, triangle submit, vsync/swap), configure TRI_MODE for Gouraud shading (GOURAUD=1, no texture, no Z)
- [x] T020 [US1] Wire up double-buffered rendering in `firmware/src/core1.rs` — track current draw/display buffer addresses, alternate after each vsync swap

**Checkpoint**: US1 complete — Gouraud-shaded triangle renders at ≥30 FPS with double-buffered vsync. This is the MVP.

---

## Phase 4: User Story 2 — Textured Triangle (Priority: P2)

**Goal**: Upload a texture to GPU memory and render a textured triangle. Validates the texture upload pipeline and texture-mapped rendering.

**Independent Test**: Select textured triangle demo (hardcoded or via demo switch stub), confirm textured triangle appears with correct mapping and no artifacts at ≥30 FPS.

### Implementation for User Story 2

- [x] T021 [P] [US2] Create demo texture data in `firmware/src/assets/textures.rs` — a small const RGBA8888 texture (e.g., 64×64 checkerboard pattern) stored in flash as `&[u32]`
- [x] T022 [US2] Implement `UploadTexture` command execution in `firmware/src/render/commands.rs` — write MEM_ADDR with target GPU address, then write MEM_DATA for each 32-bit word of texture data via `gpu_write()`. Configure TEX0_BASE, TEX0_FMT (width/height log2, RGBA8, enabled), TEX0_WRAP (REPEAT)
- [x] T023 [US2] Implement perspective-correct UV packing in `firmware/src/gpu/vertex.rs` — compute U/W, V/W, 1/W from vertex UV and W values, pack to 1.15 fixed-point for UV0 register
- [x] T024 [US2] Define textured triangle demo data in `firmware/src/scene/demos.rs` — 3 vertices with UV coordinates (0,0), (1,0), (0.5,1), white vertex color, and a `Demo::TexturedTriangle` variant referencing the checkerboard texture
- [x] T025 [US2] Add textured triangle rendering path to Core 1 in `firmware/src/core1.rs` — for `Demo::TexturedTriangle`: upload texture on demo init (once), then per frame: clear, configure TRI_MODE (GOURAUD=1, TEX0 enabled), submit vertices with COLOR + UV0 + VERTEX per vertex, vsync/swap
- [x] T026 [US2] Add demo selection stub in `firmware/src/scene/mod.rs` — `Scene` struct with `active_demo: Demo` field and `switch_demo()` method that queues texture upload on transition to TexturedTriangle

**Checkpoint**: US2 complete — Textured triangle renders correctly at ≥30 FPS. Texture upload works via MEM_ADDR/MEM_DATA.

---

## Phase 5: User Story 3 — Spinning Utah Teapot (Priority: P3)

**Goal**: Render a lit, rotating Utah Teapot using the full 3D pipeline: mesh management, MVP transforms, Gouraud lighting, depth testing, and continuous animation.

**Independent Test**: Select teapot demo, confirm lit rotating teapot with correct depth ordering and smooth Gouraud shading at ≥30 FPS.

### Implementation for User Story 3

- [x] T027 [P] [US3] Create Utah Teapot mesh data in `firmware/src/assets/teapot.rs` — const arrays for vertex positions, normals, and triangle indices stored in flash. Pre-split into MeshPatch groups of ≤128 vertices each
- [x] T028 [P] [US3] Implement MVP transform pipeline in `firmware/src/render/transform.rs` — `transform_vertex()`: multiply object-space position by MVP matrix, perspective divide (x/w, y/w, z/w), viewport transform to 640×480 screen coordinates, convert to 12.4 fixed-point X/Y and 25-bit Z. `transform_normal()`: multiply normal by inverse-transpose of model-view matrix
- [x] T029 [P] [US3] Implement Gouraud lighting in `firmware/src/render/lighting.rs` — `compute_lighting()`: for each vertex normal, compute `ambient + Σ(max(0, dot(N, L[i])) × light_color[i])` for 4 directional lights + ambient. Output RGBA8 vertex color. Clamp channels to 0-255
- [x] T030 [P] [US3] Write unit tests for transform pipeline in `firmware/tests/transform_tests.rs` — test identity transform, known rotation, perspective projection, viewport mapping, edge coordinates
- [x] T031 [P] [US3] Write unit tests for lighting in `firmware/tests/lighting_tests.rs` — test head-on light (dot=1.0), perpendicular (dot=0.0), back-facing (dot<0 → clamped), multiple lights additive, ambient-only
- [x] T032 [US3] Implement `RenderMeshPatch` command execution in `firmware/src/render/commands.rs` — for each vertex: transform position, transform normal, compute lighting, pack to GpuVertex. For each triangle (from indices): optional back-face cull (screen-space cross product), submit 3 vertices to GPU via `gpu_submit_triangle()`
- [x] T033 [US3] Define teapot demo scene in `firmware/src/scene/demos.rs` — `Demo::SpinningTeapot` variant with: model matrix (rotating Y-axis based on animation_time), view matrix (camera at fixed position), projection matrix (perspective with ~60° FOV), 4 directional lights (front-left, front-right, top, back-fill) + ambient
- [x] T034 [US3] Add teapot rendering path to Core 0 in `firmware/src/main.rs` — per frame: increment animation_time, update model rotation matrix, generate ClearFramebuffer command, generate RenderMeshPatch command for each teapot patch (with current MVP and lights), generate WaitVsync command. Enqueue all to SPSC queue
- [x] T035 [US3] Configure depth testing for teapot in `firmware/src/core1.rs` — on teapot demo: set FB_ZBUFFER (address 0x258000, LEQUAL compare), set TRI_MODE (GOURAUD=1, Z_TEST=1, Z_WRITE=1). Include z-buffer clear in ClearFramebuffer for this demo

**Checkpoint**: US3 complete — Spinning lit teapot renders with correct depth ordering and Gouraud shading at ≥30 FPS. Full 3D pipeline validated.

---

## Phase 6: User Story 4 — USB Keyboard Demo Switching (Priority: P4)

**Goal**: Connect a USB keyboard and press number keys 1-3 to switch between demos in real time.

**Independent Test**: Connect USB keyboard, press 1/2/3 keys, confirm display switches to corresponding demo within 1 second.

### Implementation for User Story 4

- [x] T036 [US4] Set up TinyUSB C FFI wrapper in `firmware/src/scene/input.rs` — create Rust bindings for TinyUSB USB host HID functions: `tuh_init()`, `tuh_task()`, `tuh_hid_receive_report()`. Add TinyUSB C sources to build via `firmware/build.rs` with `cc` crate
- [x] T037 [US4] Implement keyboard input polling in `firmware/src/scene/input.rs` — `poll_keyboard()` function that calls `tuh_task()` and returns `Option<KeyEvent>`. Map HID keycodes for '1' (0x1E), '2' (0x1F), '3' (0x20) to `DemoSelect` enum
- [x] T038 [US4] Integrate keyboard input into Core 0 main loop in `firmware/src/main.rs` — call `poll_keyboard()` each iteration. On key 1/2/3: call `scene.switch_demo()`, which sets `active_demo` and queues any initialization commands (e.g., texture upload for US2). Ignore invalid keys. Handle "no keyboard" case (no-op)
- [x] T039 [US4] Implement demo transition logic in `firmware/src/scene/mod.rs` — `switch_demo()` completes current frame, then on next frame generates init commands for new demo (texture upload if TexturedTriangle, z-buffer config if Teapot) followed by normal rendering

**Checkpoint**: US4 complete — USB keyboard switches demos. System works with or without keyboard.

---

## Phase 7: User Story 5 — Dual-Core Render Pipeline (Priority: P5)

**Goal**: Partition work across two cores so rendering doesn't block input handling. Validate that input responsiveness remains consistent under rendering load.

**Independent Test**: Run teapot demo at full load, press demo switch key, confirm response within 500 ms. Measure CPU utilization ≤80% per core via defmt profiling.

### Implementation for User Story 5

- [x] T040 [US5] Refactor Core 0 to be non-blocking in `firmware/src/main.rs` — ensure scene update (animation, input polling) runs independently of render command generation. Use SPSC queue backpressure (blocking enqueue) but structure the loop so input is polled before each enqueue attempt
- [x] T041 [US5] Add defmt performance counters in `firmware/src/core1.rs` — track frame time (vsync-to-vsync), render time (command processing), idle time (waiting for commands). Log FPS and utilization periodically via defmt
- [x] T042 [US5] Add defmt performance counters in `firmware/src/main.rs` — track scene update time, queue depth at enqueue, time spent blocked on full queue. Log Core 0 utilization periodically
- [x] T043 [US5] Tune SPSC queue capacity in `firmware/src/render/mod.rs` — set queue depth to accommodate at least 1 full teapot frame (~34 commands). Verify no queue stalls under normal operation via defmt logs

**Checkpoint**: US5 complete — Both cores run concurrently, input stays responsive under load, utilization ≤80% per core.

---

## Phase 8: User Story 6 — Asynchronous GPU Communication (Priority: P6)

**Goal**: Use DMA for flash-to-RAM data pre-fetch so the render core doesn't stall waiting for data loads. Optionally, explore async SPI transmission.

**Independent Test**: Run teapot demo, compare render core idle time with and without DMA pre-fetch. Core should spend <50% time waiting for transfers.

### Implementation for User Story 6

- [x] T044 [US6] Implement DMA flash-to-RAM pre-fetch in `firmware/src/render/commands.rs` — use `rp235x-hal::dma` to asynchronously load mesh patch data from flash to a working SRAM buffer while the previous patch is being processed. Double-buffer the working buffers
- [x] T045 [US6] Add DMA transfer management to Core 1 render loop in `firmware/src/core1.rs` — start DMA for next patch data while processing current patch. Check DMA completion before processing next patch. Fall back to blocking copy if DMA is unavailable
- [x] T046 [US6] Add defmt profiling for DMA in `firmware/src/core1.rs` — measure time spent waiting for DMA vs processing. Log transfer throughput and idle percentage
- [x] T047 [US6] (Stretch) Investigate async SPI transmission in `firmware/src/gpu/mod.rs` — prototype DMA-to-SPI with interrupt-based CS toggling between 9-byte commands. Document findings and feasibility in code comments. Only integrate if flow control (CMD_FULL) can be handled reliably

**Checkpoint**: US6 complete — DMA pre-fetch reduces render core stall time. Async SPI documented as feasible/infeasible.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [x] T048 [P] Verify all edge cases from spec in `firmware/src/` — GPU not detected (LED blink halt), invalid key press (ignored), no keyboard (default demo starts), queue full (backpressure blocks), demo switch mid-frame (completes current frame first)
- [x] T049 [P] Review and optimize memory usage across all modules — verify SRAM budget (520 KB): stack sizes, queue buffers, working buffers. Ensure mesh/texture data is in flash (const), not copied to SRAM unnecessarily
- [x] T050 Run quickstart.md validation — follow the build/flash/verify steps end-to-end on hardware. Confirm all 3 demos work, keyboard switching works, GPU init failure is handled
- [x] T051 Final defmt log cleanup — remove verbose debug logging, keep key metrics (FPS, utilization, queue depth). Set `DEFMT_LOG=info` for release builds

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion — BLOCKS all user stories
- **US1 (Phase 3)**: Depends on Foundational — first runnable milestone
- **US2 (Phase 4)**: Depends on Foundational. Uses `gpu_submit_triangle()` from US1 but can be implemented independently with the foundational GPU driver
- **US3 (Phase 5)**: Depends on Foundational. Uses ClearFramebuffer and triangle submission from US1/US2 but the core new work (transforms, lighting, mesh patches) is independent
- **US4 (Phase 6)**: Depends on Foundational + at least US1 (needs a demo to switch to)
- **US5 (Phase 7)**: Depends on US1 + US3 (needs rendering load to measure dual-core behavior)
- **US6 (Phase 8)**: Depends on US3 (needs mesh-heavy workload to benefit from DMA)
- **Polish (Phase 9)**: Depends on all desired user stories being complete

### User Story Dependencies

```
Phase 1: Setup
    │
Phase 2: Foundational (BLOCKS ALL)
    │
    ├──▶ Phase 3: US1 - Gouraud Triangle (MVP) ──────────────────────┐
    │                                                                 │
    ├──▶ Phase 4: US2 - Textured Triangle (can parallel with US1)    │
    │                                                                 │
    ├──▶ Phase 5: US3 - Spinning Teapot (can parallel with US1/US2)  │
    │         │                                                       │
    │         └──▶ Phase 8: US6 - Async DMA (needs US3 mesh load)    │
    │                                                                 │
    └──▶ Phase 6: US4 - Keyboard (needs at least US1) ──┐           │
                                                          │           │
         Phase 7: US5 - Dual-Core (needs US1 + US3) ◀───┘           │
                                                                      │
         Phase 9: Polish ◀────────────────────────────────────────────┘
```

### Within Each User Story

1. Data/asset tasks (if any) can run in parallel [P]
2. Core implementation tasks are sequential (depends on data)
3. Integration into Core 0/Core 1 loops is last

### Parallel Opportunities

**Phase 2 (Foundational)**:
- T007 (fixed-point), T008 (packing tests) can run in parallel with T006 (registers)

**Phase 5 (US3 — Teapot)** has the most parallelism:
- T027 (teapot mesh data), T028 (transforms), T029 (lighting), T030 (transform tests), T031 (lighting tests) — all in different files, can run in parallel

**Cross-story parallelism**:
- US1, US2, and US3 core implementations can proceed in parallel after Foundational phase, since they touch different modules

---

## Parallel Example: User Story 3 (Teapot)

```
# These can all run in parallel (different files, no dependencies):
T027: Create teapot mesh data in firmware/src/assets/teapot.rs
T028: Implement transform pipeline in firmware/src/render/transform.rs
T029: Implement Gouraud lighting in firmware/src/render/lighting.rs
T030: Write transform tests in firmware/tests/transform_tests.rs
T031: Write lighting tests in firmware/tests/lighting_tests.rs

# Then sequentially:
T032: Implement RenderMeshPatch execution (depends on T028, T029)
T033: Define teapot demo scene (depends on T027)
T034: Core 0 teapot rendering path (depends on T032, T033)
T035: Core 1 depth testing config (depends on T032)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup → project builds
2. Complete Phase 2: Foundational → GPU driver works, registers defined
3. Complete Phase 3: US1 → **Gouraud triangle on screen**
4. **STOP and VALIDATE**: Confirm triangle renders at ≥30 FPS, no tearing, stable for 60 seconds
5. This proves the entire pipeline: SPI, GPU init, register writes, double buffering, vsync

### Incremental Delivery

1. Setup + Foundational → project compiles and GPU responds
2. US1 → Gouraud triangle on screen (MVP!)
3. US2 → Textured triangle validates texture upload
4. US3 → Spinning teapot validates full 3D pipeline
5. US4 → Keyboard switching enables demo presentations
6. US5 → Dual-core profiling validates performance targets
7. US6 → DMA optimization maximizes throughput

### Key Risk: Triangle Strip Registers

FR-008 requires GPU register changes (VERTEX_NODRAW/VERTEX_DRAW for strip restart). If these are not yet available in the GPU, fall back to individual triangle submission (3 vertices per triangle, no strip optimization). This works for all demos but is less efficient. The GPU register update can be done in parallel as a separate spec/task.

---

## Notes

- [P] tasks = different files, no dependencies on incomplete tasks
- [Story] label maps task to specific user story for traceability
- Each user story is independently completable and testable after Foundational phase
- Commit after each task or logical group
- Stop at any checkpoint to validate the story independently
- All mesh and texture data must be `const` (stored in flash, not SRAM)
- Pin assignments in quickstart.md are preliminary — adjust in T004/T009 if hardware differs
