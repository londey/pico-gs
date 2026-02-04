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

/// A mesh patch with bounded vertex and index counts.
#[derive(Debug, Clone)]
pub struct MeshPatch {
    /// Vertex data (positions, UVs, normals).
    pub vertices: Vec<VertexData>,
    /// Triangle indices (u16 for GPU compatibility).
    pub indices: Vec<u16>,
    /// Patch index (0-based) within parent mesh.
    pub patch_index: usize,
}

impl MeshPatch {
    /// Get triangle count.
    pub fn triangle_count(&self) -> usize {
        self.indices.len() / 3
    }
}

/// Complete mesh asset (may contain multiple patches).
#[derive(Debug, Clone)]
pub struct MeshAsset {
    /// Source filename (for metadata).
    pub source: PathBuf,
    /// All patches that make up this mesh.
    pub patches: Vec<MeshPatch>,
    /// Rust identifier (sanitized from filename).
    pub identifier: String,
    /// Total original vertex count (before patching).
    pub original_vertex_count: usize,
    /// Total original triangle count (after triangulation).
    pub original_triangle_count: usize,
}

impl MeshAsset {
    /// Get total vertices across all patches.
    pub fn total_vertices(&self) -> usize {
        self.patches.iter().map(|p| p.vertices.len()).sum()
    }

    /// Get total indices across all patches.
    pub fn total_indices(&self) -> usize {
        self.patches.iter().map(|p| p.indices.len()).sum()
    }

    /// Get patch count.
    pub fn patch_count(&self) -> usize {
        self.patches.len()
    }
}
