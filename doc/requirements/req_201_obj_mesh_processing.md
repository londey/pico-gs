# REQ-201: OBJ Mesh Processing

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirements

**REQ-201.1:** When the asset build tool is given a Wavefront OBJ file as input, it SHALL parse the file, triangulate all polygonal faces, and merge all objects and groups into a unified vertex and index list.

**REQ-201.2:** When building a unified mesh from an OBJ file, the system SHALL include position (vec3), texture coordinate (vec2), and normal (vec3) per-vertex attributes, defaulting missing UVs and normals to zero vectors.

**REQ-201.3:** When producing GPU-compatible geometry from an OBJ file, the system SHALL split the unified mesh into patches such that each patch contains at most a configurable maximum number of vertices and indices, with defaults of 16 vertices and 32 indices.

**REQ-201.4:** When encoding a mesh patch for GPU upload, the system SHALL quantize vertex data into a per-patch SoA binary blob per INT-031, with positions encoded as u16 using the mesh-wide AABB quantization coordinate system, normals as i16 1:15 signed fixed-point, and UVs as i16 1:2:13 signed fixed-point.

**REQ-201.5:** When encoding mesh patch indices, the system SHALL perform triangle strip optimization and encode strip entries as packed u8 commands (4-bit vertex index, 2-bit kick control mapping to INT-010 VERTEX registers, 2 spare bits set to zero).

**REQ-201.6:** When splitting a mesh, the system SHALL compute a per-patch AABB and an overall mesh-wide AABB from the original float vertex positions; the mesh-wide AABB SHALL serve as the shared quantization coordinate system for all patches in that mesh.

**REQ-201.7:** When the asset build tool processes an OBJ file, it SHALL produce deterministic binary output across repeated invocations given the same input.

## Rationale

The GPU hardware has fixed-size vertex and index buffer limits per draw call, requiring large meshes to be partitioned into bounded patches at build time. Triangulation ensures all geometry uses a uniform triangle primitive. Merging multiple OBJ groups simplifies the asset pipeline by producing a single mesh asset per file. Deterministic splitting (via BTreeMap for vertex mapping) ensures reproducible binary output across builds.

## Parent Requirements

- REQ-TBD-GAME-DATA (Game Data Preparation/Import)

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
