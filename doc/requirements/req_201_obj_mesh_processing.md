# REQ-201: OBJ Mesh Processing

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL parse Wavefront OBJ files, triangulate all faces, merge multiple objects/groups into a unified vertex and index list, and split the resulting geometry into GPU-compatible patches. Each patch SHALL contain at most a configurable maximum number of vertices and indices (defaulting to 16 vertices and 32 indices). Vertex data SHALL include position (vec3), texture coordinates (vec2), and normal (vec3) attributes, with missing UVs or normals defaulting to zero. Patch indices SHALL use u16 values for GPU compatibility, and the splitting algorithm SHALL produce deterministic output for reproducible builds.

## Rationale

The GPU hardware has fixed-size vertex and index buffer limits per draw call, requiring large meshes to be partitioned into bounded patches at build time. Triangulation ensures all geometry uses a uniform triangle primitive. Merging multiple OBJ groups simplifies the asset pipeline by producing a single mesh asset per file. Deterministic splitting (via BTreeMap for vertex mapping) ensures reproducible binary output across builds.

## Parent Requirements

None

## Allocated To

- UNIT-031 (OBJ Parser)
- UNIT-032 (Mesh Patch Splitter)
- UNIT-033 (Codegen Engine)

## Interfaces

- INT-004 (Wavefront OBJ Format)
- INT-031 (Asset Binary Format)
- INT-030 (Asset Tool CLI Interface)

## Verification Method

**Test:** Unit tests verify that a single triangle produces one patch, that exceeding vertex or index limits forces patch splits, that shared vertices are not duplicated within a patch, that all patch-local indices are valid, and that repeated invocations produce identical output. Integration tests confirm end-to-end OBJ loading with triangulation and multi-object merging.

## Notes

The OBJ parser uses the `tobj` crate with `triangulate` and `single_index` options enabled. The greedy sequential patch splitter processes triangles in order and starts a new patch when adding the next triangle would exceed either the vertex or index limit.
