# INT-004: Wavefront OBJ Format

## Type

External Standard

## External Specification

- **Standard:** Wavefront OBJ Format
- **Reference:** OBJ file format specification for mesh parsing.

## Parties

- **Provider:** External
- **Consumer:** UNIT-031 (OBJ Parser)

## Referenced By

- REQ-201 (OBJ Mesh Processing) — area 13: Game Data Preparation/Import

## Specification

### Overview

This project uses a subset of the Wavefront OBJ Format standard.

### Usage

OBJ file format specification for mesh parsing.

## Project-Specific Usage

### Supported OBJ Directives

The asset build tool (`asset_build_tool`) uses the `tobj` crate and supports only the following subset of OBJ directives:

| Directive | Description                     | Required |
|-----------|---------------------------------|----------|
| `v`       | Vertex position (x, y, z)      | Yes      |
| `vt`      | Texture coordinate (u, v)      | No       |
| `vn`      | Vertex normal (x, y, z)        | No       |
| `f`       | Face definition                 | Yes      |

### Parsing Behavior

- **Triangulation:** Enabled automatically -- polygonal faces (quads, n-gons) are split into triangles by the parser.
- **Single-indexed:** Enabled -- separate position/UV/normal indices are collapsed into a single unified vertex index.
- **Multiple objects/groups:** All objects and groups in the file are merged into a single unified mesh. A warning is logged when merging occurs.

### Default Values for Missing Attributes

| Attribute          | Default Value         |
|--------------------|-----------------------|
| Texture coordinate | `(0.0, 0.0)`         |
| Normal             | `(0.0, 0.0, 0.0)`   |

A warning is logged per mesh when UVs or normals are absent.

### Output

Parsed vertices (position, UV, normal) and triangle indices are passed to the mesh patcher, which splits them into GPU-uploadable patches. Materials from `.mtl` files are loaded but currently unused.

## Constraints

See external specification for full details.

## Notes

This is an external standard. Refer to the official specification for complete details.
