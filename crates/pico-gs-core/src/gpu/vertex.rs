// Spec-ref: unit_022_gpu_driver_layer.md `ae21a1cf39c446b2` 2026-02-13
//! GpuVertex: pre-packed vertex data for GPU register writes.

use crate::math::fixed;

/// A vertex packed into GPU register format, ready for submission.
#[derive(Clone, Copy, Debug)]
pub struct GpuVertex {
    /// Packed COLOR register value: [31:24]=A, [23:16]=B, [15:8]=G, [7:0]=R.
    pub color_packed: u64,
    /// Packed UV0 register value: [47:32]=Q(1.15), [31:16]=VQ(1.15), [15:0]=UQ(1.15).
    pub uv_packed: u64,
    /// Packed VERTEX register value: [56:32]=Z(25), [31:16]=Y(12.4), [15:0]=X(12.4).
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
