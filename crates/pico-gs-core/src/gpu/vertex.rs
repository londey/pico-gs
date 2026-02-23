// Spec-ref: unit_022_gpu_driver_layer.md `c44d854d73502f21` 2026-02-23
//! GpuVertex: pre-packed vertex data for GPU register writes.

use crate::math::fixed;

/// A vertex packed into GPU register format, ready for submission.
#[derive(Clone, Copy, Debug)]
pub struct GpuVertex {
    /// Packed COLOR register value (0x00): COLOR0 (diffuse) in [63:32], COLOR1 (specular)
    /// in [31:0]. Currently only COLOR0 is populated: [39:32]=R, [47:40]=G, [55:48]=B,
    /// [63:56]=A.
    pub color_packed: u64,

    /// Packed UV0_UV1 register value (0x01): [15:0]=UV0_UQ, [31:16]=UV0_VQ,
    /// [47:32]=UV1_UQ, [63:48]=UV1_VQ (Q1.15 signed fixed-point).
    pub uv_packed: u64,

    /// Packed vertex position + 1/W for VERTEX_NOKICK (0x06) / VERTEX_KICK_012 (0x07):
    /// [15:0]=X (Q12.4), [31:16]=Y (Q12.4), [47:32]=Z (16-bit unsigned),
    /// [63:48]=Q=1/W (Q1.15).
    pub position_packed: u64,
}

impl GpuVertex {
    /// Create a GpuVertex with only color and position (no texture).
    pub fn from_color_position(r: u8, g: u8, b: u8, a: u8, x: f32, y: f32, z: f32) -> Self {
        Self {
            color_packed: pack_color(r, g, b, a),
            uv_packed: 0,
            position_packed: pack_position(x, y, z),
        }
    }

    /// Create a GpuVertex with color, position, and texture coordinates.
    #[allow(clippy::too_many_arguments)]
    pub fn from_full(
        r: u8,
        g: u8,
        b: u8,
        a: u8,
        x: f32,
        y: f32,
        z: f32,
        u: f32,
        v: f32,
        w: f32,
    ) -> Self {
        Self {
            color_packed: pack_color(r, g, b, a),
            uv_packed: pack_uv(u, v, w),
            position_packed: pack_position(x, y, z),
        }
    }
}

/// Pack RGBA color into GPU COLOR register format.
pub fn pack_color(r: u8, g: u8, b: u8, a: u8) -> u64 {
    ((a as u64) << 24) | ((b as u64) << 16) | ((g as u64) << 8) | (r as u64)
}

/// Pack perspective-correct UV + 1/W into GPU UV0 register format.
/// u, v are texture coordinates; w is the clip-space W value.
pub fn pack_uv(u: f32, v: f32, w: f32) -> u64 {
    let inv_w = 1.0 / w;
    let uq = fixed::f32_to_1_15(u * inv_w);
    let vq = fixed::f32_to_1_15(v * inv_w);
    let q = fixed::f32_to_1_15(inv_w);
    ((q as u64 & 0xFFFF) << 32) | ((vq as u64 & 0xFFFF) << 16) | (uq as u64 & 0xFFFF)
}

/// Pack screen-space position into GPU VERTEX register format.
pub fn pack_position(x: f32, y: f32, z: f32) -> u64 {
    let x_fixed = fixed::f32_to_12_4(x);
    let y_fixed = fixed::f32_to_12_4(y);
    let z_fixed = fixed::f32_to_z25(z);
    ((z_fixed as u64) << 32) | ((y_fixed as u64 & 0xFFFF) << 16) | (x_fixed as u64 & 0xFFFF)
}
