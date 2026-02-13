# REQ-202: Asset Build Orchestration

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL provide both a CLI tool and a library API for converting PNG and OBJ source assets into compiled firmware assets. The CLI SHALL support `texture` and `mesh` subcommands with input path, output directory, and mesh-specific patch configuration arguments. The library API SHALL provide a `build_assets` function that scans a source directory for `textures/*.png` and `meshes/*.obj` files, converts all discovered assets, and generates output files. For each texture, the system SHALL emit a `.bin` file containing raw RGBA8888 pixel data and a `.rs` file defining width, height, and data constants via `include_bytes!`. For each mesh patch, the system SHALL emit `.bin` files for positions, UVs, normals (f32 LE), and indices (u8 packed strip commands per INT-031), plus a `.rs` file defining vertex count, entry count, AABB, and data constants. For each mesh, the system SHALL emit a mesh descriptor with overall AABB, patch count, and MeshPatchDescriptor array. The system SHALL generate a master `mod.rs` that includes all generated `.rs` files, sorted alphabetically for deterministic output. The system SHALL detect identifier collisions across all assets before generating any output.

## Rationale

The dual CLI/library interface supports both interactive single-asset conversion during development and automated batch processing via `build.rs` integration. Emitting separate binary files per attribute array allows the firmware to load each vertex attribute stream independently, matching the GPU's split-attribute buffer layout. The `include_bytes!` pattern embeds asset data directly into the firmware binary at compile time, avoiding runtime file I/O on the embedded target. Deterministic output ordering and identifier collision detection ensure reproducible, conflict-free builds.

## Parent Requirements

None

## Allocated To

- UNIT-033 (Codegen Engine)
- UNIT-034 (Build.rs Orchestrator)

## Interfaces

- INT-030 (Asset Tool CLI)
- INT-031 (Asset Binary Format)

## Verification Method

**Test:** Unit tests verify that texture output produces correctly named `.rs` and `.bin` files with expected sizes and constant definitions, that mesh output produces per-patch binary files for each attribute stream with correct byte counts, that `mod.rs` generation includes all assets in sorted order, and that an empty source directory produces a valid empty `mod.rs`. Integration tests confirm end-to-end CLI invocation for both texture and mesh subcommands.

## Notes

The CLI uses `clap` with subcommands and supports a `--quiet` flag to suppress progress output. Binary data is written in little-endian format (f32 for positions/UVs/normals, u16 for indices), and the generated Rust code references binary files via relative `include_bytes!` paths within the output directory.
