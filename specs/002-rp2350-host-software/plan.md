# Implementation Plan: RP2350 Host Software

**Branch**: `002-rp2350-host-software` | **Date**: 2026-01-30 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/002-rp2350-host-software/spec.md`

## Summary

Host firmware for the RP2350 (Pico 2) that drives the SPI GPU to render 3D demos. Written in Rust targeting Cortex-M33 cores with hardware FPU. Dual-core architecture: Core 0 manages the scene graph, USB keyboard input, and render command generation; Core 1 executes render commands (transform, lighting, GPU submission) via SPI with flow control. Three demos: Gouraud-shaded triangle, textured triangle, spinning Utah Teapot. Target: ≥30 FPS, ≤80% CPU utilization per core.

## Technical Context

**Language/Version**: Rust (stable), target `thumbv8m.main-none-eabihf` (Cortex-M33 with hardware FPU)
**Primary Dependencies**: `rp235x-hal` ~0.2.x, `cortex-m-rt` 0.7.x, `heapless` 0.8.x, `glam` 0.29.x (no_std), `fixed` 1.28.x, `defmt` 0.3.x, TinyUSB (C FFI for USB host)
**Storage**: Flash (4 MB) for mesh data, texture data, and firmware binary; RP2350 SRAM (520 KB) for runtime state
**Testing**: `cargo test` (host-side unit tests for math/packing), on-target hardware validation, `defmt` logging for performance metrics
**Target Platform**: Raspberry Pi Pico 2 (RP2350) bare-metal embedded, connected to ICEpi Zero SPI GPU
**Project Type**: Single embedded firmware crate
**Performance Goals**: ≥30 FPS all demos, ≤80% CPU per core, <2s boot to display, <1s demo switch
**Constraints**: 520 KB SRAM, 4 MB flash, SPI at 25 MHz (72-bit transactions), GPU FIFO depth 16 commands
**Scale/Scope**: 3 demos, ~16 source files, single firmware binary

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Article | Applies to Host SW? | Status | Notes |
|---------|---------------------|--------|-------|
| I: Open Toolchain | Partially | ✅ PASS | Rust toolchain is open source. No vendor-specific tools required. |
| II: Resource Budget | No (FPGA resources) | N/A | Host firmware does not consume FPGA resources. |
| III: Bandwidth-First | Indirectly | ✅ PASS | Host must respect GPU SRAM bandwidth. Flow control via CMD_FULL ensures host doesn't overwhelm GPU. |
| IV: Interface Stability | Yes | ✅ PASS | Host implements against the v2.0 register map contract. GPU driver uses register constants matching the spec. |
| V: Test-First | Yes | ✅ PASS | Plan includes unit tests for math/packing, on-target hardware tests. |
| VI: Incremental Delivery | Yes | ✅ PASS | User stories P1-P6 map to incremental milestones: P1 (Gouraud triangle) is MVP, each subsequent story adds capability. |
| VII: Simplicity Gate | Yes | ✅ PASS | Feature set is constrained to 3 demos. No programmable shaders, no complex scene management. |
| VIII: Documentation | Yes | ✅ PASS | Spec, data model, contracts, quickstart, and register constants are all documented. |
| IX: Host Responsibility | Yes | ✅ PASS | Host performs all geometry processing per constitution: MVP transforms, clipping, perspective division, back-face culling, scene management. GPU receives screen-space vertices only. |

**Post-Phase 1 re-check**: No violations. The design aligns with all applicable constitution articles.

### Constitution-Driven Dependency

**Article IX** defines a clear boundary: the host is responsible for model/view/projection transforms, clipping, perspective division, back-face culling, and scene management. The GPU is a rasterizer only. FR-007 and FR-008 implement this boundary.

**Article IV** requires that the host GPU driver use the v2.0 register addresses and bit formats exactly as specified. The `registers.rs` module must define constants matching the register map contract.

## Project Structure

### Documentation (this feature)

```text
specs/002-rp2350-host-software/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Technology research and decisions
├── data-model.md        # Entity definitions and relationships
├── quickstart.md        # Build, flash, and verify guide
├── contracts/
│   ├── gpu-driver.md    # GPU SPI driver API contract
│   └── render-commands.md # Render command queue contract
├── checklists/
│   └── requirements.md  # Specification quality checklist
└── tasks.md             # Task breakdown (created by /speckit.tasks)
```

### Source Code (repository root)

```text
firmware/
├── Cargo.toml
├── build.rs                 # (optional) asset pre-processing
├── memory.x                 # Linker memory layout for RP2350
├── .cargo/
│   └── config.toml          # Target, runner (probe-rs), rustflags
├── src/
│   ├── main.rs              # Entry point, Core 0 main loop
│   ├── core1.rs             # Core 1 entry, render loop
│   ├── gpu/
│   │   ├── mod.rs           # GPU driver: init, write, read, flow control
│   │   ├── registers.rs     # Register addresses and bit-field constants (v2.0)
│   │   └── vertex.rs        # GpuVertex packing (f32 → fixed-point)
│   ├── render/
│   │   ├── mod.rs           # Render command enum and queue types
│   │   ├── transform.rs     # MVP transform, viewport mapping, perspective divide
│   │   ├── lighting.rs      # Gouraud lighting (4 directional + ambient)
│   │   └── commands.rs      # Command execution: mesh render, clear, texture upload
│   ├── scene/
│   │   ├── mod.rs           # Scene graph, demo state machine
│   │   ├── demos.rs         # Demo definitions and per-frame update logic
│   │   └── input.rs         # USB keyboard input (TinyUSB FFI wrapper)
│   ├── math/
│   │   └── fixed.rs         # f32 ↔ fixed-point conversion (12.4, 1.15, 25-bit Z)
│   └── assets/
│       ├── teapot.rs        # Utah Teapot mesh (const arrays in flash)
│       └── textures.rs      # Demo texture data (const arrays in flash)
└── tests/
    ├── transform_tests.rs   # MVP matrix, viewport mapping
    ├── lighting_tests.rs    # Gouraud shading correctness
    └── packing_tests.rs     # Fixed-point conversion, register packing
```

**Structure Decision**: Single Cargo crate under `firmware/`. Module layout mirrors the dual-core architecture: `scene/` (Core 0), `render/` + `gpu/` (Core 1), shared types in `render/mod.rs`.

## Complexity Tracking

No constitution violations to justify. The design is straightforward:
- Single crate, no workspace complexity
- Direct HAL access, no abstraction layers beyond the GPU driver
- Lock-free SPSC queue (off-the-shelf `heapless` crate)
- Standard 3D math pipeline (MVP × vertex, Gouraud lighting)
