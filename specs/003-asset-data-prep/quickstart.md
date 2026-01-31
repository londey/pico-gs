# Quickstart Guide: Asset Data Preparation Tool

**Feature**: 003-asset-data-prep
**Date**: 2026-01-31
**Status**: Phase 1 Design Artifact

## Overview

This guide will help you get started with the asset data preparation tool for the pico-gs project. You'll learn how to install the tool, convert your first texture and mesh, and integrate the generated files into your RP2350 firmware.

**What this tool does**:
- Converts PNG images to RGBA8888 texture format for the spi-gpu
- Converts OBJ mesh files to GPU-compatible patch format (≤16 vertices, ≤32 indices per patch)
- Generates Rust source files and binary data files for firmware integration
- Validates input files and reports clear errors

**What you'll need**:
- Rust toolchain (1.75 or later)
- PNG images with power-of-two dimensions (8×8 to 1024×1024)
- OBJ mesh files (standard Wavefront format)

---

## Installation

### Prerequisites

Ensure you have Rust installed:

```bash
rustc --version
# Should show: rustc 1.75.0 or later
```

If not installed, get Rust from [rustup.rs](https://rustup.rs/):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### Install from Crates.io (Recommended)

```bash
cargo install asset-prep
```

Verify installation:

```bash
asset-prep --version
# Output: asset-prep 0.1.0
```

### Build from Source (Development)

```bash
# Clone repository
git clone https://github.com/your-org/pico-gs
cd pico-gs/tools/asset-prep

# Build and install
cargo build --release
cargo install --path .

# Verify
asset-prep --version
```

---

## Quick Start Workflow

### Step 1: Prepare Your Assets

Organize your assets in a directory structure:

```
my-game/
├── assets/
│   ├── textures/
│   │   ├── player.png      # 256×256 RGBA
│   │   └── enemy.png       # 128×128 RGBA
│   └── meshes/
│       ├── cube.obj
│       └── sphere.obj
└── firmware/
    └── assets/             # Generated files will go here
```

**Important**: PNG images must have power-of-two dimensions:
- Valid: 8, 16, 32, 64, 128, 256, 512, 1024
- Invalid: 100, 300, 640, 1920

Use an image editor (GIMP, Photoshop, etc.) to resize if needed.

### Step 2: Convert a Texture

Convert your first PNG texture:

```bash
asset-prep texture assets/textures/player.png -o firmware/assets/
```

**Expected output**:
```
Converting texture: assets/textures/player.png
  Dimensions: 256×256 RGBA8
  Size: 262144 bytes (256.0 KB)
  Identifier: TEXTURES_PLAYER
  Output: firmware/assets/textures_player.rs
Success: Texture converted successfully
```

**Generated files**:
- `firmware/assets/textures_player.rs` - Rust wrapper with const declarations
- `firmware/assets/textures_player.bin` - Raw RGBA8888 pixel data (262,144 bytes)

### Step 3: Convert a Mesh

Convert your first OBJ mesh:

```bash
asset-prep mesh assets/meshes/cube.obj -o firmware/assets/
```

**Expected output**:
```
Converting mesh: assets/meshes/cube.obj
  Original vertices: 24
  Original triangles: 12
  Patch limits: 16 vertices, 32 indices
  Triangulating faces...
  Splitting into patches...
  Generated 1 patch:
    - Patch 0: 24 vertices, 36 indices (12 triangles)
  Identifier: MESHES_CUBE
  Output directory: firmware/assets/
Success: Mesh converted successfully (1 patch)
```

**Generated files** (per patch):
- `firmware/assets/meshes_cube_patch0.rs` - Rust wrapper
- `firmware/assets/meshes_cube_patch0_pos.bin` - Vertex positions (288 bytes)
- `firmware/assets/meshes_cube_patch0_uv.bin` - Texture coordinates (192 bytes)
- `firmware/assets/meshes_cube_patch0_norm.bin` - Vertex normals (288 bytes)
- `firmware/assets/meshes_cube_patch0_idx.bin` - Triangle indices (72 bytes)

### Step 4: Integrate into Firmware

Create an assets module in your firmware:

**`firmware/src/assets.rs`**:
```rust
// Include generated texture
include!("../../assets/textures_player.rs");

// Include generated mesh patch
include!("../../assets/meshes_cube_patch0.rs");
```

**`firmware/src/main.rs`**:
```rust
mod assets;

fn main() {
    // Use texture data
    let texture_width = assets::TEXTURES_PLAYER_WIDTH;
    let texture_height = assets::TEXTURES_PLAYER_HEIGHT;
    let texture_data = assets::TEXTURES_PLAYER_DATA;

    println!("Loaded texture: {}×{}, {} bytes",
        texture_width, texture_height, texture_data.len());

    // Use mesh data
    let positions = bytemuck::cast_slice::<u8, f32>(assets::MESHES_CUBE_PATCH0_POSITIONS);
    let indices = bytemuck::cast_slice::<u8, u16>(assets::MESHES_CUBE_PATCH0_INDICES);

    println!("Loaded mesh: {} vertices, {} indices",
        assets::MESHES_CUBE_PATCH0_VERTEX_COUNT,
        assets::MESHES_CUBE_PATCH0_INDEX_COUNT);
}
```

**Add `bytemuck` to `Cargo.toml`**:
```toml
[dependencies]
bytemuck = "1.14"
```

### Step 5: Build Firmware

```bash
cd firmware
cargo build --release
```

The generated binary includes all texture and mesh data embedded at compile time!

---

## Common Workflows

### Batch Convert All Assets

Instead of converting files one by one, use batch mode:

```bash
asset-prep batch assets/ -o firmware/assets/
```

This recursively finds all `.png` and `.obj` files and converts them automatically.

**Expected output**:
```
Batch converting assets from: assets/
Scanning directory...
Found 2 textures, 2 meshes

Converting textures...
  [1/2] textures/player.png → TEXTURES_PLAYER
  [2/2] textures/enemy.png → TEXTURES_ENEMY

Converting meshes...
  [1/2] meshes/cube.obj → MESHES_CUBE (1 patch)
  [2/2] meshes/sphere.obj → MESHES_SPHERE (96 patches)

Summary:
  Textures: 2 converted
  Meshes: 2 converted (97 total patches)
  Output: firmware/assets/
Success: Batch conversion complete
```

### Automate with Build Script

Add asset conversion to your firmware's `build.rs`:

**`firmware/build.rs`**:
```rust
use std::process::Command;

fn main() {
    // Rebuild if assets directory changes
    println!("cargo:rerun-if-changed=../assets/");

    // Run asset conversion
    let status = Command::new("asset-prep")
        .args(&["batch", "../assets/", "-o", "assets/", "--quiet"])
        .status()
        .expect("Failed to run asset-prep");

    if !status.success() {
        panic!("Asset conversion failed");
    }
}
```

Now assets are automatically converted when you build:

```bash
cargo build
# Assets are converted before compilation
```

### CI/CD Integration

Use quiet mode to suppress progress output in automated builds:

**.github/workflows/build.yml**:
```yaml
name: Build Firmware

on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable

      - name: Install asset-prep
        run: cargo install asset-prep

      - name: Convert assets
        run: asset-prep batch assets/ -o firmware/assets/ --quiet

      - name: Build firmware
        run: cd firmware && cargo build --release

      - name: Upload artifact
        uses: actions/upload-artifact@v3
        with:
          name: firmware
          path: firmware/target/release/firmware.elf
```

### Custom Patch Sizes

For memory-constrained scenarios, use smaller patches:

```bash
asset-prep mesh assets/complex-model.obj -o firmware/assets/ --patch-size 12 --index-limit 24
```

This generates patches with max 12 vertices and 24 indices (8 triangles), reducing memory requirements per batch.

For better GPU batching, use larger patches:

```bash
asset-prep mesh assets/terrain.obj -o firmware/assets/ --patch-size 20 --index-limit 60
```

**Trade-offs**:
- Smaller patches: Less memory per batch, more draw calls
- Larger patches: More memory per batch, fewer draw calls

---

## Troubleshooting

### Error: "Expected power-of-two dimensions"

**Problem**: Your PNG image has non-power-of-two dimensions (e.g., 300×200).

**Solution**: Resize the image to power-of-two dimensions using an image editor:
- GIMP: Image → Scale Image
- Photoshop: Image → Image Size
- ImageMagick: `convert input.png -resize 256x256 output.png`

**Valid dimensions**: 8, 16, 32, 64, 128, 256, 512, 1024

### Error: "Dimensions exceed GPU maximum"

**Problem**: Your texture is larger than 1024×1024.

**Solution**: Downscale the image to 1024×1024 or smaller. The spi-gpu supports maximum 1024×1024 textures.

```bash
# Using ImageMagick
convert large-texture.png -resize 1024x1024 texture.png
```

### Error: "File not found"

**Problem**: The input file path is incorrect or the file doesn't exist.

**Solution**: Verify the path is correct:
```bash
ls -l assets/textures/player.png
# Should show file info
```

Use absolute paths if relative paths don't work:
```bash
asset-prep texture /home/user/my-game/assets/player.png -o /home/user/my-game/firmware/assets/
```

### Error: "Mesh has no vertices"

**Problem**: Your OBJ file is empty or corrupted.

**Solution**: Open the OBJ file in a 3D editor (Blender, MeshLab) and verify it contains geometry. Re-export if needed.

**Blender export settings**:
- File → Export → Wavefront (.obj)
- Enable: Include Normals, Include UVs, Triangulate Faces
- Disable: Write Materials, Write Normals

### Warning: "Mesh has no UV coordinates"

**Problem**: Your OBJ file doesn't include texture coordinates.

**Solution**: This is just a warning. The tool will use default UVs (0.0, 0.0) for all vertices. If you need proper texture mapping:

1. Open mesh in Blender
2. UV Editing workspace
3. Select all faces (A key)
4. U → Unwrap
5. Export with "Include UVs" enabled

### Large Number of Patches

**Problem**: Your mesh generates hundreds of patches, making integration tedious.

**Solution**: Consider these options:

1. **Simplify the mesh**: Use Blender's Decimate modifier to reduce vertex count
2. **Increase patch size**: Use `--patch-size 20` or higher
3. **Use a manifest file**: Create a Rust macro to include all patches:

```rust
// firmware/src/assets.rs
macro_rules! include_mesh_patches {
    ($base:expr, $count:expr) => {
        concat!(
            $(include!(concat!("../../assets/", $base, "_patch", stringify!($i), ".rs")),)*
        )
    };
}

// Include sphere with 96 patches
include_mesh_patches!("sphere", 96);
```

### Permission Denied Writing Output

**Problem**: Cannot write to output directory.

**Solution**: Check directory permissions:
```bash
ls -ld firmware/assets/
# Should show write permissions (drwxr-xr-x or similar)

# Create directory if it doesn't exist
mkdir -p firmware/assets/

# Fix permissions if needed
chmod 755 firmware/assets/
```

### Identifier Conflicts

**Problem**: "Identifier conflict: PLAYER already used"

**Solution**: This happens when multiple files generate the same identifier. Options:

1. **Rename one file**: `player.png` → `player_sprite.png`
2. **Use subdirectories**: Move to different subdirectories
   - `textures/player.png` → `TEXTURES_PLAYER`
   - `ui/player.png` → `UI_PLAYER`

### Build Fails with "cannot find include"

**Problem**: Firmware build fails because generated `.rs` files can't be found.

**Solution**: Verify paths in `include!()` are correct relative to the Rust file:

```rust
// If this is firmware/src/assets.rs
// And generated file is firmware/assets/player.rs
include!("../../assets/player.rs");  // Correct
// NOT: include!("assets/player.rs")  // Wrong
```

Use `../` to go up directories from `src/assets.rs`:
- `../` → `firmware/src/`
- `../../` → `firmware/`
- `../../assets/` → `firmware/assets/`

---

## Best Practices

### Asset Organization

Organize assets by type and purpose:

```
assets/
├── textures/
│   ├── characters/
│   │   ├── player.png
│   │   └── enemy.png
│   ├── ui/
│   │   ├── button.png
│   │   └── panel.png
│   └── environment/
│       └── terrain.png
└── meshes/
    ├── characters/
    │   └── player.obj
    └── environment/
        └── terrain.obj
```

This generates clear identifiers:
- `CHARACTERS_PLAYER` (texture)
- `UI_BUTTON` (texture)
- `CHARACTERS_PLAYER` (mesh)

**Note**: Avoid deep nesting - only immediate parent directory is used in identifiers.

### Version Control

**Do commit**:
- Source assets (`assets/*.png`, `assets/*.obj`)
- Build script (`build.rs`) that runs asset-prep
- Asset manifest or index file

**Consider `.gitignore`**:
- Generated `.bin` files (large, can be regenerated)
- Generated `.rs` files (can be regenerated from source)

**Or commit everything**:
- Useful for reproducible builds without requiring asset-prep installation
- Binary files compress well with Git LFS

### Texture Preparation Tips

1. **Always use power-of-two dimensions**: Plan ahead when creating textures
2. **Start with high resolution**: Easier to downscale than upscale
3. **Use PNG for transparency**: Alpha channel is preserved in RGBA8888
4. **Optimize file size**: Use PNG optimization tools (pngcrush, optipng) before committing
5. **Consistent color space**: Use sRGB for all textures

### Mesh Preparation Tips

1. **Triangulate before export**: Let Blender handle triangulation instead of relying on asset-prep
2. **Include UVs and normals**: Reduces warnings and ensures proper rendering
3. **Clean up geometry**: Remove doubles, fix normals, remove internal faces
4. **Optimize vertex count**: Use decimation modifiers to reduce patch count
5. **Test with simple meshes**: Start with cube/sphere before complex models

### Performance Optimization

1. **Batch convert in CI/CD**: Use `--quiet` flag and cache generated files
2. **Use build script**: Automatic conversion on firmware build
3. **Profile large meshes**: Check patch count before committing large models
4. **Monitor flash usage**: Keep total asset size under 2 MB (leaves room for firmware)

---

## What's Next?

Now that you've converted your assets:

1. **Integrate with GPU**: Use the spi-gpu specification (specs/001-spi-gpu) to upload textures
2. **Render meshes**: Use the host software API (specs/002-rp2350-host-software) to submit patches
3. **Transform data**: Apply MVP transforms before sending to GPU
4. **Optimize**: Profile rendering performance and adjust patch sizes if needed

### Additional Resources

- **Feature Specification**: `/workspaces/pico-gs/specs/003-asset-data-prep/spec.md`
- **Data Model**: `/workspaces/pico-gs/specs/003-asset-data-prep/data-model.md`
- **CLI Reference**: `/workspaces/pico-gs/specs/003-asset-data-prep/contracts/cli-interface.md`
- **Output Format**: `/workspaces/pico-gs/specs/003-asset-data-prep/contracts/output-format.md`
- **spi-gpu Spec**: `/workspaces/pico-gs/specs/001-spi-gpu/`
- **RP2350 Host Software**: `/workspaces/pico-gs/specs/002-rp2350-host-software/`

### Getting Help

If you encounter issues:

1. Check this troubleshooting section
2. Review error messages for hints
3. Use `--help` for command syntax: `asset-prep --help`
4. Check GitHub issues: [github.com/your-org/pico-gs/issues]
5. File a bug report with:
   - Command used
   - Error message
   - Input file characteristics (dimensions, vertex count, etc.)
   - Operating system and Rust version

---

## Example: Complete Workflow

Here's a complete example from scratch:

```bash
# 1. Set up project structure
mkdir -p my-game/{assets/{textures,meshes},firmware/{src,assets}}
cd my-game

# 2. Copy assets (assuming you have player.png and cube.obj)
cp ~/Downloads/player.png assets/textures/
cp ~/Downloads/cube.obj assets/meshes/

# 3. Verify texture dimensions
file assets/textures/player.png
# Should show: PNG image data, 256 x 256, 8-bit/color RGBA

# 4. Convert all assets
asset-prep batch assets/ -o firmware/assets/

# 5. Create firmware project
cd firmware
cat > Cargo.toml <<EOF
[package]
name = "my-game-firmware"
version = "0.1.0"
edition = "2021"

[dependencies]
bytemuck = "1.14"
EOF

# 6. Create assets module
cat > src/assets.rs <<EOF
include!("../../assets/textures_player.rs");
include!("../../assets/meshes_cube_patch0.rs");
EOF

# 7. Create main.rs
cat > src/main.rs <<EOF
mod assets;

fn main() {
    println!("Texture: {}×{}, {} bytes",
        assets::TEXTURES_PLAYER_WIDTH,
        assets::TEXTURES_PLAYER_HEIGHT,
        assets::TEXTURES_PLAYER_DATA.len());

    println!("Mesh: {} vertices, {} triangles",
        assets::MESHES_CUBE_PATCH0_VERTEX_COUNT,
        assets::MESHES_CUBE_PATCH0_INDEX_COUNT / 3);
}
EOF

# 8. Build and run
cargo run
# Output:
# Texture: 256×256, 262144 bytes
# Mesh: 24 vertices, 12 triangles
```

Success! You've converted assets and integrated them into firmware.

---

## Summary

You've learned how to:

- ✅ Install the asset-prep tool
- ✅ Convert PNG textures to RGBA8888 format
- ✅ Convert OBJ meshes to GPU patch format
- ✅ Integrate generated files into firmware
- ✅ Automate conversion with build scripts
- ✅ Troubleshoot common errors
- ✅ Follow best practices for asset organization

The asset-prep tool makes it easy to prepare game assets for the pico-gs platform. All data is embedded at compile time, ensuring fast access and no runtime file I/O.

Happy developing!
