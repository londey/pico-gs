# Data Model: Asset Data Preparation Tool

**Feature**: 003-asset-data-prep
**Date**: 2026-01-31
**Status**: Phase 1 Design Artifact

## Overview

This document defines the core data structures, validation rules, and transformation pipeline for the asset data preparation tool. All types are designed to support the conversion of PNG images and OBJ meshes into RP2350 firmware-compatible binary format.

## Library API Types

### AssetBuildConfig

Configuration for the asset build process, used by build.rs.

**Rust Type Signature**:
```rust
pub struct AssetBuildConfig {
    /// Directory containing source assets (textures/*.png, meshes/*.obj)
    pub source_dir: PathBuf,

    /// Output directory for generated files (typically OUT_DIR/assets)
    pub out_dir: PathBuf,

    /// Maximum vertices per mesh patch (default: 16)
    pub patch_size: usize,

    /// Maximum indices per mesh patch (default: 32)
    pub index_limit: usize,
}
```

### GeneratedAsset

Metadata about a generated asset, returned by the build process.

**Rust Type Signature**:
```rust
pub struct GeneratedAsset {
    /// Rust module name for this asset
    pub module_name: String,

    /// Rust identifier prefix (uppercase)
    pub identifier: String,

    /// Path to the generated .rs file (relative to out_dir)
    pub rs_path: PathBuf,

    /// Source file that produced this asset (for rerun-if-changed)
    pub source_path: PathBuf,
}
```

### Public API Functions

```rust
/// Process all assets in source_dir and write outputs to out_dir.
/// Returns list of generated assets for building the master mod.rs.
pub fn build_assets(config: &AssetBuildConfig) -> Result<Vec<GeneratedAsset>, AssetError>;

/// Convert a single PNG texture and write output files to out_dir.
pub fn convert_texture(input: &Path, out_dir: &Path) -> Result<TextureAsset, AssetError>;

/// Convert a single OBJ mesh and write output files to out_dir.
pub fn convert_mesh(
    input: &Path,
    out_dir: &Path,
    patch_size: usize,
    index_limit: usize,
) -> Result<MeshAsset, AssetError>;

/// Generate the master mod.rs file that re-exports all asset modules.
pub fn generate_mod_rs(assets: &[GeneratedAsset], out_dir: &Path) -> Result<(), AssetError>;
```

---

## Core Types

### TextureAsset

Represents a converted PNG image in RGBA8888 format, ready for GPU upload.

**Rust Type Signature**:
```rust
pub struct TextureAsset {
    /// Original source filename
    pub source_path: PathBuf,

    /// Texture width (power-of-two, 8-1024)
    pub width: u32,

    /// Texture height (power-of-two, 8-1024)
    pub height: u32,

    /// RGBA8888 pixel data, row-major order
    /// Length: width × height × 4 bytes
    pub pixel_data: Vec<u8>,

    /// Rust identifier derived from filename
    /// Example: "textures/player.png" → "TEXTURES_PLAYER"
    pub identifier: String,
}
```

**Attributes**:
- `source_path`: Original PNG file path for metadata comments
- `width`: Image width in pixels (must be power-of-two)
- `height`: Image height in pixels (must be power-of-two)
- `pixel_data`: Raw RGBA8888 bytes (4 bytes per pixel, row-major)
- `identifier`: Sanitized Rust constant name

**Memory Requirements**:
- Data size: `width × height × 4` bytes
- GPU alignment: 4K (4096 bytes) for base address
- Example: 256×256 texture = 262,144 bytes = 64 pages

**Validation Rules**:
1. Width and height must be power-of-two (8, 16, 32, 64, 128, 256, 512, or 1024)
2. Dimensions must be within GPU range: 8×8 minimum to 1024×1024 maximum
3. Identifier must be valid Rust identifier (alphanumeric + underscore, no leading digit)
4. Pixel data length must equal `width × height × 4`

---

### VertexData

Represents per-vertex attributes for 3D mesh rendering.

**Rust Type Signature**:
```rust
pub struct VertexData {
    /// Position in model space (x, y, z)
    pub position: [f32; 3],

    /// Texture coordinates (u, v)
    pub uv: [f32; 2],

    /// Normal vector (x, y, z)
    pub normal: [f32; 3],
}
```

**Attributes**:
- `position`: 3D coordinates in model space (f32 for precision)
- `uv`: 2D texture coordinates (typically 0.0-1.0 range)
- `normal`: 3D normal vector (not necessarily unit length)

**Default Values**:
- Missing UVs: `[0.0, 0.0]`
- Missing normals: `[0.0, 0.0, 0.0]`

**Binary Layout**:
- Positions: 12 bytes per vertex (3 × f32)
- UVs: 8 bytes per vertex (2 × f32)
- Normals: 12 bytes per vertex (3 × f32)
- Total: 32 bytes per vertex (stored separately, not interleaved)

---

### MeshPatch

Represents a segment of a 3D mesh with vertex and index data fitting within GPU constraints.

**Rust Type Signature**:
```rust
pub struct MeshPatch {
    /// Vertex count (≤16 by default, configurable)
    pub vertex_count: usize,

    /// Index count (≤32 by default, configurable)
    pub index_count: usize,

    /// Vertex positions [x, y, z] flattened
    /// Length: vertex_count × 3
    pub positions: Vec<f32>,

    /// Vertex UVs [u, v] flattened
    /// Length: vertex_count × 2
    pub uvs: Vec<f32>,

    /// Vertex normals [x, y, z] flattened
    /// Length: vertex_count × 3
    pub normals: Vec<f32>,

    /// Triangle indices (local to this patch)
    /// Length: index_count (multiple of 3)
    pub indices: Vec<u16>,

    /// Patch index (0-based) within parent mesh
    pub patch_index: usize,
}
```

**Constraints**:
- `vertex_count ≤ MAX_VERTICES_PER_PATCH` (default: 16, configurable via `--patch-size`)
- `index_count ≤ MAX_INDICES_PER_PATCH` (default: 32, configurable via `--index-limit`)
- `index_count % 3 == 0` (must form complete triangles)
- All indices < `vertex_count` (local indices only)
- `positions.len() == vertex_count × 3`
- `uvs.len() == vertex_count × 2`
- `normals.len() == vertex_count × 3`

**Validation Rules**:
1. Vertex count must not exceed configured limit
2. Index count must not exceed configured limit and must be multiple of 3
3. All indices must be valid (< vertex_count)
4. Attribute arrays must have correct lengths

---

### MeshAsset

Represents a complete converted OBJ mesh, consisting of one or more patches.

**Rust Type Signature**:
```rust
pub struct MeshAsset {
    /// Original source filename
    pub source_path: PathBuf,

    /// Base identifier derived from filename
    /// Example: "meshes/cube.obj" → "MESHES_CUBE"
    pub identifier: String,

    /// All patches comprising this mesh
    pub patches: Vec<MeshPatch>,

    /// Original vertex count before splitting
    pub original_vertex_count: usize,

    /// Original triangle count
    pub original_triangle_count: usize,
}
```

**Attributes**:
- `source_path`: Original OBJ file path for metadata
- `identifier`: Base name for patch identifiers (each patch appends `_PATCH{n}`)
- `patches`: All patches generated from mesh splitting
- `original_vertex_count`: Vertex count in source OBJ (before duplication)
- `original_triangle_count`: Triangle count (after triangulation, before splitting)

**Relationships**:
- One `MeshAsset` → Multiple `MeshPatch` (1-to-many)
- Patches are independent (no cross-patch vertex sharing in initial version)
- Patch identifiers: `{BASE}_PATCH{n}` where n is 0-based index

---

### OutputFile

Represents a pair of generated files (Rust wrapper + binary data).

**Rust Type Signature**:
```rust
pub struct OutputFile {
    /// Rust wrapper filename (e.g., "player.rs")
    pub rust_filename: String,

    /// Rust source code content
    pub rust_source: String,

    /// Binary data files (may be multiple for meshes)
    pub binary_files: Vec<BinaryFile>,
}

pub struct BinaryFile {
    /// Binary filename (e.g., "player.bin", "cube_patch0_pos.bin")
    pub filename: String,

    /// Raw binary data
    pub data: Vec<u8>,
}
```

**Attributes**:
- `rust_filename`: Name of .rs file (derived from identifier)
- `rust_source`: Generated Rust code with `include_bytes!()` macros
- `binary_files`: One or more .bin files referenced by Rust source

**Relationships**:
- One `TextureAsset` → One `OutputFile` with one binary file
- One `MeshPatch` → One `OutputFile` with four binary files (positions, UVs, normals, indices)
- One `MeshAsset` → Multiple `OutputFile` (one per patch)

---

## Transformation Pipeline

### Pipeline Overview

```text
┌─────────────────────────────────────────────────────────┐
│  cargo build -p pico-gs-host                            │
│                                                         │
│  host_app/build.rs                                      │
│    ├─ AssetBuildConfig { source_dir, out_dir, ... }     │
│    ├─ build_assets(&config)                             │
│    │   ├─ Scan host_app/assets/textures/*.png           │
│    │   ├─ Scan host_app/assets/meshes/*.obj             │
│    │   ├─ Convert each asset → OUT_DIR/assets/          │
│    │   └─ Generate OUT_DIR/assets/mod.rs                │
│    └─ println!("cargo:rerun-if-changed=assets/")        │
│                                                         │
│  host_app/src/assets/mod.rs                             │
│    └─ include!(concat!(env!("OUT_DIR"), "/assets/mod.rs"))│
└─────────────────────────────────────────────────────────┘
```

#### Per-Asset Pipelines

```text
┌─────────────┐
│   PNG File  │
└──────┬──────┘
       │
       ▼
┌──────────────────────────────────────┐
│  Load & Validate PNG                 │
│  - image::open()                     │
│  - Check power-of-two dimensions     │
│  - Check size range (8-1024)         │
└──────┬───────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────┐
│  Convert to RGBA8                    │
│  - img.to_rgba8()                    │
│  - Handles grayscale/indexed/RGB     │
└──────┬───────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────┐
│  Create TextureAsset                 │
│  - Extract dimensions                │
│  - Store pixel_data                  │
│  - Generate identifier               │
└──────┬───────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────┐
│  Generate Output Files               │
│  - Create .rs wrapper                │
│  - Write .bin pixel data             │
│  - Add metadata comments             │
└──────┬───────────────────────────────┘
       │
       ▼
┌──────────────┐
│ Output Files │
│ - .rs        │
│ - .bin       │
└──────────────┘


┌─────────────┐
│   OBJ File  │
└──────┬──────┘
       │
       ▼
┌──────────────────────────────────────┐
│  Load & Parse OBJ                    │
│  - tobj::load_obj()                  │
│  - Triangulate: true                 │
│  - Extract positions/UVs/normals     │
└──────┬───────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────┐
│  Handle Missing Attributes           │
│  - Default UVs: [0.0, 0.0]           │
│  - Default normals: [0.0, 0.0, 0.0]  │
└──────┬───────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────┐
│  Convert to Triangle List            │
│  - Flatten face data                 │
│  - Create global index list          │
└──────┬───────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────┐
│  Split into Patches (Greedy)         │
│  - For each triangle:                │
│    * Check if fits in current patch  │
│    * If not, start new patch         │
│    * Add vertices to patch           │
│    * Map global→local indices        │
└──────┬───────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────┐
│  Create MeshAsset                    │
│  - Store all patches                 │
│  - Record original counts            │
│  - Generate identifier               │
└──────┬───────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────┐
│  Generate Output Files (per patch)   │
│  - Create .rs wrapper                │
│  - Write 4 .bin files:               │
│    * positions                       │
│    * UVs                             │
│    * normals                         │
│    * indices                         │
│  - Add metadata comments             │
└──────┬───────────────────────────────┘
       │
       ▼
┌──────────────┐
│ Output Files │
│ - .rs (×n)   │
│ - .bin (×4n) │
└──────────────┘
```

### Transformation Stages

#### Stage 1: Input Validation

**Texture**:
```rust
fn validate_texture_dimensions(width: u32, height: u32) -> Result<(), String> {
    // Check power-of-two
    if !is_power_of_two(width) || !is_power_of_two(height) {
        return Err(format!(
            "Expected power-of-two dimensions, got {}×{}. Try {}×{} or {}×{}.",
            width, height,
            width.next_power_of_two(), height.next_power_of_two(),
            width.next_power_of_two() / 2, height.next_power_of_two() / 2
        ));
    }

    // Check range
    if width < 8 || height < 8 {
        return Err(format!("Dimensions {}×{} below GPU minimum (8×8)", width, height));
    }

    if width > 1024 || height > 1024 {
        return Err(format!("Dimensions {}×{} exceed GPU maximum (1024×1024)", width, height));
    }

    Ok(())
}

fn is_power_of_two(n: u32) -> bool {
    n > 0 && (n & (n - 1)) == 0
}
```

**Mesh**:
```rust
fn validate_mesh_data(positions: &[f32], indices: &[u32]) -> Result<(), String> {
    // Check non-empty
    if positions.is_empty() {
        return Err("Mesh has no vertices".to_string());
    }

    if indices.is_empty() {
        return Err("Mesh has no faces".to_string());
    }

    // Check positions are multiple of 3
    if positions.len() % 3 != 0 {
        return Err(format!("Position count {} not multiple of 3", positions.len()));
    }

    // Check indices are multiple of 3 (triangles)
    if indices.len() % 3 != 0 {
        return Err(format!("Index count {} not multiple of 3", indices.len()));
    }

    // Check indices are in bounds
    let vertex_count = positions.len() / 3;
    for &idx in indices {
        if idx as usize >= vertex_count {
            return Err(format!("Index {} out of bounds (vertex count: {})", idx, vertex_count));
        }
    }

    Ok(())
}
```

#### Stage 2: Format Conversion

**Texture**:
```rust
fn convert_to_rgba8(img: DynamicImage) -> TextureAsset {
    let (width, height) = img.dimensions();
    let rgba_img = img.to_rgba8(); // Handles grayscale/indexed/RGB automatically

    TextureAsset {
        source_path: /* ... */,
        width,
        height,
        pixel_data: rgba_img.into_raw(), // Vec<u8> of RGBA bytes
        identifier: /* ... */,
    }
}
```

**Mesh**:
```rust
fn handle_missing_attributes(
    mesh: &tobj::Mesh,
) -> (Vec<f32>, Vec<f32>, Vec<f32>) {
    let vertex_count = mesh.positions.len() / 3;

    let positions = mesh.positions.clone();

    let uvs = if mesh.texcoords.is_empty() {
        vec![0.0; vertex_count * 2] // Default [0.0, 0.0] for each vertex
    } else {
        mesh.texcoords.clone()
    };

    let normals = if mesh.normals.is_empty() {
        vec![0.0; vertex_count * 3] // Default [0.0, 0.0, 0.0] for each vertex
    } else {
        mesh.normals.clone()
    };

    (positions, uvs, normals)
}
```

#### Stage 3: Mesh Patch Splitting

**Greedy Sequential Algorithm**:
```rust
const MAX_VERTICES_PER_PATCH: usize = 16;
const MAX_INDICES_PER_PATCH: usize = 32;

fn split_into_patches(
    positions: &[f32],
    uvs: &[f32],
    normals: &[f32],
    indices: &[u32],
) -> Vec<MeshPatch> {
    use std::collections::HashMap;

    let mut patches = Vec::new();
    let mut current_patch = MeshPatch::new();
    let mut vertex_map: HashMap<u32, u16> = HashMap::new();

    // Process triangles (indices in groups of 3)
    for tri_indices in indices.chunks_exact(3) {
        // Count how many new vertices we need
        let required_vertices = tri_indices.iter()
            .filter(|&&idx| !vertex_map.contains_key(&idx))
            .count();

        let new_vertex_count = current_patch.vertex_count + required_vertices;
        let new_index_count = current_patch.index_count + 3;

        // Start new patch if limits exceeded
        if new_vertex_count > MAX_VERTICES_PER_PATCH ||
           new_index_count > MAX_INDICES_PER_PATCH {
            patches.push(current_patch);
            current_patch = MeshPatch::new();
            current_patch.patch_index = patches.len();
            vertex_map.clear();
        }

        // Add triangle to current patch
        for &global_idx in tri_indices {
            let local_idx = *vertex_map.entry(global_idx).or_insert_with(|| {
                let local = current_patch.vertex_count as u16;

                // Extract vertex data from global arrays
                let v_idx = global_idx as usize;
                let pos = [
                    positions[v_idx * 3],
                    positions[v_idx * 3 + 1],
                    positions[v_idx * 3 + 2],
                ];
                let uv = [uvs[v_idx * 2], uvs[v_idx * 2 + 1]];
                let norm = [
                    normals[v_idx * 3],
                    normals[v_idx * 3 + 1],
                    normals[v_idx * 3 + 2],
                ];

                // Add to patch
                current_patch.positions.extend_from_slice(&pos);
                current_patch.uvs.extend_from_slice(&uv);
                current_patch.normals.extend_from_slice(&norm);
                current_patch.vertex_count += 1;

                local
            });

            current_patch.indices.push(local_idx);
            current_patch.index_count += 1;
        }
    }

    // Add final patch if non-empty
    if current_patch.vertex_count > 0 {
        patches.push(current_patch);
    }

    patches
}
```

#### Stage 4: Identifier Generation

```rust
fn generate_identifier(source_path: &Path) -> Result<String, String> {
    // Extract parent directory and filename
    let parent = source_path.parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        .unwrap_or("");

    let filename = source_path.file_stem()
        .and_then(|s| s.to_str())
        .ok_or_else(|| "Invalid filename".to_string())?;

    // Combine parent + filename
    let combined = if parent.is_empty() {
        filename.to_string()
    } else {
        format!("{}_{}", parent, filename)
    };

    // Sanitize to valid Rust identifier
    let sanitized = combined
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '_' })
        .collect::<String>()
        .to_uppercase();

    // Ensure doesn't start with digit
    let identifier = if sanitized.chars().next().map_or(false, |c| c.is_numeric()) {
        format!("_{}", sanitized)
    } else {
        sanitized
    };

    Ok(identifier)
}
```

**Examples**:
- `player.png` → `PLAYER`
- `textures/player.png` → `TEXTURES_PLAYER`
- `ui/button-hover.png` → `UI_BUTTON_HOVER`
- `meshes/cube.obj` → `MESHES_CUBE`

#### Stage 5: Output File Generation

**Texture Output**:
```rust
fn generate_texture_output(asset: &TextureAsset, output_dir: &Path) -> OutputFile {
    let identifier = &asset.identifier;
    let rust_filename = format!("{}.rs", identifier.to_lowercase());
    let bin_filename = format!("{}.bin", identifier.to_lowercase());

    // Generate Rust source
    let rust_source = format!(
        r#"// Generated from: {}
// Dimensions: {}×{} RGBA8
// Size: {} bytes ({:.1} KB)
// GPU Requirements: 4K-aligned base address

pub const {}_WIDTH: u32 = {};
pub const {}_HEIGHT: u32 = {};
pub const {}_DATA: &[u8] = include_bytes!("{}");

// Usage in firmware:
// let texture = Texture::from_rgba8({}_WIDTH, {}_HEIGHT, {}_DATA);
"#,
        asset.source_path.display(),
        asset.width,
        asset.height,
        asset.pixel_data.len(),
        asset.pixel_data.len() as f64 / 1024.0,
        identifier,
        asset.width,
        identifier,
        asset.height,
        identifier,
        bin_filename,
        identifier,
        identifier,
        identifier,
    );

    OutputFile {
        rust_filename,
        rust_source,
        binary_files: vec![
            BinaryFile {
                filename: bin_filename,
                data: asset.pixel_data.clone(),
            }
        ],
    }
}
```

**Mesh Output**:
```rust
fn generate_mesh_patch_output(
    asset: &MeshAsset,
    patch: &MeshPatch,
    output_dir: &Path,
) -> OutputFile {
    let base_name = format!("{}_patch{}",
        asset.identifier.to_lowercase(),
        patch.patch_index
    );
    let rust_filename = format!("{}.rs", base_name);

    // Generate binary files
    let pos_bin = format!("{}_pos.bin", base_name);
    let uv_bin = format!("{}_uv.bin", base_name);
    let norm_bin = format!("{}_norm.bin", base_name);
    let idx_bin = format!("{}_idx.bin", base_name);

    let const_name = format!("{}_PATCH{}", asset.identifier, patch.patch_index);

    // Generate Rust source
    let rust_source = format!(
        r#"// Generated from: {} (patch {} of {})
// Vertices: {}, Indices: {} ({} triangles)

pub const {}_VERTEX_COUNT: usize = {};
pub const {}_INDEX_COUNT: usize = {};

pub const {}_POSITIONS: &[u8] = include_bytes!("{}");
pub const {}_UVS: &[u8] = include_bytes!("{}");
pub const {}_NORMALS: &[u8] = include_bytes!("{}");
pub const {}_INDICES: &[u8] = include_bytes!("{}");

// Usage in firmware:
// let positions = bytemuck::cast_slice::<u8, f32>({}_POSITIONS);
// let uvs = bytemuck::cast_slice::<u8, f32>({}_UVS);
// let normals = bytemuck::cast_slice::<u8, f32>({}_NORMALS);
// let indices = bytemuck::cast_slice::<u8, u16>({}_INDICES);
"#,
        asset.source_path.display(),
        patch.patch_index,
        asset.patches.len(),
        patch.vertex_count,
        patch.index_count,
        patch.index_count / 3,
        const_name,
        patch.vertex_count,
        const_name,
        patch.index_count,
        const_name,
        pos_bin,
        const_name,
        uv_bin,
        const_name,
        norm_bin,
        const_name,
        idx_bin,
        const_name,
        const_name,
        const_name,
        const_name,
    );

    // Convert to binary (little-endian)
    let positions_bytes = patch.positions.iter()
        .flat_map(|&f| f.to_le_bytes())
        .collect();

    let uvs_bytes = patch.uvs.iter()
        .flat_map(|&f| f.to_le_bytes())
        .collect();

    let normals_bytes = patch.normals.iter()
        .flat_map(|&f| f.to_le_bytes())
        .collect();

    let indices_bytes = patch.indices.iter()
        .flat_map(|&i| i.to_le_bytes())
        .collect();

    OutputFile {
        rust_filename,
        rust_source,
        binary_files: vec![
            BinaryFile { filename: pos_bin, data: positions_bytes },
            BinaryFile { filename: uv_bin, data: uvs_bytes },
            BinaryFile { filename: norm_bin, data: normals_bytes },
            BinaryFile { filename: idx_bin, data: indices_bytes },
        ],
    }
}
```

---

## Validation Rules Summary

### Texture Validation

| Rule | Check | Error Message |
|------|-------|---------------|
| Dimensions power-of-two | `is_power_of_two(w) && is_power_of_two(h)` | "Expected power-of-two dimensions, got WxH. Try ..." |
| Minimum size | `w >= 8 && h >= 8` | "Dimensions WxH below GPU minimum (8×8)" |
| Maximum size | `w <= 1024 && h <= 1024` | "Dimensions WxH exceed GPU maximum (1024×1024)" |
| Valid pixel data | `data.len() == w × h × 4` | "Pixel data length mismatch" |
| Valid identifier | Rust naming rules | "Invalid identifier: ..." |

### Mesh Validation

| Rule | Check | Error Message |
|------|-------|---------------|
| Non-empty positions | `!positions.is_empty()` | "Mesh has no vertices" |
| Non-empty indices | `!indices.is_empty()` | "Mesh has no faces" |
| Position array alignment | `positions.len() % 3 == 0` | "Position count not multiple of 3" |
| Index array alignment | `indices.len() % 3 == 0` | "Index count not multiple of 3 (not triangles)" |
| Index bounds | `all indices < vertex_count` | "Index N out of bounds (vertex count: M)" |
| Patch vertex limit | `vertices <= MAX_VERTICES` | (Trigger new patch, no error) |
| Patch index limit | `indices <= MAX_INDICES` | (Trigger new patch, no error) |

---

## Type Relationships

```text
TextureAsset
    ↓
OutputFile (1 .rs + 1 .bin)


MeshAsset
    ├─ MeshPatch[0] → OutputFile (1 .rs + 4 .bin)
    ├─ MeshPatch[1] → OutputFile (1 .rs + 4 .bin)
    └─ MeshPatch[n] → OutputFile (1 .rs + 4 .bin)


VertexData
    └─ Used within MeshPatch (conceptual, not stored as struct)
```

---

## Binary Format Specification

All multi-byte values are stored in **little-endian** byte order (native for RP2350).

### Texture Binary (`.bin`)

```text
Offset | Type | Count        | Description
-------|------|--------------|-------------
0      | u8   | w × h × 4    | RGBA8888 pixel data, row-major
```

**Example**: 8×8 texture = 256 bytes (64 pixels × 4 bytes/pixel)

### Mesh Position Binary (`_pos.bin`)

```text
Offset | Type | Count         | Description
-------|------|---------------|-------------
0      | f32  | vertex_count × 3 | [x0, y0, z0, x1, y1, z1, ...]
```

**Example**: 16 vertices = 192 bytes (16 vertices × 3 components × 4 bytes)

### Mesh UV Binary (`_uv.bin`)

```text
Offset | Type | Count         | Description
-------|------|---------------|-------------
0      | f32  | vertex_count × 2 | [u0, v0, u1, v1, ...]
```

**Example**: 16 vertices = 128 bytes (16 vertices × 2 components × 4 bytes)

### Mesh Normal Binary (`_norm.bin`)

```text
Offset | Type | Count         | Description
-------|------|---------------|-------------
0      | f32  | vertex_count × 3 | [x0, y0, z0, x1, y1, z1, ...]
```

**Example**: 16 vertices = 192 bytes (16 vertices × 3 components × 4 bytes)

### Mesh Index Binary (`_idx.bin`)

```text
Offset | Type | Count       | Description
-------|------|-------------|-------------
0      | u16  | index_count | [i0, i1, i2, i3, ...]
```

**Example**: 32 indices = 64 bytes (32 indices × 2 bytes)

---

## Usage Examples

### Primary Usage: build.rs (Recommended)

```rust
// host_app/build.rs
use asset_build_tool::{AssetBuildConfig, build_assets};
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());

    let config = AssetBuildConfig {
        source_dir: manifest_dir.join("assets"),
        out_dir: out_dir.join("assets"),
        patch_size: 16,
        index_limit: 32,
    };

    // Tell Cargo to rerun if source assets change
    println!("cargo:rerun-if-changed={}", config.source_dir.display());

    let generated = build_assets(&config).expect("Asset build failed");

    // Emit rerun-if-changed for each source file
    for asset in &generated {
        println!("cargo:rerun-if-changed={}", asset.source_path.display());
    }
}
```

```rust
// host_app/src/assets/mod.rs
include!(concat!(env!("OUT_DIR"), "/assets/mod.rs"));
```

### Library API: Single Texture

```rust
use asset_build_tool::convert_texture;
use std::path::Path;

let asset = convert_texture(
    Path::new("host_app/assets/textures/player.png"),
    Path::new("/tmp/out"),
)?;
// asset.width, asset.height, asset.identifier are available
```

### Library API: Single Mesh

```rust
use asset_build_tool::convert_mesh;
use std::path::Path;

let asset = convert_mesh(
    Path::new("host_app/assets/meshes/cube.obj"),
    Path::new("/tmp/out"),
    16, // patch_size
    32, // index_limit
)?;
// asset.patches.len() gives the number of patches
```

---

## Summary

This data model provides:

1. **Clear type definitions** for all core entities
2. **Validation rules** ensuring GPU compatibility
3. **Transformation pipeline** from source files to binary output
4. **Binary format specification** for RP2350 firmware integration
5. **Code examples** demonstrating practical usage

All types are designed to be simple, testable, and maintainable while meeting the requirements specified in `spec.md`.
