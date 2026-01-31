# CLI Interface Contract: Asset Data Preparation Tool

**Feature**: 003-asset-data-prep
**Date**: 2026-01-31
**Status**: Phase 1 Design Artifact

## Overview

This document specifies the complete command-line interface for the asset data preparation tool, including command syntax, flags, arguments, exit codes, and error handling behavior.

## Installation

### From Crates.io (Recommended)

```bash
cargo install asset-prep
```

### From Source

```bash
git clone https://github.com/your-org/pico-gs
cd pico-gs/tools/asset-prep
cargo build --release
cargo install --path .
```

### Verify Installation

```bash
asset-prep --version
# Output: asset-prep 0.1.0
```

---

## Command Structure

```bash
asset-prep [GLOBAL_FLAGS] <SUBCOMMAND> [SUBCOMMAND_ARGS] [SUBCOMMAND_FLAGS]
```

### Global Flags

| Flag | Short | Type | Default | Description |
|------|-------|------|---------|-------------|
| `--quiet` | `-q` | bool | false | Suppress progress output (only show errors) |
| `--help` | `-h` | bool | - | Show help message |
| `--version` | `-V` | bool | - | Show version information |

**Global Flag Behavior**:
- `--quiet` applies to all subcommands
- When enabled, only writes to stderr (errors/warnings)
- Progress messages, statistics, and success confirmations are suppressed
- Exit codes remain unchanged

---

## Subcommands

### 1. `texture` - Convert PNG to RGBA8888 Texture Format

Converts a single PNG image to GPU-compatible RGBA8888 format with validation.

**Syntax**:
```bash
asset-prep texture <INPUT> --output <OUTPUT_DIR>
```

**Arguments**:

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `<INPUT>` | Path | Yes | Path to input PNG file |

**Flags**:

| Flag | Short | Type | Required | Default | Description |
|------|-------|------|----------|---------|-------------|
| `--output` | `-o` | Path | Yes | - | Output directory for generated files |

**Examples**:

```bash
# Convert single texture
asset-prep texture assets/player.png -o firmware/assets/textures/

# Quiet mode (no progress output)
asset-prep texture assets/enemy.png -o firmware/assets/textures/ --quiet

# With parent directory for identifier
asset-prep texture ui/button.png -o firmware/assets/
# Generates: ui_button.rs, ui_button.bin with identifier UI_BUTTON
```

**Output Files**:
- `{identifier}.rs` - Rust wrapper with const declarations
- `{identifier}.bin` - Raw RGBA8888 pixel data

**Expected Progress Output** (when `--quiet` is not set):
```
Converting texture: assets/player.png
  Dimensions: 256×256 RGBA8
  Size: 262144 bytes (256.0 KB)
  Identifier: PLAYER
  Output: firmware/assets/textures/player.rs
Success: Texture converted successfully
```

---

### 2. `mesh` - Convert OBJ to Mesh Patch Format

Converts a single OBJ mesh file to GPU-compatible patch format with automatic splitting.

**Syntax**:
```bash
asset-prep mesh <INPUT> --output <OUTPUT_DIR> [--patch-size N] [--index-limit N]
```

**Arguments**:

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `<INPUT>` | Path | Yes | Path to input OBJ file |

**Flags**:

| Flag | Short | Type | Required | Default | Description |
|------|-------|------|----------|---------|-------------|
| `--output` | `-o` | Path | Yes | - | Output directory for generated files |
| `--patch-size` | - | usize | No | 16 | Maximum vertices per patch (1-65535) |
| `--index-limit` | - | usize | No | 32 | Maximum indices per patch (3-65535, multiple of 3) |

**Validation**:
- `--patch-size` must be at least 3 (minimum triangle)
- `--index-limit` must be at least 3 and a multiple of 3
- `--index-limit` must be at least `--patch-size` (avoid degenerate cases)

**Examples**:

```bash
# Convert mesh with default limits
asset-prep mesh assets/cube.obj -o firmware/assets/meshes/

# Custom patch size for smaller batches
asset-prep mesh assets/complex-model.obj -o firmware/assets/meshes/ --patch-size 12

# Custom index limit for more triangles per patch
asset-prep mesh assets/terrain.obj -o firmware/assets/meshes/ --index-limit 48

# Both limits customized
asset-prep mesh assets/character.obj -o firmware/assets/ --patch-size 20 --index-limit 60

# Quiet mode
asset-prep mesh assets/cube.obj -o firmware/assets/meshes/ --quiet
```

**Output Files** (per patch):
- `{identifier}_patch{n}.rs` - Rust wrapper with const declarations
- `{identifier}_patch{n}_pos.bin` - Vertex positions (f32)
- `{identifier}_patch{n}_uv.bin` - Texture coordinates (f32)
- `{identifier}_patch{n}_norm.bin` - Vertex normals (f32)
- `{identifier}_patch{n}_idx.bin` - Triangle indices (u16)

**Expected Progress Output** (when `--quiet` is not set):
```
Converting mesh: assets/cube.obj
  Original vertices: 24
  Original triangles: 12
  Patch limits: 16 vertices, 32 indices
  Triangulating faces...
  Splitting into patches...
  Generated 1 patch:
    - Patch 0: 24 vertices, 36 indices (12 triangles)
  Identifier: CUBE
  Output directory: firmware/assets/meshes/
Success: Mesh converted successfully (1 patch)
```

**Large Mesh Example**:
```
Converting mesh: assets/dragon.obj
  Original vertices: 1538
  Original triangles: 2836
  Patch limits: 16 vertices, 32 indices
  Triangulating faces...
  Splitting into patches...
  Generated 284 patches:
    - Patch 0: 16 vertices, 30 indices (10 triangles)
    - Patch 1: 16 vertices, 30 indices (10 triangles)
    ...
    - Patch 283: 14 vertices, 27 indices (9 triangles)
  Identifier: DRAGON
  Output directory: firmware/assets/meshes/
Success: Mesh converted successfully (284 patches)
```

---

### 3. `batch` - Batch Convert Directory

Automatically converts all PNG and OBJ files in a directory, preserving subdirectory structure for identifiers.

**Syntax**:
```bash
asset-prep batch <INPUT_DIR> --output <OUTPUT_DIR> [--patch-size N] [--index-limit N]
```

**Arguments**:

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `<INPUT_DIR>` | Path | Yes | Input directory containing .png and .obj files |

**Flags**:

| Flag | Short | Type | Required | Default | Description |
|------|-------|------|----------|---------|-------------|
| `--output` | `-o` | Path | Yes | - | Output directory for generated files |
| `--patch-size` | - | usize | No | 16 | Maximum vertices per patch for meshes |
| `--index-limit` | - | usize | No | 32 | Maximum indices per patch for meshes |

**Behavior**:
- Recursively scans `<INPUT_DIR>` for `.png` and `.obj` files
- Skips hidden files (starting with `.`)
- Processes textures first, then meshes
- Uses parent directory name in identifier (e.g., `textures/player.png` → `TEXTURES_PLAYER`)
- Reports total count at completion

**Examples**:

```bash
# Batch convert all assets
asset-prep batch assets/ -o firmware/assets/

# With custom patch limits
asset-prep batch assets/ -o firmware/assets/ --patch-size 12 --index-limit 36

# Quiet mode for CI/CD
asset-prep batch assets/ -o firmware/assets/ --quiet
```

**Expected Directory Structure**:
```
assets/
├── textures/
│   ├── player.png
│   └── enemy.png
└── meshes/
    ├── cube.obj
    └── sphere.obj
```

**Expected Progress Output** (when `--quiet` is not set):
```
Batch converting assets from: assets/
Scanning directory...
Found 2 textures, 2 meshes

Converting textures...
  [1/2] textures/player.png → TEXTURES_PLAYER
  [2/2] textures/enemy.png → TEXTURES_ENEMY

Converting meshes...
  [1/2] meshes/cube.obj → MESHES_CUBE (1 patch)
  [2/2] meshes/sphere.obj → MESHES_SPHERE (3 patches)

Summary:
  Textures: 2 converted
  Meshes: 2 converted (4 total patches)
  Output: firmware/assets/
Success: Batch conversion complete
```

**Quiet Mode Output**:
```
(no output unless errors occur)
```

---

## Error Handling

### Exit Codes

| Code | Meaning | Description |
|------|---------|-------------|
| 0 | Success | All operations completed successfully |
| 1 | General error | Unknown or unhandled error |
| 2 | File not found | Input file or directory does not exist |
| 3 | Invalid format | Input file format is invalid or corrupted |
| 4 | Validation error | Input fails validation (dimensions, limits, etc.) |
| 5 | IO error | Cannot read input or write output |
| 6 | Identifier conflict | Generated identifiers would conflict |

### Error Message Format

All error messages are written to **stderr** and follow this format:

```
Error: <error-type>: <description>
  Hint: <actionable-suggestion>
```

**Examples**:

```bash
# File not found
Error: File not found: assets/missing.png
  Hint: Check that the path is correct and the file exists

# Invalid dimensions
Error: Validation error: Expected power-of-two dimensions, got 300×200
  Hint: Resize to 256×256 or 512×512 using an image editor

# Dimensions out of range
Error: Validation error: Dimensions 2048×2048 exceed GPU maximum (1024×1024)
  Hint: Resize to maximum 1024×1024

# Below minimum
Error: Validation error: Dimensions 4×4 below GPU minimum (8×8)
  Hint: Resize to minimum 8×8

# Corrupted file
Error: Invalid format: Failed to decode PNG: invalid header
  Hint: Ensure the file is a valid PNG image

# OBJ with no geometry
Error: Validation error: Mesh has no vertices
  Hint: Check that the OBJ file contains vertex data

# Invalid patch size
Error: Invalid argument: --patch-size must be at least 3 (got 1)
  Hint: Use --patch-size 3 or greater

# Invalid index limit
Error: Invalid argument: --index-limit must be multiple of 3 (got 10)
  Hint: Use --index-limit 9, 12, 15, etc.

# Identifier conflict
Error: Identifier conflict: TEXTURES_PLAYER already used
  Hint: Rename one of the conflicting files or reorganize directory structure

# IO error
Error: IO error: Permission denied writing to firmware/assets/player.rs
  Hint: Check write permissions for output directory
```

### Warning Messages

Warnings are written to **stderr** but do not cause non-zero exit codes.

```bash
# Missing UVs
Warning: Mesh has no UV coordinates, using default (0.0, 0.0)

# Missing normals
Warning: Mesh has no normals, using default (0.0, 0.0, 0.0)

# Material file ignored
Warning: Material file 'cube.mtl' referenced but not processed (materials not supported)

# Named groups ignored
Warning: OBJ contains named groups/objects, all geometry will be merged
```

---

## Help Output

### Main Help

```bash
$ asset-prep --help
```

```
asset-prep 0.1.0
Convert PNG/OBJ assets to RP2350 firmware format

USAGE:
    asset-prep [OPTIONS] <SUBCOMMAND>

OPTIONS:
    -q, --quiet      Suppress progress output (only show errors)
    -h, --help       Print help information
    -V, --version    Print version information

SUBCOMMANDS:
    texture    Convert a PNG image to RGBA8888 texture format
    mesh       Convert an OBJ mesh to patch format
    batch      Batch convert all assets in a directory
    help       Print this message or the help of the given subcommand(s)

EXAMPLES:
    # Convert single texture
    asset-prep texture assets/player.png -o firmware/assets/

    # Convert single mesh
    asset-prep mesh assets/cube.obj -o firmware/assets/

    # Batch convert directory
    asset-prep batch assets/ -o firmware/assets/

For more information on a specific command, use:
    asset-prep <SUBCOMMAND> --help
```

### Subcommand Help: `texture`

```bash
$ asset-prep texture --help
```

```
asset-prep-texture 0.1.0
Convert a PNG image to RGBA8888 texture format

USAGE:
    asset-prep texture [OPTIONS] <INPUT>

ARGS:
    <INPUT>    Path to input PNG file

OPTIONS:
    -o, --output <OUTPUT_DIR>    Output directory for generated files
    -q, --quiet                  Suppress progress output
    -h, --help                   Print help information

DESCRIPTION:
    Converts a PNG image to GPU-compatible RGBA8888 format. The image must have
    power-of-two dimensions (8, 16, 32, 64, 128, 256, 512, or 1024) and be within
    the GPU size range (8×8 to 1024×1024).

    Output files:
      - {identifier}.rs   Rust wrapper with const declarations
      - {identifier}.bin  Raw RGBA8888 pixel data (little-endian)

EXAMPLES:
    # Convert with automatic identifier
    asset-prep texture assets/player.png -o firmware/assets/
    # Generates: player.rs, player.bin with identifier PLAYER

    # Convert with parent directory in identifier
    asset-prep texture textures/ui/button.png -o firmware/assets/
    # Generates: ui_button.rs, ui_button.bin with identifier UI_BUTTON
```

### Subcommand Help: `mesh`

```bash
$ asset-prep mesh --help
```

```
asset-prep-mesh 0.1.0
Convert an OBJ mesh to patch format

USAGE:
    asset-prep mesh [OPTIONS] <INPUT>

ARGS:
    <INPUT>    Path to input OBJ file

OPTIONS:
    -o, --output <OUTPUT_DIR>    Output directory for generated files
        --patch-size <N>         Maximum vertices per patch [default: 16]
        --index-limit <N>        Maximum indices per patch [default: 32]
    -q, --quiet                  Suppress progress output
    -h, --help                   Print help information

DESCRIPTION:
    Converts an OBJ mesh to GPU-compatible patch format. Large meshes are
    automatically split into patches that fit within vertex and index limits.

    The tool handles:
      - Quad and polygon faces (automatically triangulated)
      - Missing UVs (defaults to 0.0, 0.0)
      - Missing normals (defaults to 0.0, 0.0, 0.0)

    Output files per patch:
      - {identifier}_patch{n}.rs         Rust wrapper
      - {identifier}_patch{n}_pos.bin    Vertex positions (f32)
      - {identifier}_patch{n}_uv.bin     Texture coordinates (f32)
      - {identifier}_patch{n}_norm.bin   Vertex normals (f32)
      - {identifier}_patch{n}_idx.bin    Triangle indices (u16)

EXAMPLES:
    # Convert with default limits
    asset-prep mesh assets/cube.obj -o firmware/assets/

    # Smaller patches for memory-constrained scenarios
    asset-prep mesh assets/model.obj -o firmware/assets/ --patch-size 12

    # Larger patches for better batching
    asset-prep mesh assets/terrain.obj -o firmware/assets/ --index-limit 48
```

### Subcommand Help: `batch`

```bash
$ asset-prep batch --help
```

```
asset-prep-batch 0.1.0
Batch convert all assets in a directory

USAGE:
    asset-prep batch [OPTIONS] <INPUT_DIR>

ARGS:
    <INPUT_DIR>    Input directory containing .png and .obj files

OPTIONS:
    -o, --output <OUTPUT_DIR>    Output directory for generated files
        --patch-size <N>         Maximum vertices per patch for meshes [default: 16]
        --index-limit <N>        Maximum indices per patch for meshes [default: 32]
    -q, --quiet                  Suppress progress output
    -h, --help                   Print help information

DESCRIPTION:
    Recursively scans the input directory for .png and .obj files and converts
    them all. Parent directory names are included in identifiers to avoid conflicts.

    Files are processed in order:
      1. All PNG textures
      2. All OBJ meshes

    Hidden files (starting with '.') are skipped.

EXAMPLES:
    # Convert all assets
    asset-prep batch assets/ -o firmware/assets/

    # With custom patch limits
    asset-prep batch assets/ -o firmware/assets/ --patch-size 20

    # Quiet mode for CI/CD
    asset-prep batch assets/ -o firmware/assets/ --quiet
```

---

## Usage Examples

### Example 1: Single Texture Conversion

```bash
# Input: assets/player.png (256×256 RGBA)
# Output: firmware/assets/player.rs, firmware/assets/player.bin

$ asset-prep texture assets/player.png -o firmware/assets/

Converting texture: assets/player.png
  Dimensions: 256×256 RGBA8
  Size: 262144 bytes (256.0 KB)
  Identifier: PLAYER
  Output: firmware/assets/player.rs
Success: Texture converted successfully

$ echo $?
0
```

**Generated Files**:

`firmware/assets/player.rs`:
```rust
// Generated from: assets/player.png
// Dimensions: 256×256 RGBA8
// Size: 262144 bytes (256.0 KB)
// GPU Requirements: 4K-aligned base address

pub const PLAYER_WIDTH: u32 = 256;
pub const PLAYER_HEIGHT: u32 = 256;
pub const PLAYER_DATA: &[u8] = include_bytes!("player.bin");

// Usage in firmware:
// let texture = Texture::from_rgba8(PLAYER_WIDTH, PLAYER_HEIGHT, PLAYER_DATA);
```

`firmware/assets/player.bin`: 262,144 bytes of raw RGBA8888 data

### Example 2: Invalid Texture Dimensions

```bash
$ asset-prep texture assets/invalid.png -o firmware/assets/

Converting texture: assets/invalid.png
Error: Validation error: Expected power-of-two dimensions, got 300×200
  Hint: Resize to 256×256 or 512×512 using an image editor

$ echo $?
4
```

### Example 3: Mesh Conversion with Splitting

```bash
# Input: assets/sphere.obj (482 vertices, 960 triangles)
# Output: Multiple patch files

$ asset-prep mesh assets/sphere.obj -o firmware/assets/

Converting mesh: assets/sphere.obj
  Original vertices: 482
  Original triangles: 960
  Patch limits: 16 vertices, 32 indices
  Triangulating faces...
  Splitting into patches...
  Generated 96 patches:
    - Patch 0: 16 vertices, 30 indices (10 triangles)
    - Patch 1: 16 vertices, 30 indices (10 triangles)
    ...
    - Patch 95: 16 vertices, 30 indices (10 triangles)
  Identifier: SPHERE
  Output directory: firmware/assets/
Success: Mesh converted successfully (96 patches)

$ echo $?
0
```

### Example 4: Batch Conversion

```bash
$ asset-prep batch assets/ -o firmware/assets/

Batch converting assets from: assets/
Scanning directory...
Found 3 textures, 2 meshes

Converting textures...
  [1/3] textures/player.png → TEXTURES_PLAYER
  [2/3] textures/enemy.png → TEXTURES_ENEMY
  [3/3] ui/button.png → UI_BUTTON

Converting meshes...
  [1/2] meshes/cube.obj → MESHES_CUBE (1 patch)
  [2/2] meshes/sphere.obj → MESHES_SPHERE (96 patches)

Summary:
  Textures: 3 converted
  Meshes: 2 converted (97 total patches)
  Output: firmware/assets/
Success: Batch conversion complete

$ echo $?
0
```

### Example 5: Quiet Mode (CI/CD)

```bash
$ asset-prep batch assets/ -o firmware/assets/ --quiet
$ echo $?
0

# No output on success, only exit code 0
# Errors still printed to stderr:
$ asset-prep texture missing.png -o firmware/assets/ --quiet
Error: File not found: missing.png
  Hint: Check that the path is correct and the file exists
$ echo $?
2
```

---

## Integration with Build Systems

### Cargo Build Script (`build.rs`)

```rust
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=assets/");

    let status = Command::new("asset-prep")
        .args(&["batch", "assets/", "-o", "firmware/assets/", "--quiet"])
        .status()
        .expect("Failed to run asset-prep");

    if !status.success() {
        panic!("Asset conversion failed");
    }
}
```

### Makefile

```makefile
.PHONY: assets
assets:
	asset-prep batch assets/ -o firmware/assets/

.PHONY: assets-clean
assets-clean:
	rm -rf firmware/assets/*.rs firmware/assets/*.bin

build: assets
	cargo build --release
```

### CI/CD (GitHub Actions)

```yaml
- name: Install asset-prep
  run: cargo install asset-prep

- name: Convert assets
  run: asset-prep batch assets/ -o firmware/assets/ --quiet

- name: Build firmware
  run: cargo build --release
```

---

## Summary

This CLI interface provides:

1. **Three subcommands**: `texture`, `mesh`, `batch` for different use cases
2. **Configurable limits**: `--patch-size` and `--index-limit` for mesh conversion
3. **Quiet mode**: `--quiet` flag for automated builds
4. **Clear error messages**: Actionable hints with appropriate exit codes
5. **Progress reporting**: Detailed output showing conversion progress
6. **Auto-generated help**: Comprehensive `--help` documentation

The interface is designed to be intuitive for manual use while also supporting automated build integration through quiet mode and exit codes.
