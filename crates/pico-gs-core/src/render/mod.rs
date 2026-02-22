// Spec-ref: unit_026_intercore_queue.md `254452866b60d251` 2026-02-19
//! Render command types and data structures.
//!
//! Platform-agnostic render types. The inter-core SPSC queue (RP2350-specific)
//! is defined in pico-gs-rp2350.

pub mod commands;
pub mod lighting;
pub mod mesh;
pub mod transform;

use crate::gpu::vertex::GpuVertex;
use glam::Vec3;

/// Maximum vertices per mesh patch.
pub const MAX_PATCH_VERTICES: usize = 128;
/// Maximum indices per mesh patch (128 vertices x ~3 triangles each, rounded up).
pub const MAX_PATCH_INDICES: usize = 384;

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
    /// Enable color buffer writes. False = Z-only prepass.
    pub color_write: bool,
}

impl RenderFlags {
    /// Convert to GPU RENDER_MODE register value.
    pub fn to_render_mode(&self) -> u64 {
        let mut mode = 0u64;
        if self.gouraud {
            mode |= crate::gpu::registers::RENDER_MODE_GOURAUD;
        }
        if self.z_test {
            mode |= crate::gpu::registers::RENDER_MODE_Z_TEST;
        }
        if self.z_write {
            mode |= crate::gpu::registers::RENDER_MODE_Z_WRITE;
        }
        if self.color_write {
            mode |= crate::gpu::registers::RENDER_MODE_COLOR_WRITE;
        }
        mode
    }

    /// Backward-compatible alias for `to_render_mode()`.
    pub fn to_tri_mode(&self) -> u64 {
        self.to_render_mode()
    }
}

/// Render command: the unit of work for GPU submission.
///
/// On RP2350 these flow through an SPSC queue from Core 0 to Core 1.
/// On PC they are executed directly in the main loop.
#[derive(Clone, Copy, Debug)]
pub enum RenderCommand {
    /// Submit a pre-packed screen-space triangle directly to the GPU.
    SubmitScreenTriangle(ScreenTriangleCommand),
    /// Wait for GPU vertical sync and swap framebuffers.
    WaitVsync,
    /// Clear the framebuffer to a solid color.
    ClearFramebuffer(ClearCommand),
    /// Set the rendering mode (RENDER_MODE register).
    SetRenderMode(RenderFlags),
    /// Set depth range clipping (Z_RANGE register).
    SetZRange {
        /// Minimum Z value (inclusive). Fragments with Z < min are discarded.
        z_min: u16,
        /// Maximum Z value (inclusive). Fragments with Z > max are discarded.
        z_max: u16,
    },
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
    /// GPU SDRAM dword address (22-bit, byte address >> 3).
    pub gpu_dword_addr: u32,
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
