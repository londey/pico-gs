# REQ-202: Asset Build Orchestration

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirements

**REQ-202.1:** When invoked as a CLI tool, the system SHALL provide `texture` and `mesh` subcommands accepting an input file path, an output directory, and (for mesh) patch configuration arguments, and SHALL convert the specified asset to the appropriate GPU-compatible output files.

**REQ-202.2:** When invoked as a library via the `build_assets` function, the system SHALL scan a source directory for `textures/*.png` and `meshes/*.obj` files, convert all discovered assets, and generate output files in the configured output directory.

**REQ-202.3:** When converting a texture asset, the system SHALL emit a `.bin` file containing encoded pixel data and a `.rs` file defining width, height, format, and data constants using `include_bytes!`.

**REQ-202.4:** When converting a mesh asset, the system SHALL emit per-patch `.bin` files each containing a contiguous SoA blob of quantized vertex data and indices per INT-031, with corresponding `.rs` files defining vertex count, entry count, AABB, and data constants, plus a mesh-level descriptor with overall AABB, patch count, and MeshPatchDescriptor array.

**REQ-202.5:** When generating output for a batch of assets, the system SHALL produce a master `mod.rs` that includes all generated `.rs` files in alphabetically sorted order for deterministic output.

**REQ-202.6:** When processing a batch of assets, the system SHALL detect identifier collisions across all assets before generating any output files, and SHALL report all collisions with a descriptive error message.

## Rationale

The dual CLI/library interface supports both interactive single-asset conversion during development and automated batch processing via `build.rs` integration. Emitting separate binary files per attribute array allows the firmware to load each vertex attribute stream independently, matching the GPU's split-attribute buffer layout. The `include_bytes!` pattern embeds asset data directly into the firmware binary at compile time, avoiding runtime file I/O on the embedded target. Deterministic output ordering and identifier collision detection ensure reproducible, conflict-free builds.

## Parent Requirements

- REQ-TBD-GAME-DATA (Game Data Preparation/Import)

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
