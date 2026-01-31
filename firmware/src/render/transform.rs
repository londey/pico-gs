//! MVP transform pipeline: matrix transforms, viewport mapping, perspective divide.

use crate::gpu::registers;
use crate::math::fixed;
use glam::{Mat4, Vec3, Vec4};

/// Screen-space vertex after transform, ready for GPU packing.
#[derive(Clone, Copy)]
pub struct ScreenVertex {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub w: f32,
}

/// Transform an object-space vertex by the MVP matrix, perform perspective
/// divide and viewport mapping.
///
/// Returns screen-space coordinates suitable for GPU register packing:
/// - x, y in pixel coordinates (0..639, 0..479)
/// - z normalized to 0.0 (near) .. 1.0 (far)
/// - w is the clip-space W for perspective-correct texture interpolation
pub fn transform_vertex(position: Vec3, mvp: &Mat4) -> ScreenVertex {
    // Apply MVP: object space → clip space.
    let clip = *mvp * Vec4::new(position.x, position.y, position.z, 1.0);

    // Perspective divide: clip space → NDC (normalized device coordinates).
    let w = clip.w;
    let inv_w = if w.abs() > 1e-6 { 1.0 / w } else { 1.0 };
    let ndc_x = clip.x * inv_w;
    let ndc_y = clip.y * inv_w;
    let ndc_z = clip.z * inv_w;

    // Viewport transform: NDC (-1..+1) → screen pixels.
    // NDC x: -1 = left, +1 = right → screen 0..639
    // NDC y: -1 = bottom, +1 = top → screen 479..0 (Y flipped)
    let screen_w = registers::SCREEN_WIDTH as f32;
    let screen_h = registers::SCREEN_HEIGHT as f32;

    let sx = (ndc_x + 1.0) * 0.5 * (screen_w - 1.0);
    let sy = (1.0 - ndc_y) * 0.5 * (screen_h - 1.0);

    // Z: map NDC [-1,+1] to [0, 1] for GPU 25-bit depth.
    let sz = (ndc_z + 1.0) * 0.5;

    ScreenVertex {
        x: sx,
        y: sy,
        z: sz.clamp(0.0, 1.0),
        w,
    }
}

/// Transform a normal vector by the inverse-transpose of the model-view matrix.
/// The result is renormalized for lighting calculations.
pub fn transform_normal(normal: Vec3, mv: &Mat4) -> Vec3 {
    // For an orthogonal MV matrix, inverse-transpose = MV itself.
    // For general MV, we need the 3x3 inverse-transpose.
    // Using the 3x3 upper-left of MV as approximation (correct for uniform scale).
    let n4 = *mv * Vec4::new(normal.x, normal.y, normal.z, 0.0);
    Vec3::new(n4.x, n4.y, n4.z).normalize_or_zero()
}

/// Back-face culling test using screen-space cross product.
/// Returns true if the triangle is front-facing (should be drawn).
pub fn is_front_facing(v0: &ScreenVertex, v1: &ScreenVertex, v2: &ScreenVertex) -> bool {
    let e1x = v1.x - v0.x;
    let e1y = v1.y - v0.y;
    let e2x = v2.x - v0.x;
    let e2y = v2.y - v0.y;
    // 2D cross product: positive = counter-clockwise (front-facing).
    let cross = e1x * e2y - e1y * e2x;
    cross > 0.0
}

/// Build a perspective projection matrix.
/// fov_y: vertical field of view in radians.
/// aspect: width / height (e.g., 640/480 = 1.333).
/// near, far: clipping planes.
pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) -> Mat4 {
    Mat4::perspective_rh(fov_y, aspect, near, far)
}

/// Build a look-at view matrix (right-handed).
pub fn look_at(eye: Vec3, target: Vec3, up: Vec3) -> Mat4 {
    Mat4::look_at_rh(eye, target, up)
}

/// Build a Y-axis rotation matrix.
pub fn rotate_y(angle: f32) -> Mat4 {
    Mat4::from_rotation_y(angle)
}
