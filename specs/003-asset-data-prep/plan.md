# Implementation Plan: Asset Data Preparation Library

**Branch**: `003-asset-data-prep` | **Date**: 2026-02-03 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/003-asset-data-prep/spec.md`

**Note**: This plan incorporates clarifications from 2026-02-03 session

## Summary

Build a Rust library crate that converts PNG textures to RGBA8888 GPU format and OBJ meshes to vertex patch data. The library is used as a `[build-dependency]` by host_app, invoked via `build.rs` during `cargo build`. It reads source assets from `host_app/assets/`, converts them, and writes Rust const arrays with binary data files to Cargo's `OUT_DIR` for inclusion via `include!()`. The tool validates power-of-two texture dimensions (8×8 to 1024×1024), automatically splits meshes into patches (≤16 vertices, ≤32 indices) using a deterministic algorithm, and generates firmware-compatible output with include_bytes!() references. Build fails on any asset conversion error (fail-fast approach). An optional CLI binary wraps the library for manual/debug use.

## Technical Context

**Language/Version**: Rust stable (1.75+)
**Primary Dependencies**: PNG decoding library (`image` crate), OBJ file parser (`tobj` crate), `thiserror` for errors, `log` for output, `clap` for CLI
**Storage**: File I/O (input: .png/.obj files from host_app/assets/, output: .rs source files + .bin data files to OUT_DIR)
**Build Integration**: `[build-dependency]` of host_app, invoked by build.rs during `cargo build`
**Testing**: cargo test (unit + integration tests)
**Target Platform**: Library compiles and runs on development machine (host target) as a build-dependency; outputs data for RP2350 embedded target
**Project Type**: Library crate with optional CLI binary in Cargo workspace
**Performance Goals**: PNG conversion <1s, OBJ conversion <2s, full asset set (10 textures + 5 meshes) <10s
**Constraints**: Generated data stored in flash (4 MB total budget), zero runtime RAM overhead, outputs must be no_std compatible, deterministic output required for reproducible builds
**Scale/Scope**: Typical game content (10-20 textures up to 1024×1024, 5-10 meshes up to ~1000 vertices each)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Article I: Test-First Development** ✅ PASS
- Unit tests for PNG validation (dimensions, format conversion)
- Unit tests for OBJ parsing (positions, UVs, normals, face triangulation, multiple objects)
- Unit tests for mesh patch splitting algorithm (including determinism verification)
- Unit tests for identifier generation and collision detection
- Integration tests for end-to-end conversion (PNG → binary, OBJ → patches)
- Integration tests for empty directory handling
- Contract tests for generated Rust output (compiles in firmware, correct types)

**Article II: Rust Code Standards** ✅ PASS
- Modern module organization (`<module_name>.rs` style)
- Error handling with `Result<T, E>` and `?` operator (no unwrap/expect in production)
- Use `thiserror` for custom error types (library crate)
- Use `log` crate for progress output (no println! except in main CLI)
- Rustdoc comments for all public items
- Build verification: `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`, `cargo build --release`, `cargo deny check`, `cargo audit`
- Dependencies with `default-features = false` and explicit features

**Article IV: Documentation as Practice** ✅ PASS
- Feature spec with requirements, user stories, success criteria
- Implementation plan (this file) with technical context and milestones
- Data model for entities (texture assets, mesh patches, vertex data)
- API contracts (CLI interface, output format specifications)
- Quickstart guide for developers
- Generated output includes comments documenting asset metadata and memory requirements

**Article V: Incremental Delivery** ✅ PASS
- Milestone 1: PNG to RGBA8888 conversion (US-1, validates file I/O and format conversion)
- Milestone 2: OBJ to mesh patches (US-2, validates geometry processing and splitting)
- Milestone 3: Rust output generation + build.rs integration (US-3, validates firmware integration)
- Each milestone independently testable and valuable

**Article VI: Simplicity Principle** ✅ PASS
- In scope: PNG/OBJ conversion, RGBA8888 output, patch splitting, basic validation, deterministic output, fail-fast errors
- Out of scope: Compressed textures, mipmaps, LOD generation, mesh optimization, GUI, batch parallel processing, separate assets per OBJ object
- Core goal: Convert source assets to GPU-compatible format for firmware inclusion with single `cargo build` command
- Design choices favor simplicity: merge all OBJ objects into one mesh, empty directory succeeds silently, fail on any error

**Not Applicable:**
- Article III: Verilog standards (not applicable to Rust code)

## Project Structure

### Documentation (this feature)

```text
specs/003-asset-data-prep/
├── plan.md              # This file (implementation plan)
├── spec.md              # Feature specification (includes 2026-02-03 clarifications)
├── research.md          # Phase 0: Technology selections and decisions
├── data-model.md        # Phase 1: Core types and transformation pipeline
├── quickstart.md        # Phase 1: Developer guide for using the library
├── contracts/           # Phase 1: Interface specifications
│   ├── cli-interface.md     # Command-line interface contract
│   └── output-format.md     # Binary and Rust output format contract
└── tasks.md             # Phase 2: Implementation tasks (generated by /speckit.tasks)
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
│   │   ├── mesh.rs          # OBJ parsing and validation (merges all objects/groups)
│   │   ├── patch.rs         # Deterministic mesh patch splitting algorithm
│   │   ├── codegen.rs       # Rust wrapper and binary file generation
│   │   ├── identifier.rs    # Filename to Rust identifier conversion + collision detection
│   │   └── error.rs         # Error types (thiserror)
│   └── tests/
│       ├── texture_tests.rs # Unit tests for texture conversion
│       ├── mesh_tests.rs    # Unit tests for mesh parsing
│       ├── patch_tests.rs   # Unit tests for patch splitting + determinism
│       ├── identifier_tests.rs # Unit tests for identifier generation
│       ├── integration_tests.rs # End-to-end library API tests
│       └── fixtures/        # Test assets
│           ├── valid_256x256.png
│           ├── invalid_300x200.png
│           ├── cube.obj     # Simple 8-vertex cube
│           ├── teapot.obj   # Complex ~1000-vertex mesh
│           └── multi_object.obj # OBJ with multiple named objects
│
├── host_app/                # Existing firmware project
│   ├── Cargo.toml           # [build-dependencies] includes asset_build_tool
│   ├── build.rs             # Invokes asset_build_tool::build_assets() to convert assets → OUT_DIR
│   ├── assets/              # Source assets (committed to git, may be empty)
│   │   ├── textures/
│   │   │   └── *.png        # Original PNG files
│   │   └── meshes/
│   │       └── *.obj        # Original OBJ files
│   └── src/
│       ├── assets/
│       │   └── mod.rs       # include!(concat!(env!("OUT_DIR"), "/assets/mod.rs"))
│       └── ...
│
├── Cargo.toml               # Workspace root (includes asset_build_tool member)
└── build.sh                 # Simplified (no asset orchestration steps needed)
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

No violations. All constitutional requirements are satisfied.

## Key Design Decisions (from 2026-02-03 Clarifications)

1. **Empty Directory Handling**: When `host_app/assets/` is empty or contains no .png/.obj files, build succeeds with empty `mod.rs`. This allows firmware builds to proceed during early development.

2. **Error Handling Strategy**: Any asset conversion error fails the firmware build immediately. Errors are propagated via `Result<T, E>` return values, causing build.rs to fail. This catches broken assets during development rather than at runtime.

3. **Deterministic Output**: Patch splitting algorithm must produce identical output for the same input file across multiple runs. This ensures reproducible builds and enables reliable testing via hash comparison.

4. **Identifier Collision Detection**: When different source files sanitize to the same Rust identifier (e.g., "foo@bar.png" and "foo_bar.png" both becoming "FOO_BAR"), the build fails with a clear error listing the conflicting files. This prevents silent data loss.

5. **Multiple OBJ Objects**: When an .obj file contains multiple named objects or groups, all are merged into one unified mesh output. One .obj file produces one asset regardless of internal structure. Developers can split objects into separate files externally if needed.

## Implementation Phases

### Phase 0: Research & Technology Selection
*(Output: research.md)*

Research tasks:
1. PNG decoding library selection: Evaluate `image` crate for no_std compatibility and feature flags
2. OBJ parser selection: Evaluate `tobj` crate for features (triangulation, groups/objects)
3. Deterministic algorithm design: Ensure consistent iteration order (sorted file paths, stable face ordering)
4. Build.rs integration patterns: Research `cargo:rerun-if-changed` best practices
5. Identifier sanitization: Define character mapping rules for Rust identifiers

Decisions to document in research.md:
- Which PNG decoder (likely `image` with `default-features = false, features = ["png"]`)
- Which OBJ parser (likely `tobj` with triangulation enabled)
- How to ensure determinism (sort inputs, stable algorithms, no HashMap iteration)
- Error type hierarchy (top-level AssetError with variants for Io, ImageDecode, ObjParse, etc.)

### Phase 1: Data Model & Contracts
*(Output: data-model.md, contracts/cli-interface.md, contracts/output-format.md, quickstart.md)*

Data model entities:
1. **TextureAsset**: Intermediate representation of converted PNG
2. **MeshAsset**: Intermediate representation of converted OBJ (collection of MeshPatch)
3. **MeshPatch**: Segment of mesh with ≤16 vertices, ≤32 indices
4. **VertexData**: Per-vertex attributes (position, UV, normal)
5. **GeneratedAsset**: Output file metadata (path, identifier, source)

Contracts to define:
1. **CLI Interface**: `texture`, `mesh` subcommands with `--quiet` flag
2. **Library API**: `build_assets()`, `convert_texture()`, `convert_mesh()` signatures
3. **Output Format**: Rust wrapper structure, binary data layout (endianness, alignment)
4. **Error Format**: Error message templates with actionable guidance

### Phase 2: Implementation Tasks
*(Output: tasks.md, generated by /speckit.tasks command)*

Tasks will be generated based on user stories:
- US-1: PNG to RGBA8888 conversion
- US-2: OBJ to mesh patches
- US-3: Build.rs integration

Task phases align with incremental delivery milestones.

## Verification Strategy

### Unit Test Coverage
- Texture conversion: dimensions validation, format conversion (grayscale, indexed, RGBA)
- Mesh parsing: positions, UVs, normals, missing attributes (defaults), face triangulation
- Patch splitting: single-patch meshes, multi-patch meshes, determinism verification
- Identifier generation: sanitization rules, collision detection, parent directory inclusion
- Empty directory: succeeds with empty mod.rs

### Integration Test Coverage
- End-to-end conversion: PNG → .rs + .bin files
- End-to-end conversion: OBJ → .rs + .bin files (multiple patches)
- Build.rs integration: `cargo build -p pico-gs-host` with test assets
- Incremental rebuild: modify one asset, verify only that asset reconverts
- Error propagation: invalid asset fails firmware build

### Contract Test Coverage
- Generated Rust code compiles in firmware context
- Binary data files match expected layout (endianness, alignment)
- const arrays accessible from firmware code
- Type signatures match expectations (e.g., `&[u8]` for texture data)

## Success Criteria Review

All success criteria from spec.md apply:
- SC-001: Single `cargo build -p pico-gs-host` converts all assets ✅
- SC-002: New assets auto-detected without config changes ✅
- SC-003: Incremental builds only reconvert modified assets ✅
- SC-004-006: Performance targets for conversion times ✅
- SC-007-010: Correctness (no data loss, visual fidelity) ✅
- SC-011: No runtime RAM (data in flash) ✅
- SC-012: Actionable error messages ✅
- SC-013: Deterministic mesh splitting ✅ (2026-02-03 clarification)
- SC-014: Simplified build.sh (no asset orchestration) ✅

## Next Steps

1. Run `/speckit.tasks` to generate tasks.md from this plan
2. Begin implementation starting with Phase 1 (Setup) tasks
3. Follow TDD approach: write tests first, ensure they fail, then implement
4. Validate each milestone independently before proceeding
5. Run build verification after each significant change

---

**Plan Status**: Ready for task generation
**Constitution Compliance**: ✅ All articles satisfied
**Blockers**: None
