# UNIT-034: Build.rs Orchestrator

## Purpose

Asset pipeline entry point

## Parent Area

- Area 13: Game Data Preparation/Import

## Implements Requirements

- REQ-012.03 (Asset Build Orchestration)

## Interfaces

### Provides

- INT-030 (Asset Tool CLI Interface)

### Consumes

- INT-031 (Asset Binary Format)

### Internal Interfaces

- Calls `png_converter::load_and_convert()` (UNIT-033) for each `.png` file.
- Calls `obj_converter::load_and_convert()` (UNIT-031) for each `.obj` file.
- Calls `identifier::check_collisions()` to detect duplicate Rust identifiers across all assets.
- Calls `output_gen::write_texture_output()`, `output_gen::write_mesh_output()`, and `output_gen::write_mod_rs()` to emit generated files.

## Design Description

### Inputs

**Library API** (`build_assets`):
- `config: &AssetBuildConfig` containing:
  - `source_dir: PathBuf` — Root directory containing `textures/` and `meshes/` subdirectories.
  - `out_dir: PathBuf` — Output directory for generated `.rs` and `.bin` files.
  - `patch_size: usize` — Maximum vertices per mesh patch (default: 16).
  - `index_limit: usize` — Maximum indices per mesh patch (default: 32).

**CLI** (`main.rs`, debug/standalone mode):
- Subcommand `texture`: `--input <PNG>`, `--output <DIR>`.
- Subcommand `mesh`: `--input <OBJ>`, `--output <DIR>`, `--patch-size` (default 16), `--index-limit` (default 32).
- Global flag `--quiet` suppresses non-error output.

### Outputs

- `Result<Vec<GeneratedAsset>, AssetError>` — List of generated assets, each containing `module_name`, `identifier`, `rs_path`, and `source_path`.
- **File-system side effects**:
  - Per-texture: `<id>.rs` (Rust wrapper with `include_bytes!`) + `<id>.bin` (raw RGBA8888).
  - Per-mesh-patch: `<id>_patch<N>.rs` + `_patch<N>.bin` (single SoA blob per INT-031).
  - Master `mod.rs` that `include!`s all generated `.rs` files (sorted for determinism).
- Empty `mod.rs` (no `include!` lines) when no assets are found (per FR-040b).

### Internal State

- `png_files: Vec<PathBuf>` — Sorted list of `.png` files found in `source_dir/textures/`.
- `obj_files: Vec<PathBuf>` — Sorted list of `.obj` files found in `source_dir/meshes/`.
- `generated: Vec<GeneratedAsset>` — Accumulator of metadata for all successfully converted assets.

### Algorithm / Behavior

1. **Prepare output**: Create `out_dir` if it does not exist.
2. **Discover sources**: Scan `source_dir/textures/` for `.png` files and `source_dir/meshes/` for `.obj` files (non-recursive, case-insensitive extension match). Sort each list for deterministic processing.
3. **Collision check**: Compute Rust identifiers for all discovered files and verify uniqueness via `identifier::check_collisions()`. Fail early on collision.
4. **Convert textures**: For each `.png`, call `png_converter::load_and_convert()` then `output_gen::write_texture_output()`. Append returned `GeneratedAsset` entries.
5. **Convert meshes**: For each `.obj`:
   a. Parse, triangulate, merge, split into patches.
   b. Strip optimization: reorder triangles, encode as u8 strip commands.
   c. AABB computation: per-patch and overall mesh bounding boxes.
   d. Quantize vertex data using mesh-wide AABB (u16 positions, i16 normals, i16 UVs) and pack into SoA blobs per INT-031.
   e. Emit per-patch binary blobs and mesh descriptor.
   Log vertex/triangle/patch statistics. Append returned `GeneratedAsset` entries.
6. **Generate mod.rs**: Call `output_gen::write_mod_rs()` to emit the master include file.
7. **Return** the accumulated `Vec<GeneratedAsset>`.

The CLI (`main.rs`) provides single-file conversion commands (`Texture`, `Mesh`) that call `convert_texture()` / `convert_mesh()` convenience wrappers. These skip discovery and collision checks, operating on one file at a time.

## Implementation

- `crates/asset-build-tool/src/lib.rs:build_assets`: Main implementation
- `crates/asset-build-tool/src/main.rs`: CLI entry point (debug/standalone mode)

## Verification

- **Empty source directory**: `build_assets` with no asset files produces an empty `mod.rs` and returns an empty `Vec<GeneratedAsset>`.
- **Texture pipeline**: A single PNG in `textures/` produces the expected `.rs` and `.bin` output files with correct constants and binary size.
- **Mesh pipeline**: A single OBJ in `meshes/` produces per-patch `.rs` and `.bin` files with correct vertex/index counts.
- **Identifier collision**: Two source files that map to the same Rust identifier cause an `AssetError::IdentifierCollision` before any output is written.
- **Determinism**: Running `build_assets` twice on identical inputs produces byte-identical output files.
- **mod.rs correctness**: Generated `mod.rs` contains sorted `include!` directives for all generated `.rs` files and nothing else.

## Design Notes

Migrated from speckit module specification.
