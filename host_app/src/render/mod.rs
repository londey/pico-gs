//! Render command types and inter-core queue definitions.

pub mod commands;
pub mod lighting;
pub mod mesh;
pub mod transform;

use crate::gpu::vertex::GpuVertex;
use glam::{Mat4, Vec3};
use heapless::spsc;

/// Maximum vertices per mesh patch.
pub const MAX_PATCH_VERTICES: usize = 128;
/// Maximum indices per mesh patch (128 vertices × ~3 triangles each, rounded up).
pub const MAX_PATCH_INDICES: usize = 384;

/// Render command queue capacity.
///
/// Teapot demo submits ~290 commands per frame (clear + mode + ~288 triangles + vsync).
/// Queue depth of 64 allows Core 0 to run ahead of Core 1 by up to 64 commands,
/// reducing stall frequency and improving overlap between transform/lighting on
/// Core 0 and SPI transmission on Core 1.
///
/// Memory: 64 × ~80 bytes (largest variant) ≈ 5 KB SRAM.
pub const QUEUE_CAPACITY: usize = 64;

/// The inter-core render command queue type.
pub type CommandQueue = spsc::Queue<RenderCommand, QUEUE_CAPACITY>;
/// Producer end of the command queue (owned by Core 0).
pub type CommandProducer<'a> = spsc::Producer<'a, RenderCommand, QUEUE_CAPACITY>;
/// Consumer end of the command queue (owned by Core 1).
pub type CommandConsumer<'a> = spsc::Consumer<'a, RenderCommand, QUEUE_CAPACITY>;

/// A single vertex in object space.
#[derive(Clone, Copy, Debug)]
pub struct Vertex {
    pub position: Vec3,
    pub normal: Vec3,
    pub color: [u8; 4], // RGBA
    pub uv: [f32; 2],   // U, V
}

/// A batch of vertices and indices extracted from a mesh.
#[derive(Clone, Debug)]
pub struct MeshPatch {
    pub vertices: heapless::Vec<Vertex, MAX_PATCH_VERTICES>,
    pub indices: heapless::Vec<u16, MAX_PATCH_INDICES>,
}

/// Directional light source for Gouraud shading.
#[derive(Clone, Copy, Debug)]
pub struct DirectionalLight {
    /// Unit direction vector (toward the light).
    pub direction: Vec3,
    /// Light color/intensity per channel (0.0-1.0).
    pub color: Vec3,
}

/// Ambient light level.
#[derive(Clone, Copy, Debug)]
pub struct AmbientLight {
    pub color: Vec3,
}

/// Rendering flags for a mesh patch.
#[derive(Clone, Copy, Debug)]
pub struct RenderFlags {
    pub gouraud: bool,
    pub textured: bool,
    pub z_test: bool,
    pub z_write: bool,
}

impl RenderFlags {
    /// Convert to GPU TRI_MODE register value.
    pub fn to_tri_mode(&self) -> u64 {
        let mut mode = 0u64;
        if self.gouraud {
            mode |= crate::gpu::registers::TRI_MODE_GOURAUD;
        }
        if self.z_test {
            mode |= crate::gpu::registers::TRI_MODE_Z_TEST;
        }
        if self.z_write {
            mode |= crate::gpu::registers::TRI_MODE_Z_WRITE;
        }
        mode
    }
}

/// Render command: the unit of work flowing from Core 0 to Core 1.
///
/// Lightweight commands go through the SPSC queue directly.
/// Large data (mesh patches) use a separate shared buffer mechanism.
#[derive(Clone, Copy, Debug)]
pub enum RenderCommand {
    /// Submit a pre-packed screen-space triangle directly to the GPU.
    /// Used by US1 (Gouraud) and US2 (Textured) where Core 0 provides
    /// already-packed vertices (no transform/lighting needed on Core 1).
    SubmitScreenTriangle(ScreenTriangleCommand),
    /// Wait for GPU vertical sync and swap framebuffers.
    WaitVsync,
    /// Clear the framebuffer to a solid color.
    ClearFramebuffer(ClearCommand),
    /// Set the triangle rendering mode (TRI_MODE register).
    SetTriMode(RenderFlags),
    /// Upload texture data to GPU memory (by texture ID).
    UploadTexture(UploadTextureCommand),
}

/// Command to submit a pre-packed triangle (3 GpuVertex).
#[derive(Clone, Copy, Debug)]
pub struct ScreenTriangleCommand {
    pub v0: GpuVertex,
    pub v1: GpuVertex,
    pub v2: GpuVertex,
    pub textured: bool,
}

/// Command to upload texture data to GPU memory.
#[derive(Clone, Copy, Debug)]
pub struct UploadTextureCommand {
    /// GPU SRAM target address (4K aligned).
    pub gpu_address: u32,
    /// Index into a global texture data table.
    pub texture_id: u8,
}

/// Command to clear the framebuffer.
#[derive(Clone, Copy, Debug)]
pub struct ClearCommand {
    /// Fill color (R, G, B, A).
    pub color: [u8; 4],
    /// Also clear the z-buffer to far plane.
    pub clear_depth: bool,
}
