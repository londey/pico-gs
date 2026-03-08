//! Graphics pipeline stages.
//!
//! Each stage is a pure function: `fn stage(input) -> output`. No shared
//! mutable state flows between stages except through the explicit transaction
//! types defined here. This makes each stage independently testable and
//! keeps the algorithm expression clear.
//!
//! ```text
//!   GpuCommand ──► command_proc ──► (state updates + DrawCalls)
//!   DrawCall   ──► vertex       ──► Vec<ClipVertex>
//!   ClipVertex ──► clip         ──► Vec<ScreenTriangle>
//!   ScreenTri  ──► rasterize    ──► Iterator<Fragment>
//!   Fragment   ──► fragment     ──► pixel writes to Framebuffer
//! ```
//!
//! # Fixed-Point Contract
//!
//! Every inter-stage type uses the exact Q formats defined in [`crate::math`].
//! These types are the *wire formats* — they correspond to the signals
//! that cross module boundaries in the RTL. If Verilator dumps an
//! inter-stage signal, it should match the twin's intermediate value
//! bit-for-bit.

pub mod clip;
pub mod command_proc;
pub mod fragment;
pub mod rasterize;
pub mod vertex;

use crate::cmd::{CullMode, DepthFunc};
use crate::math::{
    Bary3, Coord, Depth, EdgeAccum, Mat4, Rgb565, ScreenCoord, TexCoord, TexVec2, Vec4, WRecip,
};
use serde::{Deserialize, Serialize};

// ── GPU state (set by command processor) ────────────────────────────────────

/// Mutable GPU configuration state, updated by the command processor
/// as it interprets register-write commands.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GpuState {
    pub mvp: Mat4,
    pub viewport: Viewport,
    pub depth_func: DepthFunc,
    pub cull_mode: CullMode,
    pub bound_texture: Option<u8>,
}

impl Default for GpuState {
    fn default() -> Self {
        Self {
            mvp: Mat4::identity(),
            viewport: Viewport {
                x: 0,
                y: 0,
                width: 320,
                height: 240,
            },
            depth_func: DepthFunc::Less,
            cull_mode: CullMode::None,
            bound_texture: None,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Viewport {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}

// ── Inter-stage transaction types ───────────────────────────────────────────
//
// These match the data that crosses module boundaries in the RTL.
// Each field documents its Q format; Verilator signal dumps should
// match these values bit-for-bit.

/// Output of vertex stage: a vertex in clip space (before perspective divide).
///
/// # Wire Format
/// 4× Q16.16 clip coordinates + Q2.14 UVs + 16-bit RGB565 color = 18 bytes.
#[derive(Debug, Clone, Copy)]
pub struct ClipVertex {
    /// Clip-space position (Q16.16 per component).
    pub clip_pos: Vec4,
    /// Texture coordinates passed through (Q2.14).
    pub uv: TexVec2,
    /// Vertex color (RGB565, unmodified).
    pub color: Rgb565,
}

/// A triangle in screen space, ready for rasterization.
#[derive(Debug, Clone, Copy)]
pub struct ScreenTriangle {
    pub v: [ScreenVertex; 3],
}

/// A single vertex in screen space (after perspective divide + viewport).
///
/// # Wire Format
/// ```text
///   x, y:     Q12.4  (16-bit) — pixel coords with sub-pixel precision
///   z:        Q4.12  (16-bit) — depth for Z-buffer comparison
///   w_recip:  Q0.16  (16-bit) — 1/w for perspective-correct interpolation
///   uv:       Q2.14  (16-bit each) — texture coordinates
///   color:    RGB565 (16-bit) — vertex color
/// ```
/// Total: 12 bytes per vertex, 36 bytes per triangle.
#[derive(Debug, Clone, Copy)]
pub struct ScreenVertex {
    /// Screen-space X (Q12.4: pixel coordinate with 4-bit sub-pixel).
    pub x: ScreenCoord,
    /// Screen-space Y (Q12.4: pixel coordinate with 4-bit sub-pixel).
    pub y: ScreenCoord,
    /// Depth value for Z-buffer (Q4.12).
    pub z: Depth,
    /// Reciprocal W for perspective-correct interpolation (Q0.16 unsigned).
    pub w_recip: WRecip,
    /// Texture coordinates (Q2.14 each).
    pub uv: TexVec2,
    /// Vertex color (RGB565).
    pub color: Rgb565,
}

/// A rasterized fragment — one pixel candidate from triangle traversal.
///
/// # Wire Format
/// ```text
///   x, y:     integer pixel coordinates (u16)
///   depth:    Q4.12  (16-bit) — interpolated depth
///   uv:       Q2.14  (16-bit each) — perspective-correct tex coords
///   color:    RGB565 (16-bit) — interpolated vertex color
///   bary:     Q16.16 (3× 32-bit) — barycentric coords (debug only)
/// ```
#[derive(Debug, Clone, Copy)]
pub struct Fragment {
    /// Framebuffer X coordinate (integer pixel).
    pub x: u16,
    /// Framebuffer Y coordinate (integer pixel).
    pub y: u16,
    /// Interpolated depth (Q4.12) for Z-buffer test.
    pub depth: Depth,
    /// Interpolated texture coordinates (Q2.14, perspective-correct).
    pub uv: TexVec2,
    /// Interpolated vertex color (RGB565).
    pub color: Rgb565,
    /// Barycentric coordinates (Q16.16, for debug / Verilator comparison).
    pub bary: Bary3,
}
