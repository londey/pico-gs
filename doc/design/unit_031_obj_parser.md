# UNIT-031: OBJ Parser

## Purpose

OBJ file parsing and geometry extraction

## Implements Requirements

- REQ-201 (OBJ Mesh Processing)

## Interfaces

### Provides

None

### Consumes

- INT-004 (Wavefront OBJ Format)

### Internal Interfaces

- Calls `mesh_patcher::split_into_patches()` (UNIT-032) to split merged geometry into bounded patches.
- Calls `identifier::generate_identifier()` to derive a Rust identifier from the source file path.
- Returns `MeshAsset` (defined in `types.rs`) consumed by UNIT-034 and the output generator.

## Design Description

### Inputs

- `path: &Path` — File system path to a `.obj` file.
- `patch_size: usize` — Maximum vertices per mesh patch (passed through to UNIT-032).
- `index_limit: usize` — Maximum indices per mesh patch (passed through to UNIT-032).

### Outputs

- `Result<MeshAsset, AssetError>` — On success, a `MeshAsset` containing:
  - `source` — Original file path.
  - `patches` — `Vec<MeshPatch>` produced by the patch splitter.
  - `identifier` — Uppercased Rust identifier derived from the file path.
  - `original_vertex_count` — Vertex count before patching.
  - `original_triangle_count` — Triangle count after triangulation.
- On failure, an `AssetError::ObjParse` (parse failure) or `AssetError::Validation` (empty geometry).

### Internal State

- `tobj::LoadOptions` — Configured with `triangulate: true` and `single_index: true` for GPU-compatible output.
- `Vec<VertexData>` — Unified vertex list accumulated across all OBJ objects/groups. Each `VertexData` contains `position: [f32; 3]`, `uv: [f32; 2]`, `normal: [f32; 3]`.
- `Vec<u32>` — Unified index list with offsets remapped per-object so indices reference the merged vertex list.
- `vertex_offset: u32` — Running offset tracking the base vertex index for each merged object.

### Algorithm / Behavior

1. **Parse**: Load OBJ via `tobj::load_obj()` with triangulation and single-index mode enabled. Materials are loaded but discarded.
2. **Validate**: Reject files with zero models (empty geometry). Warn when multiple objects/groups are present (all are merged).
3. **Merge** (`merge_models`): Iterate over all `tobj::Model` entries. For each model, extract per-vertex position, UV (defaults to `[0,0]` if absent), and normal (defaults to `[0,0,0]` if absent). Append vertices to the unified list and remap indices by adding `vertex_offset`.
4. **Split**: Delegate to `mesh_patcher::split_into_patches()` to partition unified geometry into GPU-sized patches.
5. **Identify**: Generate a Rust identifier from the file path via `identifier::generate_identifier()`.
6. **Return**: Assemble and return the `MeshAsset`.

## Implementation

- `asset_build_tool/src/obj_converter.rs`: Main implementation

## Verification

- **Empty input**: `merge_models` on an empty model list returns empty vertex/index vecs without error.
- **Parse errors**: Verify `AssetError::ObjParse` is returned for malformed OBJ files.
- **Validation errors**: Verify `AssetError::Validation` is returned when OBJ has no geometry or all meshes have empty positions.
- **Multi-object merge**: Confirm that multiple OBJ groups are merged into a single vertex/index list with correct index remapping.
- **Missing attributes**: Confirm default UV `[0,0]` and normal `[0,0,0]` when attributes are absent, with log warnings.
- **Round-trip correctness**: Verify a known OBJ file produces expected vertex count, triangle count, and patch count.

## Design Notes

Migrated from speckit module specification.
