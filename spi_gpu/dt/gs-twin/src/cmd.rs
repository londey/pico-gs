//! GPU command stream decoder.
//!
//! This module defines the GPU's command set — the same register writes and
//! draw-call packets that the RP2350 host firmware emits over SPI. The twin
//! consumes the same binary command stream format as the RTL, ensuring both
//! interpret commands identically.
//!
//! ## Command stream format
//!
//! Commands are serialized as a sequence of `GpuCommand` variants. For test
//! fixtures, we use bincode for compact binary encoding. The same fixtures
//! feed both:
//!   - This Rust twin (via `Gpu::execute`)
//!   - Verilator testbenches (via a C++ loader that reads the same format)

use crate::math::{Mat4, Rgb565, TexVec2, Vec3};
use serde::{Deserialize, Serialize};

/// A single GPU command, corresponding to one or more register writes
/// or a draw-call trigger in the RTL.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum GpuCommand {
    /// No-op / sync barrier.
    Nop,

    /// Set the model-view-projection matrix.
    /// In the RTL this is a sequence of register writes to the matrix bank.
    SetMvpMatrix(Mat4),

    /// Set the viewport transform (origin + dimensions).
    SetViewport {
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    },

    /// Clear the framebuffer to a solid color.
    ClearColor(Rgb565),

    /// Clear the depth buffer to a given value (raw 16-bit).
    ClearDepth(u16),

    /// Load vertex data into GPU-local SRAM at the given base address.
    LoadVertices {
        base_addr: u32,
        vertices: Vec<Vertex>,
    },

    /// Load index data for indexed draw calls.
    LoadIndices {
        base_addr: u32,
        indices: Vec<u16>,
    },

    /// Load a texture into SRAM.
    LoadTexture {
        slot: u8,
        width: u16,
        height: u16,
        /// RGB565 texel data, row-major.
        data: Vec<u16>,
    },

    /// Configure depth test mode.
    SetDepthTest(DepthFunc),

    /// Configure backface culling.
    SetCullMode(CullMode),

    /// Bind a texture slot for subsequent draws.
    BindTexture(u8),

    /// Draw non-indexed triangles from loaded vertex data.
    DrawArrays {
        base_addr: u32,
        vertex_count: u32,
    },

    /// Draw indexed triangles.
    DrawIndexed {
        vertex_base: u32,
        index_base: u32,
        index_count: u32,
    },
}

/// Vertex format matching the GPU's SRAM vertex layout.
///
/// All fields use the same fixed-point formats as the RTL's vertex
/// input registers.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct Vertex {
    /// Object-space position (Q16.16 per component).
    pub position: Vec3,
    /// Texture coordinates (Q2.14 per component).
    pub uv: TexVec2,
    /// Vertex color (packed RGB565).
    pub color: Rgb565,
}

/// Depth comparison function.
///
/// # RTL Implementation Notes
/// Encoded as a 3-bit register field. The comparison is performed
/// on raw 16-bit Z-buffer values (Q4.12 interpreted as signed i16).
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub enum DepthFunc {
    Never,
    #[default]
    Less,
    LessEqual,
    Equal,
    Greater,
    GreaterEqual,
    NotEqual,
    Always,
}

/// Triangle winding / cull mode.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub enum CullMode {
    #[default]
    None,
    Backface,
    Frontface,
}

// ── Serialization helpers ───────────────────────────────────────────────────

/// Encode a command stream to bincode bytes (for test fixtures).
pub fn encode_stream(commands: &[GpuCommand]) -> Vec<u8> {
    bincode::serialize(commands).expect("command stream serialization failed")
}

/// Decode a command stream from bincode bytes.
pub fn decode_stream(bytes: &[u8]) -> Result<Vec<GpuCommand>, bincode::Error> {
    bincode::deserialize(bytes)
}
