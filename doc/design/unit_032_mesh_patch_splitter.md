# UNIT-032: Mesh Patch Splitter

## Purpose

Mesh splitting with vertex/index limits

## Implements Requirements

- REQ-201 (Unknown)

## Interfaces

### Provides

None

### Consumes

None

### Internal Interfaces

- Called by `obj_converter::load_and_convert()` (UNIT-031) after OBJ geometry is merged.
- Produces `Vec<MeshPatch>` (defined in `types.rs`) which is embedded in `MeshAsset` and consumed by the output generator.

## Design Description

### Inputs

- `vertices: &[VertexData]` — Unified vertex array from the merged OBJ (position, UV, normal per vertex).
- `indices: &[u32]` — Triangle index list (length is a multiple of 3); each value indexes into `vertices`.
- `max_vertices: usize` — Maximum number of unique vertices allowed per patch.
- `max_indices: usize` — Maximum number of indices allowed per patch.

### Outputs

- `Vec<MeshPatch>` — Ordered list of patches. Each `MeshPatch` contains:
  - `vertices: Vec<VertexData>` — Local vertex data (copied from global list, deduplicated within patch).
  - `indices: Vec<u16>` — Local triangle indices (u16 for GPU compatibility), referencing the local vertex array.
  - `patch_index: usize` — Zero-based sequential patch number.

### Internal State

- `current_verts: Vec<VertexData>` — Vertex accumulator for the patch being built.
- `current_indices: Vec<u16>` — Index accumulator for the patch being built.
- `vertex_map: BTreeMap<u32, u16>` — Maps global vertex indices to local patch indices. Uses `BTreeMap` (not `HashMap`) to guarantee deterministic iteration order for reproducible builds.
- `patch_index: usize` — Counter for assigning sequential patch indices.

### Algorithm / Behavior

Greedy sequential triangle-packing algorithm:

1. Iterate over the global index list in chunks of 3 (one triangle per chunk).
2. For each triangle, count how many of its 3 vertices are **new** (not yet in `vertex_map`).
3. Check if adding this triangle would exceed either `max_vertices` or `max_indices` for the current patch.
4. **If limits would be exceeded** and the current patch is non-empty: finalize the current patch (push to results, reset accumulators and `vertex_map`, increment `patch_index`).
5. **Add triangle**: For each of the 3 vertex indices, look up or insert into `vertex_map`. If new, copy the vertex from the global array into `current_verts` and assign the next local index. Push the local index into `current_indices`.
6. After all triangles are processed, finalize the last patch if non-empty.

Key properties:
- Vertices shared between triangles within the same patch are deduplicated (stored once, referenced by multiple indices).
- Vertices shared across patch boundaries are duplicated into each patch that uses them.
- Output is deterministic for identical input (BTreeMap ordering).
- Local indices are u16, supporting up to 65535 vertices per patch.

## Implementation

- `asset_build_tool/src/mesh_patcher.rs`: Main implementation

## Verification

- **Single triangle**: One triangle with generous limits produces exactly one patch with 3 vertices and 3 indices.
- **Vertex limit split**: Two independent triangles (6 unique vertices) with `max_vertices=3` produce 2 patches.
- **Index limit split**: Two triangles with `max_indices=3` produce 2 patches regardless of vertex sharing.
- **Vertex sharing**: Two triangles sharing an edge within one patch produce 4 unique vertices (not 6), confirming deduplication.
- **Determinism**: Running the same input twice produces identical output (patch count, vertex counts, index values).
- **Index validity**: All local indices in every patch are strictly less than that patch's vertex count.

## Design Notes

Migrated from speckit module specification.
