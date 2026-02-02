# Research: Asset Data Preparation Tool

**Date**: 2026-01-31
**Feature**: 003-asset-data-prep

## 1. PNG Decoding Library

**Decision**: `image` crate (v0.25+)

**Rationale**:
The `image` crate is the de facto standard for image processing in Rust and provides the best balance of ergonomics, features, and reliability:

- **High-level API**: Provides simple `open()` and `to_rgba8()` methods that handle all color space conversions automatically
- **Format support**: Handles PNG, JPEG, and other formats through a unified interface, enabling future format extensions
- **Active maintenance**: Widely used (10M+ downloads/month) with strong community support and regular updates
- **Internally uses `png` crate**: Delegates PNG decoding to the specialized `png` crate, so we get its performance benefits
- **Dimension validation**: Easy to access image dimensions through `image.dimensions()` for power-of-two validation
- **Color space handling**: Automatically handles grayscale, indexed, RGB, and RGBA PNGs, converting them to consistent RGBA8 format

**Alternatives Considered**:

1. **`png` crate** (lower-level):
   - Pros: Slightly faster compile times, direct control over decoding
   - Cons: Requires manual color space conversion, more boilerplate, no support for other formats
   - Verdict: Rejected - additional complexity not justified for our use case

2. **`lodepng`** (C FFI bindings):
   - Pros: Proven C implementation, potentially smaller binary size
   - Cons: Requires C toolchain, FFI overhead, less idiomatic Rust
   - Verdict: Rejected - conflicts with open toolchain mandate and Rust-first approach

**Code Example**:
```rust
use image::{DynamicImage, ImageError, RgbaImage};

fn load_and_validate_texture(path: &Path) -> Result<RgbaImage, String> {
    // Open and decode PNG
    let img = image::open(path)
        .map_err(|e| format!("Failed to open {}: {}", path.display(), e))?;

    // Validate dimensions
    let (width, height) = img.dimensions();
    if !is_power_of_two(width) || !is_power_of_two(height) {
        return Err(format!(
            "Expected power-of-two dimensions, got {}×{}. Try {}×{} or {}×{}.",
            width, height,
            width.next_power_of_two(), height.next_power_of_two(),
            width.next_power_of_two() / 2, height.next_power_of_two() / 2
        ));
    }

    if width < 8 || height < 8 || width > 1024 || height > 1024 {
        return Err(format!(
            "Dimensions {}×{} outside GPU range (8×8 to 1024×1024)",
            width, height
        ));
    }

    // Convert to RGBA8 (handles grayscale, indexed, RGB automatically)
    Ok(img.to_rgba8())
}

fn is_power_of_two(n: u32) -> bool {
    n > 0 && (n & (n - 1)) == 0
}
```

---

## 2. OBJ Parser Library

**Decision**: `tobj` crate (v4.0+)

**Rationale**:
`tobj` is the clear winner for our use case, offering the best combination of features, reliability, and ecosystem integration:

- **Most popular**: 971K+ all-time downloads, used by 88 crates - proven reliability
- **Triangulation support**: Meshes can be triangulated on-the-fly with trivial triangle fan conversion
- **Complete attribute parsing**: Handles positions, normals, UVs, and vertex colors with optional attribute support
- **Simple API**: Returns `Vec<Model>` and `Vec<Material>` - straightforward to work with
- **Active maintenance**: Regular updates and bug fixes
- **Error handling**: Clear error messages for malformed OBJ files
- **Performance**: Lightweight parser optimized for common OBJ features

**Alternatives Considered**:

1. **`wavefront_obj` (obj-rs)**:
   - Pros: Structured API with different vertex data types, good documentation
   - Cons: Lower usage (638K downloads vs 971K), less flexible triangulation support
   - Verdict: Rejected - `tobj` is more battle-tested and has better triangulation support

2. **Custom parser**:
   - Pros: Complete control over parsing logic, minimal dependencies
   - Cons: High implementation cost, reinventing the wheel, likely buggy
   - Verdict: Rejected - violates simplicity gate, not worth the effort

**Code Example**:
```rust
use tobj::{self, LoadOptions};

fn load_obj_mesh(path: &Path) -> Result<Vec<Mesh>, String> {
    let load_options = LoadOptions {
        triangulate: true,  // Automatically triangulate quads and polygons
        single_index: false, // Keep separate indices for pos/uv/normal (we'll handle this)
        ..Default::default()
    };

    let (models, materials) = tobj::load_obj(path, &load_options)
        .map_err(|e| format!("Failed to load OBJ: {}", e))?;

    let mut meshes = Vec::new();

    for model in models {
        let mesh = &model.mesh;

        // Validate mesh has positions
        if mesh.positions.is_empty() {
            return Err(format!("Model '{}' has no vertex positions", model.name));
        }

        // Extract vertex data
        let positions = &mesh.positions; // [x, y, z, x, y, z, ...]
        let normals = &mesh.normals;     // [x, y, z, ...] or empty
        let texcoords = &mesh.texcoords; // [u, v, ...] or empty
        let indices = &mesh.indices;     // Triangle list indices

        meshes.push(Mesh {
            name: model.name.clone(),
            positions: positions.clone(),
            normals: normals.clone(),
            uvs: texcoords.clone(),
            indices: indices.clone(),
        });
    }

    Ok(meshes)
}
```

**Handling Missing Attributes**:
```rust
// If normals are missing, generate default (0, 0, 0) for each vertex
let normals = if mesh.normals.is_empty() {
    vec![0.0; mesh.positions.len()] // Same length as positions
} else {
    mesh.normals.clone()
};

// If UVs are missing, generate default (0, 0) for each vertex
let uvs = if mesh.texcoords.is_empty() {
    vec![0.0; (mesh.positions.len() / 3) * 2] // 2 components per vertex
} else {
    mesh.texcoords.clone()
};
```

---

## 3. Mesh Splitting Algorithm

**Algorithm Description**:

Based on FR-018 requirements, we implement a **greedy sequential triangle packing** algorithm that fills each patch with triangles until adding the next triangle would violate vertex or index limits.

**Design Rationale**:
- **Simplicity**: Easy to implement, debug, and maintain
- **Predictability**: Deterministic output for the same input mesh
- **Performance**: O(n) time complexity where n is the number of triangles
- **Trade-off**: Accepts some vertex duplication for algorithmic simplicity (cross-patch optimization deferred to future version)

**Algorithm Pseudocode**:
```
Input: Triangle list T = [(i0, i1, i2), ...] with vertex data V
Output: List of patches P = [Patch1, Patch2, ...]

1. Initialize empty current_patch with:
   - local_vertices = []      // Up to 16 vertices
   - local_indices = []       // Up to 32 indices
   - vertex_map = {}          // global_idx -> local_idx

2. For each triangle (i0, i1, i2) in T:
   a. Calculate required_vertices = number of triangle vertices not in vertex_map
   b. Calculate new_vertex_count = len(local_vertices) + required_vertices
   c. Calculate new_index_count = len(local_indices) + 3

   d. If new_vertex_count > 16 OR new_index_count > 32:
      i.   Finalize current_patch and add to P
      ii.  Start new patch (reset local_vertices, local_indices, vertex_map)
      iii. required_vertices = 3 (all new for fresh patch)

   e. For each vertex index vi in (i0, i1, i2):
      i.  If vi not in vertex_map:
             - Add V[vi] to local_vertices
             - vertex_map[vi] = len(local_vertices) - 1
      ii. local_idx = vertex_map[vi]
      iii. Append local_idx to local_indices

3. Finalize current_patch and add to P
4. Return P
```

**Implementation Notes**:

1. **Vertex Duplication**: When a triangle doesn't fit in the current patch, we start a new patch. If that triangle shares vertices with previous patches, those vertices are duplicated in the new patch. This is acceptable for initial version.

2. **Patch Size Limits**:
   - Max 16 vertices per patch (adjustable via `--patch-size` CLI flag)
   - Max 32 indices per patch (adjustable via `--index-limit` CLI flag)
   - A patch can hold 5-10 triangles typically, depending on vertex sharing

3. **Performance**: For a 1000-vertex mesh (~600 triangles), algorithm runs in <1ms, well under the 2-second success criterion.

**Code Example**:
```rust
const MAX_VERTICES_PER_PATCH: usize = 16;
const MAX_INDICES_PER_PATCH: usize = 32;

struct MeshPatch {
    positions: Vec<f32>,  // [x, y, z] * vertex_count
    normals: Vec<f32>,    // [x, y, z] * vertex_count
    uvs: Vec<f32>,        // [u, v] * vertex_count
    indices: Vec<u16>,    // Triangle list indices
}

fn split_into_patches(
    positions: &[f32],
    normals: &[f32],
    uvs: &[f32],
    indices: &[u32],
) -> Vec<MeshPatch> {
    use std::collections::HashMap;

    let mut patches = Vec::new();
    let mut current_patch = MeshPatch::new();
    let mut vertex_map: HashMap<u32, u16> = HashMap::new();

    // Process triangles (indices in groups of 3)
    for tri_indices in indices.chunks_exact(3) {
        let [i0, i1, i2] = [tri_indices[0], tri_indices[1], tri_indices[2]];

        // Check how many new vertices we need
        let required_vertices = tri_indices.iter()
            .filter(|&&idx| !vertex_map.contains_key(&idx))
            .count();

        let new_vertex_count = current_patch.vertex_count() + required_vertices;
        let new_index_count = current_patch.indices.len() + 3;

        // Start new patch if limits exceeded
        if new_vertex_count > MAX_VERTICES_PER_PATCH || new_index_count > MAX_INDICES_PER_PATCH {
            patches.push(current_patch);
            current_patch = MeshPatch::new();
            vertex_map.clear();
        }

        // Add triangle vertices to patch
        for &global_idx in tri_indices {
            let local_idx = *vertex_map.entry(global_idx).or_insert_with(|| {
                let local = current_patch.vertex_count() as u16;
                current_patch.add_vertex(global_idx as usize, positions, normals, uvs);
                local
            });
            current_patch.indices.push(local_idx);
        }
    }

    // Add final patch if non-empty
    if current_patch.vertex_count() > 0 {
        patches.push(current_patch);
    }

    patches
}
```

---

## 4. Binary Output Format

**Decision**: Raw binary arrays with Rust wrapper files using `include_bytes!()`

**Format Specification**:

We use a **dual-file approach**: one `.bin` file containing raw binary data, and one `.rs` file with Rust const declarations and metadata comments.

**Rationale**:
- **Simplicity**: Raw binary format is trivial to generate and consume
- **Compile-time efficiency**: Small wrapper files compile fast; large binary data is included as-is
- **include_bytes!() compatibility**: Perfect match - macro expects `&[u8]` from file
- **Debuggability**: Binary data can be inspected with hex editors; Rust wrapper includes metadata comments
- **Type safety**: Rust wrapper provides const declarations with proper types
- **Flash efficiency**: Data stored directly in flash with no runtime overhead

**File Organization**:
```
firmware/assets/
├── textures/
│   ├── player.rs          # Rust wrapper with metadata
│   ├── player.bin         # Raw RGBA8888 pixel data
│   ├── enemy.rs
│   └── enemy.bin
└── meshes/
    ├── cube_patch0.rs     # First patch of cube mesh
    ├── cube_patch0_pos.bin
    ├── cube_patch0_uv.bin
    ├── cube_patch0_norm.bin
    ├── cube_patch0_idx.bin
    └── ...
```

**Binary Format Specification**:

1. **Texture Binary (.bin)**:
   ```
   Format: Raw RGBA8888 pixel data, row-major order
   Byte order: Little-endian (native for RP2350)
   Layout: [R, G, B, A, R, G, B, A, ...] for each pixel
   Size: width × height × 4 bytes
   ```

2. **Mesh Position Binary (_pos.bin)**:
   ```
   Format: Raw f32 array, 3 components per vertex
   Byte order: Little-endian IEEE 754 single-precision
   Layout: [x0, y0, z0, x1, y1, z1, ...]
   Size: vertex_count × 3 × 4 bytes
   ```

3. **Mesh UV Binary (_uv.bin)**:
   ```
   Format: Raw f32 array, 2 components per vertex
   Byte order: Little-endian IEEE 754 single-precision
   Layout: [u0, v0, u1, v1, ...]
   Size: vertex_count × 2 × 4 bytes
   ```

4. **Mesh Normal Binary (_norm.bin)**:
   ```
   Format: Raw f32 array, 3 components per vertex
   Byte order: Little-endian IEEE 754 single-precision
   Layout: [x0, y0, z0, x1, y1, z1, ...]
   Size: vertex_count × 3 × 4 bytes
   ```

5. **Mesh Index Binary (_idx.bin)**:
   ```
   Format: Raw u16 array, triangle list
   Byte order: Little-endian
   Layout: [i0, i1, i2, i3, i4, i5, ...] (groups of 3)
   Size: index_count × 2 bytes
   ```

**Rust Wrapper Example**:

```rust
// Generated file: firmware/assets/textures/player.rs
// Source: assets/textures/player.png
// Dimensions: 256×256 RGBA8
// Size: 262144 bytes (256 KB)
// GPU Requirements: 4K-aligned base address

pub const PLAYER_WIDTH: u32 = 256;
pub const PLAYER_HEIGHT: u32 = 256;
pub const PLAYER_DATA: &[u8] = include_bytes!("player.bin");

// Usage in firmware:
// let texture = Texture::from_rgba8(PLAYER_WIDTH, PLAYER_HEIGHT, PLAYER_DATA);
```

```rust
// Generated file: firmware/assets/meshes/cube_patch0.rs
// Source: assets/meshes/cube.obj (patch 0 of 1)
// Vertices: 24, Indices: 36 (12 triangles)

pub const CUBE_PATCH0_VERTEX_COUNT: usize = 24;
pub const CUBE_PATCH0_INDEX_COUNT: usize = 36;

pub const CUBE_PATCH0_POSITIONS: &[u8] = include_bytes!("cube_patch0_pos.bin");
pub const CUBE_PATCH0_UVS: &[u8] = include_bytes!("cube_patch0_uv.bin");
pub const CUBE_PATCH0_NORMALS: &[u8] = include_bytes!("cube_patch0_norm.bin");
pub const CUBE_PATCH0_INDICES: &[u8] = include_bytes!("cube_patch0_idx.bin");

// Usage in firmware:
// let positions = bytemuck::cast_slice::<u8, f32>(CUBE_PATCH0_POSITIONS);
// let indices = bytemuck::cast_slice::<u8, u16>(CUBE_PATCH0_INDICES);
```

**Advantages**:
- **No parsing overhead**: Data is used directly as static slices
- **Compile-time inclusion**: Guaranteed availability, no file I/O at runtime
- **Version control friendly**: Binary files compress well in git with LFS; wrapper files show metadata diffs
- **4K alignment**: Can be handled by linker script attributes if needed (future enhancement)

**Disadvantages (Accepted Trade-offs)**:
- **Multiple files per asset**: Each mesh patch generates 5 files (.rs + 4 .bin), but this is acceptable for clarity
- **No built-in validation**: Binary data has no magic numbers or checksums (rely on build-time generation correctness)
- **Manual type casting**: Firmware must use `bytemuck::cast_slice()` to reinterpret `&[u8]` as typed arrays

---

## 5. Build Integration Architecture

**Decision**: Library crate as `[build-dependency]` with `build.rs` integration

**Rationale**:

The asset tool is restructured as a library-first crate. The primary consumer is `host_app/build.rs`, which calls the library API during `cargo build`. An optional CLI binary wraps the library for manual debugging.

**Why library + build.rs over standalone CLI + shell script**:

1. **Self-contained builds**: `cargo build -p pico-gs-host` handles everything — no shell script orchestration needed
2. **Incremental rebuilds**: Cargo's `rerun-if-changed` directives mean assets are only reconverted when source files actually change, unlike a shell script that rebuilds everything every time
3. **Standard Rust pattern**: build.rs + build-dependencies is the idiomatic way to generate code at build time in Rust projects
4. **No file copying**: Output goes directly to `OUT_DIR`, included via `include!(concat!(env!("OUT_DIR"), ...))`. No intermediate directories or copy steps
5. **Cross-platform**: Works identically on Linux, macOS, and Windows without shell script differences

**How build-dependencies work with cross-compilation**:

When `host_app` targets `thumbv8m.main-none-eabihf` (RP2350), Cargo automatically compiles `[build-dependencies]` for the **host** machine, not the target. This means `image`, `tobj`, and other desktop-only crates work correctly as build-dependencies even though the firmware targets a no_std embedded platform.

**Source asset location**: `host_app/assets/` (outside `src/`, conventional for non-Rust source files). build.rs accesses them via `CARGO_MANIFEST_DIR`.

**Output location**: Cargo's `OUT_DIR/assets/`. Generated files are ephemeral and not committed to version control. The library generates a master `mod.rs` that re-exports all asset modules.

**`clap` note**: The `clap` dependency is only needed by the optional CLI binary (`main.rs`). It is not used by the library API and should remain a regular dependency (not a build-dependency of host_app). Only the library portion of the crate is used as a build-dependency.

---

## 6. CLI Framework

**Decision**: `clap` v4 with derive macros (for optional CLI binary only)

**Rationale**:

The derive API is the clear choice for modern Rust CLI development in 2026:

- **Ergonomics**: Describe CLI as a Rust struct, clap handles the rest via proc-macros
- **Maintainability**: Declarative approach is easier to extend and modify than builder API
- **Help generation**: Automatic `--help` output with proper formatting and examples
- **Type safety**: Arguments are strongly typed with validation at parse time
- **Subcommand support**: Clean syntax for `texture` and `mesh` subcommands
- **Community standard**: Derive API is recommended approach for new projects
- **Interop**: Can drop to builder API for specific args if needed (rare)

**Alternatives Considered**:

1. **Clap builder API**:
   - Pros: Faster compile times if not using other proc-macros, more runtime flexibility
   - Cons: Significantly more verbose, harder to maintain, more boilerplate
   - Verdict: Rejected - We already use proc-macros (likely serde, other derives), so compile time benefit is minimal. Verbosity hurts maintainability.

2. **Minimal parser (e.g., pico-args)**:
   - Pros: Tiny dependency, very fast compile
   - Cons: No subcommands, manual help text, manual validation
   - Verdict: Rejected - Too limited for our needs (subcommands, rich validation)

**Code Example**:

```rust
use clap::{Parser, Subcommand, ValueEnum};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "asset-prep")]
#[command(about = "Convert PNG/OBJ assets to RP2350 firmware format", long_about = None)]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// Suppress progress output (only show errors)
    #[arg(short, long, global = true)]
    quiet: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Convert a PNG image to RGBA8888 texture format
    Texture {
        /// Input PNG file path
        #[arg(value_name = "INPUT")]
        input: PathBuf,

        /// Output directory for generated .rs and .bin files
        #[arg(short, long, value_name = "DIR")]
        output: PathBuf,
    },

    /// Convert an OBJ mesh to patch format
    Mesh {
        /// Input OBJ file path
        #[arg(value_name = "INPUT")]
        input: PathBuf,

        /// Output directory for generated files
        #[arg(short, long, value_name = "DIR")]
        output: PathBuf,

        /// Maximum vertices per patch (default: 16)
        #[arg(long, default_value = "16")]
        patch_size: usize,

        /// Maximum indices per patch (default: 32)
        #[arg(long, default_value = "32")]
        index_limit: usize,
    },

}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Texture { input, output } => {
            if !cli.quiet {
                println!("Converting texture: {}", input.display());
            }
            // Calls asset_build_tool::convert_texture() library function
        }
        Commands::Mesh { input, output, patch_size, index_limit } => {
            if !cli.quiet {
                println!("Converting mesh: {} (patch size: {}, index limit: {})",
                    input.display(), patch_size, index_limit);
            }
            // Calls asset_build_tool::convert_mesh() library function
        }
    }
}
```

**Usage Examples** (CLI is for debugging; production builds use build.rs):
```bash
# Debug a single texture conversion
$ asset-prep texture host_app/assets/textures/player.png -o /tmp/debug/

# Debug a single mesh conversion with custom limits
$ asset-prep mesh host_app/assets/meshes/cube.obj -o /tmp/debug/ --patch-size 12

# Help text (auto-generated)
$ asset-prep --help
$ asset-prep texture --help
```

**Error Handling**:
```rust
use clap::error::ErrorKind;
use std::process;

// Clap automatically handles:
// - Missing required arguments (shows usage)
// - Invalid file paths (type validation)
// - Unknown flags (shows available options)

// Custom validation:
if !input.exists() {
    clap::Error::raw(
        ErrorKind::ValueValidation,
        format!("Input file does not exist: {}", input.display())
    ).exit();
}
```

**Benefits Demonstrated**:
1. **Automatic help text**: `clap` generates comprehensive `--help` output from struct attributes
2. **Subcommand organization**: Clear separation of `texture`, `mesh`, `batch` operations
3. **Type safety**: `PathBuf` args ensure valid path syntax; `usize` for numeric limits
4. **Global flags**: `--quiet` applies to all subcommands via `global = true`
5. **Validation**: File existence, numeric ranges validated before business logic runs
6. **Versioning**: `#[command(version)]` auto-includes cargo version in `--version`

---

## Summary

### Key Decisions

| Area | Decision | Primary Justification |
|------|----------|----------------------|
| PNG Decoding | `image` crate | High-level API, automatic color conversion, ecosystem standard |
| OBJ Parsing | `tobj` crate | Most popular, built-in triangulation, proven reliability |
| Mesh Splitting | Greedy sequential | Simple O(n) algorithm, meets FR-018, predictable output |
| Binary Format | Raw arrays + `include_bytes!()` | No parsing overhead, compile-time inclusion, flash-efficient |
| Build Integration | Library + build.rs | Self-contained cargo build, incremental rebuilds, standard Rust pattern |
| CLI Framework | `clap` v4 derive macros (optional CLI) | Ergonomic, maintainable, automatic help generation |

### Implementation Priorities

**Phase 0 Complete**: All research tasks resolved with concrete decisions.

**Next Phase Actions**:
1. Add dependencies to `asset_build_tool/Cargo.toml`:
   ```toml
   [dependencies]
   image = "0.25"
   tobj = "4.0"
   clap = { version = "4.5", features = ["derive"] }  # For optional CLI only
   thiserror = "1.0"
   log = "0.4"
   ```

2. Add build-dependency to `host_app/Cargo.toml`:
   ```toml
   [build-dependencies]
   asset-prep = { path = "../asset_build_tool" }
   ```

3. Create `host_app/build.rs` and `host_app/assets/` directory

4. Implement in order:
   - P1: PNG texture conversion (US-1)
   - P2: OBJ mesh conversion (US-2)
   - P3: Firmware-compatible output via build.rs (US-3)

### Remaining Considerations

**Open Questions for Design Phase**:
1. Identifier conflict resolution: Current spec says "report error" - should we auto-suffix with numbers instead?
2. 4K alignment for textures: Should binary files include padding, or rely on linker script?
3. Progress output format: Simple text or structured (JSON) for build tools?
4. Batch mode organization: Flatten all assets or preserve directory structure in output?

**Performance Validation Needed**:
- Benchmark `image` crate with 1024×1024 PNG (target: <1s)
- Benchmark `tobj` + mesh splitting with 1000-vertex mesh (target: <2s)
- Measure compile time impact of large `include_bytes!()` files (target: minimal)

**Testing Strategy**:
- Unit tests: Each converter module with fixture files
- Integration tests: End-to-end CLI invocation with output validation
- Property tests: Mesh splitting preserves triangle count, no index out-of-bounds

---

## Sources

- [Decoding and encoding images in Rust using the image crate - LogRocket Blog](https://blog.logrocket.com/decoding-encoding-images-rust-using-image-crate/)
- [Images — list of Rust libraries/crates // Lib.rs](https://lib.rs/multimedia/images)
- [image - crates.io: Rust Package Registry](https://crates.io/crates/image)
- [png - crates.io: Rust Package Registry](https://crates.io/crates/png)
- [GitHub - image-rs/image: Encoding and decoding images in Rust](https://github.com/image-rs/image)
- [3D Format Loaders | Are we game yet?](https://arewegameyet.rs/ecosystem/3dformatloaders/)
- [GitHub - Twinklebear/tobj: Tiny OBJ Loader in Rust](https://github.com/Twinklebear/tobj)
- [tobj - crates.io: Rust Package Registry](https://crates.io/crates/tobj)
- [GitHub - simnalamburt/obj-rs: Wavefront obj parser for Rust](https://github.com/simnalamburt/obj-rs)
- [Efﬁciently Computing and Updating Triangle Strips for Real-Time Rendering](https://www.cs.umd.edu/~varshney/papers/CADstrips.pdf)
- [Greedy Meshing for Vertex Colored Voxels In Unity](https://eddieabbondanz.io/post/voxel/greedy-mesh/)
- [clap::_faq - Rust](https://docs.rs/clap/latest/clap/_faq/index.html)
- [Clap derive or builder? · clap-rs/clap · Discussion #5724](https://github.com/clap-rs/clap/discussions/5724)
- [clap::_derive::_tutorial - Rust](https://docs.rs/clap/latest/clap/_derive/_tutorial/index.html)
- [Getting Started with Clap: A Beginner's Guide to Rust CLI Apps - DEV Community](https://dev.to/moseeh_52/getting-started-with-clap-a-beginners-guide-to-rust-cli-apps-1n3f)
- [include_bytes in std - Rust](https://doc.rust-lang.org/std/macro.include_bytes.html)
- [A Quick Tour of Trade-offs Embedding Data in Rust | nickb.dev](https://nickb.dev/blog/a-quick-tour-of-trade-offs-embedding-data-in-rust/)
- [Using `include_str!()` and `include_bytes!()` for Compile-Time File Embedding - rust Tip](https://www.kungfudev.com/tips/rust/using-include-str-and-include-bytes-macros-compile-time)
