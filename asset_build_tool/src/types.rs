use std::path::PathBuf;

/// Converted PNG texture in RGBA8888 format
#[derive(Debug, Clone)]
pub struct TextureAsset {
    /// Source filename (for metadata)
    pub source: PathBuf,
    /// Texture width (power-of-two, 8-1024)
    pub width: u32,
    /// Texture height (power-of-two, 8-1024)
    pub height: u32,
    /// RGBA8888 pixel data (row-major)
    pub data: Vec<u8>,
    /// Rust identifier (sanitized from filename)
    pub identifier: String,
}

impl TextureAsset {
    /// Calculate size in bytes
    pub fn size_bytes(&self) -> usize {
        self.data.len()
    }

    /// Check if dimensions are power-of-two
    pub fn is_valid_dimensions(&self) -> bool {
        self.width.is_power_of_two()
            && self.height.is_power_of_two()
            && self.width >= 8
            && self.width <= 1024
            && self.height >= 8
            && self.height <= 1024
    }
}

/// Per-vertex attribute data
#[derive(Debug, Clone, Copy)]
pub struct VertexData {
    /// Position (x, y, z) in model space
    pub position: [f32; 3],
    /// Texture coordinates (u, v)
    pub uv: [f32; 2],
    /// Normal vector (x, y, z)
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

/// A mesh patch with ≤16 vertices and ≤32 indices
#[derive(Debug, Clone)]
pub struct MeshPatch {
    /// Source filename (for metadata)
    pub source: PathBuf,
    /// Vertex data (positions, UVs, normals)
    pub vertices: Vec<VertexData>,
    /// Triangle indices (u16 for GPU compatibility)
    pub indices: Vec<u16>,
    /// Rust identifier (sanitized from filename)
    pub identifier: String,
    /// Patch index (for multi-patch meshes)
    pub patch_index: usize,
}

impl MeshPatch {
    /// Validate patch constraints
    pub fn is_valid(&self) -> bool {
        self.vertices.len() <= 16
            && self.indices.len() <= 32
            && self.indices.len() % 3 == 0 // Must be triangles
    }

    /// Get triangle count
    pub fn triangle_count(&self) -> usize {
        self.indices.len() / 3
    }
}

/// Complete mesh asset (may contain multiple patches)
#[derive(Debug, Clone)]
pub struct MeshAsset {
    /// Source filename (for metadata)
    pub source: PathBuf,
    /// All patches that make up this mesh
    pub patches: Vec<MeshPatch>,
    /// Rust identifier (sanitized from filename)
    pub identifier: String,
    /// Total original vertex count (before patching)
    pub original_vertex_count: usize,
}

impl MeshAsset {
    /// Get total vertices across all patches
    pub fn total_vertices(&self) -> usize {
        self.patches.iter().map(|p| p.vertices.len()).sum()
    }

    /// Get total indices across all patches
    pub fn total_indices(&self) -> usize {
        self.patches.iter().map(|p| p.indices.len()).sum()
    }

    /// Get patch count
    pub fn patch_count(&self) -> usize {
        self.patches.len()
    }
}

/// Generated Rust source file
#[derive(Debug, Clone)]
pub struct OutputFile {
    /// Rust source file path
    pub rust_file: PathBuf,
    /// Binary data file path
    pub binary_file: PathBuf,
    /// Rust source code content
    pub rust_content: String,
    /// Binary data content
    pub binary_data: Vec<u8>,
}

/// Binary data file (positions, UVs, normals, indices)
#[derive(Debug, Clone)]
pub struct BinaryFile {
    /// File path
    pub path: PathBuf,
    /// Binary data (little-endian f32 or u16)
    pub data: Vec<u8>,
}
