# Implementation Plan: Asset Data Preparation Tool

**Branch**: `003-asset-data-prep` | **Date**: 2026-01-31 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/003-asset-data-prep/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Build a command-line tool that converts PNG images to RGBA8888 texture data and OBJ mesh files to GPU-compatible patch format (≤16 vertices, ≤32 indices per patch), generating Rust source files with `include_bytes!()` macros and binary data files for embedding in RP2350 firmware. The tool validates input formats, automatically splits large meshes, derives unique identifiers from filenames with parent directory prefixes, and provides progress output with a `--quiet` flag for CI/CD integration.

## Technical Context

**Language/Version**: Rust stable (1.75+)
**Primary Dependencies**:
- Image decoding: `image` crate (PNG support)
- OBJ parsing: `tobj` or `wavefront_obj` crate
- CLI framework: `clap` (v4.x) for argument parsing
- Binary I/O: std::fs, std::io

**Storage**: File I/O (input: .png/.obj files, output: .rs source files + .bin data files)
**Testing**: `cargo test` with unit tests for parsing, conversion, and output generation
**Target Platform**: Development machines (Linux, macOS, Windows) - build-time tool, not embedded
**Project Type**: Single CLI application
**Performance Goals**:
- PNG conversion: <1 second for 1024×1024 textures
- OBJ conversion: <2 seconds for ~1000 vertex meshes
- Batch processing: <10 seconds for 10 textures + 5 meshes

**Constraints**:
- Output must be valid Rust syntax (compile without errors)
- Binary data must be little-endian f32/u16 for RP2350 compatibility
- Identifiers must be unique and valid Rust names
- No GUI required (CLI only)

**Scale/Scope**:
- Typical asset set: 10-20 textures + 5-10 meshes
- Max texture size: 1024×1024 RGBA8
- Max mesh size: ~10k vertices (split into hundreds of patches)
- Output size: ~4 MB total (RP2350 flash limit)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Applicability**: The project constitution targets the ICEpi GPU RTL development. This feature is a **host-side build tool**, not FPGA hardware, so most articles do not apply directly. However, we check for spirit-of-the-law alignment:

| Article | Applies? | Check | Status |
|---------|----------|-------|--------|
| I: Open Toolchain Mandate | Indirect | Tool uses Rust (open toolchain), generates data for open GPU | ✅ PASS |
| II: Resource Budget Discipline | No | Not FPGA resource; tool runs on dev machine | N/A |
| III: Bandwidth-First Design | No | Not FPGA hardware | N/A |
| IV: Interface Stability Covenant | Yes | Output format is contract with firmware | ✅ PASS - Binary format specified with versioning path |
| V: Test-First Development | Yes | CLI tool requires testing | ✅ PASS - cargo test planned |
| VI: Incremental Delivery | Yes | Build tool should deliver value incrementally | ✅ PASS - Texture conversion (P1) → Mesh conversion (P2) → Output integration (P3) |
| VII: Simplicity Gate | Yes | Avoid feature creep in build tools | ✅ PASS - Compressed textures, optimization deferred (see Out of Scope) |
| VIII: Documentation as Artifact | Yes | Tool needs docs for users | ✅ PASS - quickstart.md planned |
| IX: Host Responsibility Boundary | Yes | Tool prepares data, GPU renders it | ✅ PASS - Clear separation: tool converts, firmware transforms |

**Overall**: ✅ **PASS** - No constitution violations. Tool aligns with project philosophy of incremental, tested, well-documented development.

## Project Structure

### Documentation (this feature)

```text
specs/003-asset-data-prep/
├── spec.md              # Feature specification (completed via /speckit.specify)
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (library choices, format decisions)
├── data-model.md        # Phase 1 output (asset structures, file formats)
├── quickstart.md        # Phase 1 output (how to use the tool)
├── contracts/           # Phase 1 output (CLI interface, output format)
│   ├── cli-interface.md
│   └── output-format.md
├── checklists/
│   └── requirements.md  # Validation checklist (from /speckit.specify)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created yet)
```

### Source Code (repository root)

```text
# CLI tool structure
tools/asset-prep/        # New directory for the asset preparation tool
├── Cargo.toml
├── src/
│   ├── main.rs          # CLI entry point, argument parsing
│   ├── lib.rs           # Library API for testing
│   ├── png_converter.rs # PNG → RGBA8888 conversion
│   ├── obj_converter.rs # OBJ → mesh patch conversion
│   ├── mesh_patcher.rs  # Mesh splitting algorithm
│   ├── output_gen.rs    # Rust source + binary file generation
│   ├── identifier.rs    # Filename → Rust identifier sanitization
│   └── types.rs         # Shared types (TextureAsset, MeshPatch)
└── tests/
    ├── integration/
    │   ├── png_conversion_test.rs
    │   ├── obj_conversion_test.rs
    │   └── end_to_end_test.rs
    └── fixtures/
        ├── test-texture.png
        ├── test-cube.obj
        └── test-teapot.obj

# Integration with firmware
firmware/                # Existing firmware directory (002-rp2350-host-software)
├── assets/              # Generated asset files (output from tool)
│   ├── textures/        # Generated .rs + .bin files for textures
│   └── meshes/          # Generated .rs + .bin files for meshes
└── src/
    └── assets.rs        # Include point for generated assets
```

**Structure Decision**: CLI tool in `tools/asset-prep/` as standalone Rust project. Keeps tool separate from firmware code, allowing independent versioning and testing. Generated output (`firmware/assets/`) is included in firmware build via `mod` declarations. This matches Rust conventions for workspace projects with multiple crates.

## Complexity Tracking

**No violations recorded** - all constitution checks passed.

---

## Phase 0: Research & Technology Selection

**Objective**: Resolve all technical unknowns and select concrete dependencies.

### Research Tasks

1. **PNG Decoding Library Evaluation**
   - **Question**: Which Rust crate provides reliable PNG decoding with RGBA8 support?
   - **Options**: `image` (most popular), `png` (lower-level), `lodepng` (C bindings)
   - **Criteria**: Power-of-two validation support, color space handling, performance

2. **OBJ Parser Library Evaluation**
   - **Question**: Which Rust crate handles Wavefront OBJ format with face triangulation?
   - **Options**: `tobj`, `wavefront_obj`, custom parser
   - **Criteria**: Quad/polygon support, normal/UV parsing, error handling

3. **Mesh Splitting Algorithm Design**
   - **Question**: How to efficiently split meshes into 16-vertex patches with minimal vertex duplication?
   - **Approach**: Greedy sequential (spec FR-018) vs. graph partitioning
   - **Trade-off**: Simplicity vs. optimization

4. **Binary Output Format**
   - **Question**: Should binary files use custom header or raw data?
   - **Options**: Raw f32/u16 arrays (simpler) vs. structured format with metadata
   - **Criteria**: include_bytes!() compatibility, debuggability

5. **CLI Framework Selection**
   - **Question**: Use clap derive vs. builder API?
   - **Options**: clap v4 (derive macros), clap builder, structopt (deprecated)
   - **Criteria**: Ease of use, help generation, subcommand support

### Output

**File**: `research.md` containing:
- Decision for each research task
- Rationale with pros/cons
- Code snippets demonstrating chosen approach
- Any assumptions or constraints discovered

---

## Phase 1: Design Artifacts

**Prerequisites**: `research.md` completed with all technology choices resolved.

### 1. Data Model (`data-model.md`)

Define core types and their relationships:

**Entities**:
- `TextureAsset`: Represents converted PNG with RGBA8888 data
- `MeshAsset`: Represents converted OBJ with multiple patches
- `MeshPatch`: 16-vertex, 32-index segment of mesh
- `VertexData`: Position, UV, normal per vertex
- `OutputFile`: Rust source + binary pair

**Transformations**:
- PNG → TextureAsset (validation, format conversion)
- OBJ → MeshAsset (parsing, triangulation, patch splitting)
- TextureAsset → (Rust file, binary file)
- MeshAsset → [(Rust file, binary file) per patch]

**Validation Rules**:
- Texture dimensions: power-of-two, 8×8 to 1024×1024
- Mesh patches: ≤16 vertices, ≤32 indices
- Identifiers: valid Rust names, no conflicts

### 2. API Contracts (`contracts/`)

**CLI Interface** (`cli-interface.md`):
```bash
# Convert single texture
asset-prep texture input.png -o output_dir/

# Convert single mesh
asset-prep mesh input.obj -o output_dir/

# Batch convert directory
asset-prep batch assets/ -o firmware/assets/

# Flags
--quiet        # Suppress progress output
--patch-size   # Override vertex limit (default: 16)
--index-limit  # Override index limit (default: 32)
```

**Output Format** (`output-format.md`):
Specify exact structure of generated .rs and .bin files:

```rust
// Example: textures/player.rs
pub const PLAYER: &[u8] = include_bytes!("player.bin");
// Meta: 256x256 RGBA8, 262144 bytes, 4K-aligned
```

Binary file layout (little-endian):
```text
Texture: [RGBA8 bytes, row-major]
Mesh positions: [f32, f32, f32, ...]
Mesh UVs: [f32, f32, ...]
Mesh normals: [f32, f32, f32, ...]
Mesh indices: [u16, u16, ...]
```

### 3. Quickstart Guide (`quickstart.md`)

User-facing guide covering:
- Installation (cargo install)
- Basic usage examples
- Workflow integration (add to build.rs)
- Troubleshooting common errors

### 4. Agent Context Update

Run `.specify/scripts/bash/update-agent-context.sh claude` to add:
- Rust stable
- `image`, `tobj`, `clap` crates
- CLI tool structure

---

## Phase 2: Task Generation

**Not executed by this command** - use `/speckit.tasks` after Phase 1 completion.

Expected output: `tasks.md` with dependency-ordered implementation tasks derived from data model and contracts.

---

## Next Steps

1. Execute Phase 0 research (automated)
2. Execute Phase 1 design generation (automated)
3. Review generated artifacts
4. Run `/speckit.tasks` to generate implementation tasks
5. Begin implementation with `/speckit.implement`

