use std::path::PathBuf;

/// Configuration for the asset build process (used by build.rs).
#[derive(Debug, Clone)]
pub struct AssetBuildConfig {
    /// Directory containing source assets (textures/*.png, meshes/*.obj).
    pub source_dir: PathBuf,
    /// Output directory for generated files (typically OUT_DIR/assets).
    pub out_dir: PathBuf,
    /// Maximum vertices per mesh patch (default: 16).
    pub patch_size: usize,
    /// Maximum indices per mesh patch (default: 32).
    pub index_limit: usize,
}

/// Metadata about a generated asset file, returned by the build process.
#[derive(Debug, Clone)]
pub struct GeneratedAsset {
    /// Rust module name for this asset.
    pub module_name: String,
    /// Rust identifier prefix (uppercase).
    pub identifier: String,
    /// Path to the generated .rs file (relative to out_dir).
    pub rs_path: PathBuf,
    /// Source file that produced this asset (for rerun-if-changed).
    pub source_path: PathBuf,
}

/// Converted PNG texture in RGBA8888 format.
#[derive(Debug, Clone)]
pub struct TextureAsset {
    /// Source filename (for metadata).
    pub source: PathBuf,
    /// Texture width (power-of-two, 8-1024).
    pub width: u32,
    /// Texture height (power-of-two, 8-1024).
    pub height: u32,
    /// RGBA8888 pixel data (row-major).
    pub data: Vec<u8>,
    /// Rust identifier (sanitized from filename).
    pub identifier: String,
}

impl TextureAsset {
    /// Calculate size in bytes.
    pub fn size_bytes(&self) -> usize {
        self.data.len()
    }
}

/// Per-vertex attribute data.
#[derive(Debug, Clone, Copy)]
pub struct VertexData {
    /// Position (x, y, z) in model space.
    pub position: [f32; 3],
    /// Texture coordinates (u, v).
    pub uv: [f32; 2],
    /// Normal vector (x, y, z).
    pub normal: [f32; 3],
}

impl Default for VertexData {
    fn default() -> Self {
        Self {
            position: [0.0, 0.0, 0.0],
            uv: [0.0, 0.0],
            normal: [0.0, 0.0, 0.0],
        }
    }
}

/// Raw mesh patch output from the splitter (f32 vertex data, u16 indices).
///
/// This is the intermediate representation between splitting and quantization.
#[derive(Debug, Clone)]
pub struct RawMeshPatch {
    /// Vertex data (positions, UVs, normals) in f32.
    pub vertices: Vec<VertexData>,
    /// Triangle indices (u16, local to this patch).
    pub indices: Vec<u16>,
    /// Patch index (0-based) within parent mesh.
    pub patch_index: usize,
}

/// A quantized mesh patch with SoA blob data, ready for firmware inclusion.
#[derive(Debug, Clone)]
pub struct MeshPatch {
    /// Contiguous SoA blob: quantized positions (u16), normals (i16),
    /// UVs (i16), indices (u16 LE).
    pub data: Vec<u8>,
    /// Patch AABB minimum in model space (from original f32 positions).
    pub aabb_min: [f32; 3],
    /// Patch AABB maximum in model space (from original f32 positions).
    pub aabb_max: [f32; 3],
    /// Number of vertices (for SoA offset calculation).
    pub vertex_count: usize,
    /// Number of index entries.
    pub entry_count: usize,
    /// Patch index (0-based) within parent mesh.
    pub patch_index: usize,
}

/// Complete mesh asset (may contain multiple patches).
#[derive(Debug, Clone)]
pub struct MeshAsset {
    /// Source filename (for metadata).
    pub source: PathBuf,
    /// All quantized patches that make up this mesh.
    pub patches: Vec<MeshPatch>,
    /// Rust identifier (sanitized from filename).
    pub identifier: String,
    /// Total original vertex count (before patching).
    pub original_vertex_count: usize,
    /// Total original triangle count (after triangulation).
    pub original_triangle_count: usize,
    /// Overall mesh AABB minimum (quantization coordinate system).
    pub aabb_min: [f32; 3],
    /// Overall mesh AABB maximum (quantization coordinate system).
    pub aabb_max: [f32; 3],
}

impl MeshAsset {
    /// Get total vertices across all patches.
    pub fn total_vertices(&self) -> usize {
        self.patches.iter().map(|p| p.vertex_count).sum()
    }

    /// Get total index entries across all patches.
    pub fn total_entries(&self) -> usize {
        self.patches.iter().map(|p| p.entry_count).sum()
    }

    /// Get patch count.
    pub fn patch_count(&self) -> usize {
        self.patches.len()
    }
}
