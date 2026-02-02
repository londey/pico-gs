# Implementation Plan: Asset Data Preparation Tool

**Branch**: `003-asset-data-prep` | **Date**: 2026-02-01 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/003-asset-data-prep/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Build a Rust library crate that converts PNG textures to RGBA8888 GPU format and OBJ meshes to vertex patch data. The library is used as a `[build-dependency]` by host_app, invoked via `build.rs` during `cargo build`. It reads source assets from `host_app/assets/`, converts them, and writes Rust const arrays with binary data files to Cargo's `OUT_DIR` for inclusion via `include!()`. The tool validates power-of-two texture dimensions (8×8 to 1024×1024), automatically splits meshes into patches (≤16 vertices, ≤32 indices), and generates firmware-compatible output with include_bytes!() references. An optional CLI binary wraps the library for manual/debug use.

## Technical Context

**Language/Version**: Rust stable (1.75+)
**Primary Dependencies**: PNG decoding library, OBJ file parser
**Storage**: File I/O (input: .png/.obj files from host_app/assets/, output: .rs source files + .bin data files to OUT_DIR)
**Build Integration**: `[build-dependency]` of host_app, invoked by build.rs during `cargo build`
**Testing**: cargo test
**Target Platform**: Library compiles and runs on development machine (host target) as a build-dependency; outputs data for RP2350 embedded target
**Project Type**: Library crate with optional CLI binary in workspace
**Performance Goals**: PNG conversion <1s, OBJ conversion <2s, full asset set (10 textures + 5 meshes) <10s
**Constraints**: Generated data stored in flash (4 MB total budget), zero runtime RAM overhead, outputs must be no_std compatible
**Scale/Scope**: Typical game content (10-20 textures up to 1024×1024, 5-10 meshes up to ~1000 vertices each)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Article V: Test-First Development** ✅ PASS
- Unit tests for PNG validation (dimensions, format conversion)
- Unit tests for OBJ parsing (positions, UVs, normals, face triangulation)
- Unit tests for mesh patch splitting algorithm
- Integration tests for end-to-end conversion (PNG → binary, OBJ → patches)
- Contract tests for generated Rust output (compiles in firmware, correct types)

**Article VI: Incremental Delivery** ✅ PASS
- Milestone 1: PNG to RGBA8888 conversion (US-1, validates file I/O and format conversion)
- Milestone 2: OBJ to mesh patches (US-2, validates geometry processing and splitting)
- Milestone 3: Rust output generation (US-3, validates firmware integration)
- Each milestone independently testable and valuable

**Article VII: Simplicity Gate** ✅ PASS
- In scope: PNG/OBJ conversion, RGBA8888 output, patch splitting, basic validation
- Out of scope: Compressed textures, mipmaps, LOD generation, mesh optimization, GUI, batch parallel processing
- Core goal: Convert source assets to GPU-compatible format for firmware inclusion

**Article VIII: Documentation as Artifact** ✅ PASS
- Feature spec with requirements, user stories, success criteria
- Implementation plan (this file) with technical context and milestones
- Data model for entities (texture assets, mesh patches, vertex data)
- Generated output includes comments documenting asset metadata and memory requirements

**Article X: Rust Code Standards** ✅ PASS
- Modern module organization (`<module_name>.rs` style)
- Error handling with `Result<T, E>` and `?` operator (no unwrap/expect in production)
- Use `thiserror` for custom error types (library crate)
- Use `log` crate for progress output (no println! except in main CLI)
- Rustdoc comments for all public items
- Build verification: `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`, `cargo build --release`, `cargo deny check`, `cargo audit`
- Dependencies with `default-features = false` and explicit features

**Not Applicable:**
- Articles I-IV, IX: FPGA/GPU-specific (not applicable to build-time tooling)
- Article XI: Verilog standards (not applicable to Rust code)

## Project Structure

### Documentation (this feature)

```text
specs/003-asset-data-prep/
├── plan.md              # This file (implementation plan)
├── spec.md              # Feature specification
├── research.md          # Phase 0: Technology selections and decisions
├── data-model.md        # Phase 1: Core types and transformation pipeline
├── quickstart.md        # Phase 1: User guide for tool usage
├── contracts/           # Phase 1: CLI and output format specifications
│   ├── cli-interface.md     # Command-line interface contract
│   └── output-format.md     # Binary and Rust output format contract
└── tasks.md             # Phase 2: Implementation tasks (existing)
```

### Source Code (repository root)

```text
pico-gs/
├── asset_build_tool/        # Cargo workspace member (library + optional CLI)
│   ├── Cargo.toml           # Package manifest
│   ├── src/
│   │   ├── lib.rs           # Public library API (build_assets, convert_texture, convert_mesh)
│   │   ├── main.rs          # Optional CLI entry point (thin wrapper over library)
│   │   ├── texture.rs       # PNG to RGBA8888 conversion
│   │   ├── mesh.rs          # OBJ parsing and validation
│   │   ├── patch.rs         # Mesh patch splitting algorithm
│   │   ├── codegen.rs       # Rust wrapper and binary file generation
│   │   ├── identifier.rs    # Filename to Rust identifier conversion
│   │   └── error.rs         # Error types (thiserror)
│   └── tests/
│       ├── texture_tests.rs # Unit tests for texture conversion
│       ├── mesh_tests.rs    # Unit tests for mesh parsing
│       ├── patch_tests.rs   # Unit tests for patch splitting
│       ├── integration_tests.rs # End-to-end library API tests
│       └── fixtures/        # Test assets
│           ├── valid_256x256.png
│           ├── invalid_300x200.png
│           ├── cube.obj     # Simple 8-vertex cube
│           └── teapot.obj   # Complex ~1000-vertex mesh
│
├── host_app/                # Existing firmware project
│   ├── Cargo.toml           # [build-dependencies] includes asset_build_tool
│   ├── build.rs             # Invokes asset_build_tool library to convert assets → OUT_DIR
│   ├── assets/              # Source assets (committed to git)
│   │   ├── textures/
│   │   │   └── *.png        # Original PNG files
│   │   └── meshes/
│   │       └── *.obj        # Original OBJ files
│   └── src/
│       ├── assets/
│       │   └── mod.rs       # include!(concat!(env!("OUT_DIR"), "/assets/mod.rs"))
│       └── ...
│
├── Cargo.toml               # Workspace root (both members)
└── build.sh                 # Simplified (no asset orchestration needed)
```

**Structure Decision**: Library crate with optional CLI binary in Cargo workspace

The `asset_build_tool` crate is a workspace member that operates primarily as a library. It is listed as a `[build-dependency]` of `host_app`, and `host_app/build.rs` calls its public API to convert all source assets from `host_app/assets/` into `OUT_DIR`. The firmware includes generated code via `include!(concat!(env!("OUT_DIR"), "/assets/mod.rs"))`.

This structure integrates cleanly with the existing workspace:
- No impact on `spi_gpu/` (FPGA RTL)
- `host_app` gains build.rs and source assets directory
- `cargo build -p pico-gs-host` is self-contained (no shell script needed for assets)
- Cargo handles incremental rebuilds via `rerun-if-changed` directives
- Follows standard Rust build.rs pattern for code generation

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| [e.g., 4th project] | [current need] | [why 3 projects insufficient] |
| [e.g., Repository pattern] | [specific problem] | [why direct DB access insufficient] |
