# Feature Specification: Asset Data Preparation Library

**Feature Branch**: `003-asset-data-prep`
**Created**: 2026-01-31
**Status**: Draft
**Input**: User description: "Add a data preparation tool that takes .png images and puts them in the correct format for textures for the spi-gpu. It should also take .obj mesh files and turn them into mesh patch data. These data output will then be baked into the rp2350-host-software as constant data. Mesh patches should probably have up to 16 verticies and maybe 32 indicies but am open to adjust those values up or down as needed."

**Architecture**: Library-first design invoked by `host_app/build.rs` for seamless integration into the firmware build process. Asset conversion happens automatically during `cargo build -p pico-gs-host`.

## Overview

The asset data preparation system is a Rust library crate (`asset_build_tool`) that converts PNG textures and OBJ meshes into GPU-compatible formats for the pico-gs project. Unlike traditional asset build tools that run as separate command-line programs invoked by shell scripts, this library integrates directly into Cargo's build system as a `[build-dependency]` of the `host_app` firmware crate.

**Build Flow**:
1. Developer runs `cargo build -p pico-gs-host`
2. Cargo invokes `host_app/build.rs` before compiling the firmware
3. `build.rs` calls `asset_build_tool::build_assets()` with paths to source assets
4. Library scans `host_app/assets/`, converts all .png and .obj files
5. Generates Rust wrapper files + binary data files in `OUT_DIR/assets/`
6. Creates master `mod.rs` that re-exports all asset modules
7. Firmware includes generated code via `include!(concat!(env!("OUT_DIR"), "/assets/mod.rs"))`
8. Cargo compiles firmware with embedded asset data in flash

**Benefits**:
- **Single command**: No shell script orchestration needed for assets
- **Automatic discovery**: New assets are detected and converted automatically
- **Incremental builds**: Only modified assets are reconverted via `cargo:rerun-if-changed`
- **Type safety**: Generated Rust code is checked at compile time
- **Flash packaging**: Assets are embedded directly in the firmware binary

An optional CLI binary is provided for debugging individual asset conversions outside the build process.

## Clarifications

### Session 2026-01-31

- Q: Output file organization - How should multiple converted assets be organized into files? → A: One file per asset with predictable naming (e.g., texture_player.rs, mesh_cube.rs), using binary files to be pulled in by include_bytes!() macro
- Q: Identifier conflict resolution - How to handle conflicts when multiple files have the same name in different directories? → A: Include parent directory in identifier (e.g., TEXTURES_PLAYER, UI_PLAYER)
- Q: Progress reporting and verbosity - Should the tool provide feedback during conversion? → A: Progress output with quiet flag (show progress by default, --quiet to suppress for automated builds)
- Q: Flash budget validation - Should the tool validate total asset size against RP2350's 4 MB flash limit? → A: No validation (developer responsible for checking flash usage at firmware build time)
- Q: Mesh patch count limits - Should there be a maximum number of patches per mesh with warnings or errors? → A: Always report patch count, no warnings (developer decides if patch count is acceptable)

### Session 2026-02-02 - Build System Architecture

**Design Decision: Library invoked by build.rs (not CLI invoked by shell script)**

This design makes the host_app build process including the packaging of prepared assets into the flash binary more streamlined by integrating asset conversion directly into Cargo's build system.

- Q: Should the asset tool be a standalone CLI application or a library used as a build dependency? → A: **Library-first design**. The `asset_build_tool` crate exposes a public Rust API and is used as a `[build-dependency]` by host_app via build.rs. An optional CLI binary (main.rs) wraps the library for manual/debug use only.
- Q: Where should source assets live? → A: `host_app/assets/` (outside src/, conventional for non-Rust source files). build.rs references them via `CARGO_MANIFEST_DIR`.
- Q: Where should generated output go? → A: Cargo's `OUT_DIR` (ephemeral, not committed to VCS). host_app includes generated code via `include!(concat!(env!("OUT_DIR"), "/assets/mod.rs"))`.
- Q: How does the build pipeline work? → A: **Single command: `cargo build -p pico-gs-host`** triggers build.rs, which calls the asset_build_tool library to convert all assets in `host_app/assets/` and write outputs to `OUT_DIR`. No shell script orchestration needed for assets. This makes firmware build completely self-contained.
- Q: Should the batch CLI subcommand be kept? → A: No. The build.rs replaces batch functionality by scanning the source asset directory. The CLI retains `texture` and `mesh` subcommands for debugging individual assets only.

### Session 2026-02-03

- Q: When `host_app/assets/` is empty or contains no .png/.obj files, what should the build behavior be? → A: Succeed with empty `mod.rs` that re-exports nothing (least disruptive for early-stage development when assets aren't ready yet).
- Q: When asset conversion encounters an error during build.rs execution, how should the firmware build be affected? → A: Fail build on any asset conversion error (catches broken assets immediately during development, follows Cargo build.rs conventions).
- Q: Must the patch splitting algorithm produce identical output when processing the same .obj file multiple times? → A: Yes, deterministic required (ensures reproducible builds and reliable testing).
- Q: When two different source files sanitize to the same output identifier, what should happen? → A: Error and fail build (prevents silent data loss where one asset overwrites another).
- Q: When an .obj file contains multiple named objects or groups, how should they be processed? → A: Merge all into one mesh (simplest approach, matches one-asset-per-file model; developers can split externally if needed).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Convert PNG to GPU Texture Format (Priority: P1)

A developer preparing assets for the pico-gs project needs to convert standard PNG images into the RGBA8888 format required by the spi-gpu, ensuring dimensions are power-of-two and within the GPU's supported range (8×8 to 1024×1024).

**Why this priority**: Core functionality that enables all textured rendering. This is the most frequently used feature, can be independently tested, and delivers immediate value for preparing any textured scene.

**Independent Test**: Can be fully tested by converting a single PNG image (e.g., a 256×256 texture) and verifying the output data matches expected RGBA8888 format with correct dimensions and pixel values. No mesh data or firmware integration required.

**Acceptance Scenarios**:

1. **Given** a valid PNG image with power-of-two dimensions (e.g., 256×256), **When** the tool processes it, **Then** output is generated in RGBA8888 format with correct width, height, and pixel data
2. **Given** a PNG image with non-power-of-two dimensions (e.g., 300×200), **When** the tool processes it, **Then** the tool reports an error indicating dimensions must be power-of-two
3. **Given** a PNG image exceeding 1024×1024, **When** the tool processes it, **Then** the tool reports an error indicating size exceeds GPU maximum (1024×1024)
4. **Given** a PNG image smaller than 8×8, **When** the tool processes it, **Then** the tool reports an error indicating size below GPU minimum (8×8)
5. **Given** a PNG image with transparency (alpha channel), **When** the tool processes it, **Then** alpha values are preserved in the RGBA8888 output

---

### User Story 2 - Convert OBJ to Mesh Patches (Priority: P2)

A developer needs to convert standard .obj mesh files into mesh patch format with vertex data (positions, UVs, normals) and triangle indices, automatically splitting large meshes into patches that fit within the vertex and index limits.

**Why this priority**: Essential for 3D mesh rendering. Depends on having working asset pipeline but can be tested independently from texture conversion. Delivers value for rendering any 3D geometry.

**Independent Test**: Can be fully tested by converting a simple .obj file (e.g., cube with 24 vertices, teapot with hundreds of vertices) and verifying vertex positions, UVs, normals, and indices are correctly extracted and split into appropriately-sized patches.

**Acceptance Scenarios**:

1. **Given** a valid .obj file with positions, UVs, and normals, **When** the tool processes it, **Then** mesh patch data is generated with complete vertex attributes and triangle indices
2. **Given** an .obj file without UV coordinates, **When** the tool processes it, **Then** mesh patch data is generated with default UV coordinates (0.0, 0.0) for all vertices
3. **Given** an .obj file without normals, **When** the tool processes it, **Then** mesh patch data is generated with default normals (0.0, 0.0, 0.0) for all vertices
4. **Given** an .obj file with mesh complexity requiring multiple patches (e.g., >16 unique vertices), **When** the tool processes it, **Then** the mesh is automatically split into multiple patches, each with ≤16 vertices and ≤32 indices
5. **Given** an .obj file with quad faces, **When** the tool processes it, **Then** quads are automatically triangulated (split into 2 triangles each)

---

### User Story 3 - Seamless Build.rs Integration (Priority: P3)

A developer needs the converted texture and mesh data to be automatically generated during the firmware build process through `host_app/build.rs`, with all assets converted and packaged into the flash binary in a single `cargo build -p pico-gs-host` command. The asset_build_tool library is invoked as a build dependency, scanning `host_app/assets/`, converting all .png and .obj files, and generating Rust const arrays in `OUT_DIR` that are included in the firmware, eliminating manual data entry, shell script orchestration for assets, and reducing errors.

**Why this priority**: Integration feature that streamlines the entire asset pipeline from source files to compiled firmware binary. Depends on US-1 and US-2 being functional. Delivers value by making firmware builds completely self-contained with automatic asset packaging into flash.

**Independent Test**: Can be fully tested by adding a new .png or .obj file to `host_app/assets/`, running `cargo build -p pico-gs-host`, and verifying that: (1) build.rs automatically detects and converts the new asset, (2) generated Rust source files appear in `OUT_DIR`, (3) firmware compiles without errors, (4) asset data is accessible from firmware code via `include!()`, and (5) incremental rebuilds only reconvert modified assets.

**Acceptance Scenarios**:

1. **Given** `host_app/build.rs` calls `asset_build_tool::build_assets()`, **When** texture data is converted, **Then** a Rust source file and binary file are created in `OUT_DIR/assets/`, with the Rust file using include_bytes!() to reference the binary RGBA8888 pixel data
2. **Given** `host_app/build.rs` calls `asset_build_tool::build_assets()`, **When** mesh data is converted, **Then** Rust source files and binary data files are created in `OUT_DIR/assets/` for vertex positions, UVs, normals, and indices with include_bytes!() references
3. **Given** multiple assets in `host_app/assets/`, **When** `cargo build -p pico-gs-host` is run, **Then** build.rs automatically calls the library to scan, convert all assets, and generate a master `mod.rs` in `OUT_DIR/assets/` that re-exports all asset modules
4. **Given** output files generated in `OUT_DIR/assets/`, **When** firmware includes them via `include!(concat!(env!("OUT_DIR"), "/assets/mod.rs"))`, **Then** build succeeds and asset data is accessible at compile time with correct types, packaged into the flash binary
5. **Given** texture data generated, **When** output includes memory layout comments, **Then** comments document the required 4K alignment for GPU base addresses
6. **Given** a source asset file is modified in `host_app/assets/`, **When** `cargo build` is run again, **Then** only the modified asset is reconverted (incremental rebuild via `cargo:rerun-if-changed` directives emitted by build.rs)
7. **Given** a new asset is added to `host_app/assets/`, **When** `cargo build` is run, **Then** the new asset is automatically discovered, converted, and included in the generated `mod.rs` without any manual configuration
8. **Given** the firmware build completes, **When** the resulting binary is examined, **Then** all asset data is embedded in flash with no runtime heap allocation required

---

### Edge Cases

- What happens when PNG images use indexed color mode or grayscale instead of RGB/RGBA? (Answered in FR-006, FR-007: converted to RGBA8888)
- How does the tool handle .obj files with multiple objects or groups? (Answered in FR-014a: all merged into one mesh)
- What happens when .obj files reference external .mtl material files? (Answered in FR-033: warning issued, materials not processed)
- How are vertex winding order (CW vs CCW) and face culling determined?
- What happens when .obj files use unsupported features (parametric curves, NURBS, subdivision surfaces)? (Answered in FR-033: warning issued)
- How does the tool handle extremely large .obj files (>1M vertices) that would create hundreds of patches?
- What happens when mesh vertices have floating-point precision that exceeds what the GPU can represent?
- How are invalid or corrupted input files detected and reported? (Answered in FR-031: clear error messages, build fails)
- What happens with deeply nested paths (e.g., `assets/textures/characters/enemies/player.png`) - how many parent directories are included in the identifier?

## Requirements *(mandatory)*

### Functional Requirements

**PNG Texture Conversion:**

- **FR-001**: System MUST accept .png image files as input and validate they are readable
- **FR-002**: System MUST validate PNG images have power-of-two dimensions (8, 16, 32, 64, 128, 256, 512, or 1024 for both width and height)
- **FR-003**: System MUST validate PNG dimensions are within GPU range (8×8 minimum to 1024×1024 maximum)
- **FR-004**: System MUST convert PNG images to RGBA8888 format (32 bits per texel, 8 bits per channel)
- **FR-005**: System MUST preserve PNG alpha channel in output for transparency support
- **FR-006**: System MUST convert grayscale PNG images to RGBA8888 by replicating luminance to R, G, B channels
- **FR-007**: System MUST convert indexed color PNG images to RGBA8888 by applying the palette

**OBJ Mesh Conversion:**

- **FR-008**: System MUST accept .obj mesh files as input and validate they are readable
- **FR-009**: System MUST extract vertex positions (x, y, z coordinates) from .obj files
- **FR-010**: System MUST extract texture coordinates (UV) from .obj files when present
- **FR-011**: System MUST extract vertex normals from .obj files when present
- **FR-012**: System MUST extract face indices from .obj files and convert to triangle list format
- **FR-013**: System MUST handle .obj files with quad faces by triangulating them (split each quad into 2 triangles)
- **FR-014**: System MUST handle .obj files with polygon faces (>4 vertices) by triangulating them using a fan triangulation
- **FR-014a**: System MUST merge all objects and groups within a single .obj file into one unified mesh output (one .obj file produces one asset regardless of internal object/group structure)

**Mesh Patch Generation:**

- **FR-015**: System MUST organize mesh data into patches with up to 16 vertices per patch
- **FR-016**: System MUST organize mesh data into patches with up to 32 indices per patch (allowing up to 10 triangles per patch if no vertex sharing)
- **FR-017**: System MUST automatically split meshes exceeding patch limits into multiple patches
- **FR-018**: System MUST use a greedy sequential algorithm for patch splitting: fill each patch with triangles until adding the next triangle would exceed vertex or index limits. The algorithm MUST be deterministic, producing identical output for the same input file across multiple runs.
- **FR-019**: System MUST duplicate vertices across patches when triangles span patch boundaries (no cross-patch vertex sharing in initial version)

**Output Generation:**

- **FR-020**: System MUST generate one Rust source file per asset with predictable naming derived from input filename
- **FR-021**: System MUST generate binary data files alongside Rust wrapper files
- **FR-022**: System MUST generate texture output as a Rust file containing `pub const [NAME]: &[u8] = include_bytes!("[name].bin");` that references a binary file with RGBA8888 pixel data in row-major order
- **FR-023**: System MUST generate mesh output as Rust files containing const declarations using `include_bytes!()` for positions, UVs, normals, and indices
- **FR-024**: System MUST store mesh vertex positions as binary f32 data (little-endian, 3 floats per vertex)
- **FR-025**: System MUST store mesh UV coordinates as binary f32 data (little-endian, 2 floats per vertex)
- **FR-026**: System MUST store mesh normals as binary f32 data (little-endian, 3 floats per vertex)
- **FR-027**: System MUST store mesh indices as binary u16 data (little-endian)
- **FR-028**: System MUST derive asset identifiers from input filenames including parent directory name (sanitized to valid Rust identifiers, uppercase with underscores, e.g., `textures/player.png` → `TEXTURES_PLAYER`)
- **FR-029**: System MUST include comments in Rust wrapper files documenting asset metadata (source filename, dimensions/vertex count, patch count for meshes)
- **FR-030**: System MUST include comments documenting texture memory requirements and 4K alignment requirements for GPU base addresses

**Error Handling and Validation:**

- **FR-031**: System MUST report clear error messages for invalid input files (corrupted, wrong format, unreadable)
- **FR-032**: System MUST report errors for PNG images with invalid dimensions (non-power-of-two or out of GPU range)
- **FR-033**: System MUST report warnings for .obj features that cannot be preserved (materials, curves, named groups)
- **FR-034**: System MUST report errors for .obj files with no valid geometry (no vertices or faces)
- **FR-035**: System MUST report patch count for all converted meshes (including original vertex count and resulting patch count, regardless of whether splitting occurred)
- **FR-036**: System MUST detect identifier collisions (when different source files sanitize to the same Rust identifier, including cases like "foo@bar.png" and "foo_bar.png" both becoming "FOO_BAR") and fail the build with a clear error message listing the conflicting source files

**Library API (Primary Interface):**

- **FR-037**: System MUST expose a public Rust library API (`build_assets()`) that accepts a source directory (`host_app/assets/`), output directory (`OUT_DIR/assets/`), and configuration (patch size, index limit) and processes all .png and .obj files found in the source directory
- **FR-038**: System MUST generate a master `mod.rs` file in the output directory that re-exports all generated asset modules with proper module hierarchy, suitable for inclusion via `include!(concat!(env!("OUT_DIR"), "/assets/mod.rs"))` in firmware code
- **FR-039**: System MUST provide the information needed for build.rs to emit `cargo:rerun-if-changed` directives for the source asset directory and all individual source asset files to support incremental rebuilds (only reconvert modified assets)
- **FR-040a**: System MUST be usable as a `[build-dependency]` in `host_app/Cargo.toml`, allowing the library to be invoked from `host_app/build.rs` during the normal firmware build process
- **FR-040b**: System MUST succeed with an empty `mod.rs` file (containing no module declarations) when the source directory is empty or contains no .png/.obj files, allowing firmware builds to proceed without assets during early development

**User Interface and Output (CLI for debugging only):**

- **FR-041**: System MUST provide an optional CLI binary that wraps the library API for manual/debug use when converting individual assets
- **FR-042**: System MUST display progress information by default (asset name, operation, status) during conversion when used via CLI
- **FR-043**: System MUST support a --quiet flag in the CLI that suppresses all non-error output
- **FR-044**: System MUST write all progress and informational messages to stdout and all errors/warnings to stderr when used via CLI. When used as a library in build.rs, errors are reported via `Result<T, E>` return values that cause build.rs to fail (propagating errors via `?` operator), ensuring any asset conversion error fails the firmware build immediately.

### Key Entities

- **Texture Asset**: A converted PNG image in RGBA8888 format ready for GPU upload
  - Attributes: width (power-of-two), height (power-of-two), pixel data (RGBA8888 byte array), size in bytes, memory alignment requirement (4K), source filename, Rust identifier

- **Mesh Patch**: A segment of a 3D mesh with vertex and index data fitting within GPU constraints
  - Attributes: vertex count (≤16), index count (≤32), vertex positions (array of [f32; 3]), UV coordinates (array of [f32; 2]), normals (array of [f32; 3]), triangle indices (array of u16), source filename, Rust identifier
  - Relationships: Multiple patches can originate from the same source .obj file, forming a complete mesh

- **Vertex Data**: Per-vertex attributes for mesh rendering
  - Attributes: position (x, y, z as f32), UV coordinates (u, v as f32), normal (x, y, z as f32)
  - Note: All attributes use 32-bit floating point to preserve precision for later transformations by host software

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A single `cargo build -p pico-gs-host` command successfully converts all assets and builds the firmware with no manual steps required
- **SC-002**: When a developer adds a new .png or .obj file to `host_app/assets/`, the next `cargo build` automatically detects and converts it without configuration changes
- **SC-003**: Incremental builds only reconvert modified assets (measured via `cargo:rerun-if-changed`), reducing build times during iterative development
- **SC-004**: The library can convert a PNG texture (up to 1024×1024) to GPU format in under 1 second on typical development machines
- **SC-005**: The library can convert a typical .obj mesh file (e.g., Utah teapot with ~1000 vertices) to patch format in under 2 seconds
- **SC-006**: Full asset set (10 textures + 5 meshes) processes in under 10 seconds during clean builds
- **SC-007**: 100% of valid power-of-two PNG images within GPU size limits (8×8 to 1024×1024) convert successfully without data loss
- **SC-008**: Generated Rust source files in `OUT_DIR` compile successfully when included in firmware builds with zero errors or warnings
- **SC-009**: Converted textures display correctly when rendered by the GPU with pixel-perfect accuracy (no color shifts or artifacts)
- **SC-010**: Converted meshes render correctly when submitted to the GPU with proper triangle topology and no missing/duplicate faces
- **SC-011**: Generated const arrays consume no additional RAM at runtime (data stored in flash, verifiable via firmware memory map)
- **SC-012**: Error messages include actionable information (e.g., "Expected power-of-two dimensions, got 300×200. Try 256×256 or 512×512.")
- **SC-013**: Mesh splitting algorithm produces patches that render identically to the original mesh (no visual differences due to vertex duplication)
- **SC-014**: The build.sh script no longer needs asset-specific orchestration steps (simplified from previous multi-step approach)

## Assumptions *(optional)*

- **A-001**: Input files use standard formats (.png for images, .obj for meshes) with no proprietary extensions
- **A-002**: PNG images use sRGB color space (no HDR or wide-gamut color spaces)
- **A-003**: OBJ files use standard Wavefront OBJ format (no material references will be processed)
- **A-004**: Mesh vertex positions are in model space; transformation to screen space is the responsibility of host software
- **A-005**: Initial version does not support compressed texture format (8-bit indexed); only RGBA8888 output
- **A-006**: **PRIMARY USE CASE**: Library runs as a `[build-dependency]` of host_app, invoked by `host_app/build.rs` during `cargo build -p pico-gs-host`. The library compiles and runs on the development machine (host target), not on RP2350 hardware. It outputs Rust wrapper files (using include_bytes!() macro) and binary data files to Cargo's `OUT_DIR/assets/` for automatic inclusion via `include!(concat!(env!("OUT_DIR"), "/assets/mod.rs"))` in firmware. This makes the firmware build self-contained with no shell script orchestration needed for assets.
- **A-007**: **SECONDARY USE CASE**: An optional CLI binary wraps the library API for manual/debug use when developers need to test conversion of individual assets outside the build process.
- **A-008**: Source assets (.png, .obj) are stored in `host_app/assets/` and committed to version control. Generated output lives in `OUT_DIR` (ephemeral) and is not committed to version control.
- **A-009**: Developers have external tools (e.g., Blender, GIMP) for preparing source assets before conversion
- **A-010**: Texture and mesh data will fit within RP2350's 4 MB flash capacity when combined with firmware code
- **A-011**: Cargo's incremental build system with `cargo:rerun-if-changed` directives provides sufficient performance for asset conversion during development (no need for parallel processing or caching)

## Dependencies *(optional)*

- **D-001**: Requires spi-gpu specification v2.0 for texture format requirements (RGBA8888, power-of-two dimensions, 4K alignment)
- **D-002**: Requires Rust toolchain on development machine for output format compatibility
- **D-003**: Requires standard image decoding library for PNG format support
- **D-004**: Requires OBJ file parser for mesh geometry extraction
- **D-005**: Requires rp2350-host-software firmware project structure for integration testing

## Out of Scope *(optional)*

**Features explicitly NOT included in this version:**

- Compressed texture format generation (8-bit indexed with LUT) - deferred to future version
- Texture swizzle pattern configuration - future enhancement
- Texture mipmap generation - future enhancement
- Mesh LOD (level-of-detail) generation - future enhancement
- Mesh optimization (vertex cache optimization, overdraw reduction) - future enhancement
- Normal map generation from height maps - future enhancement
- Automatic texture resizing or padding to power-of-two - developer must prepare correct sizes
- Material or lighting data extraction from .obj/.mtl files - future enhancement
- Flash budget validation or warnings - developer responsible for managing total flash usage at firmware build time
- GUI or interactive tool - library API and optional CLI only
- Live preview or visualization of converted assets - future enhancement
- Parallel asset conversion - process files sequentially within build.rs (sufficient for typical asset sets)
- Cross-patch vertex sharing optimization - patches are independent in this version
- Shell script orchestration for assets - build.rs integration eliminates the need for build.sh to handle asset conversion
- Batch CLI subcommand - build.rs replaces the need for batch processing via CLI

## Related Features *(optional)*

- **spi-gpu specification v2.0** (specs/001-spi-gpu): Defines texture format requirements and GPU constraints that this library must satisfy
- **rp2350-host-software** (specs/002-rp2350-host-software): Firmware that consumes the generated const arrays via build.rs integration. The firmware's build process is streamlined by having asset conversion happen automatically during `cargo build` rather than requiring separate shell script orchestration.
