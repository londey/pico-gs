# REQ-201: OBJ Mesh Processing

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL parse Wavefront OBJ files, triangulate all faces, merge multiple objects/groups into a unified vertex and index list, and split the resulting geometry into GPU-compatible patches. Each patch SHALL contain at most a configurable maximum number of vertices and indices (defaulting to 16 vertices and 32 indices). Vertex data SHALL include position (vec3), texture coordinates (vec2), and normal (vec3) attributes, with missing UVs or normals defaulting to zero. After splitting, the system SHALL quantize vertex data into a per-patch SoA binary blob per INT-031: positions as u16 using mesh-wide AABB quantization, normals as i16 1:15 signed fixed-point, and UVs as i16 1:2:13 signed fixed-point. The splitter SHALL perform triangle strip optimization and encode indices as packed u8 strip command entries (4-bit vertex index + 2-bit kick control mapping to INT-010 VERTEX registers + 2 spare bits). The splitter SHALL compute per-patch AABBs and an overall mesh AABB from vertex positions; the mesh-wide AABB SHALL serve as the quantization coordinate system for all patches. The splitting algorithm SHALL produce deterministic output for reproducible builds.

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
