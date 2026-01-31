//! Demo definitions and per-frame update logic.

use crate::gpu::vertex::GpuVertex;
use crate::render::{AmbientLight, DirectionalLight};
use glam::Vec3;

/// Active demo selection.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Demo {
    GouraudTriangle,
    TexturedTriangle,
    SpinningTeapot,
}

impl Demo {
    /// Default demo on boot.
    pub fn default() -> Self {
        Demo::GouraudTriangle
    }
}

/// Gouraud-shaded triangle demo: three vertices with distinct colors.
/// Returns 3 pre-packed GpuVertex values at screen-space positions.
pub fn gouraud_triangle_vertices() -> [GpuVertex; 3] {
    [
        // Top-center: Red
        GpuVertex::from_color_position(255, 0, 0, 255, 320.0, 80.0, 0.5),
        // Bottom-left: Green
        GpuVertex::from_color_position(0, 255, 0, 255, 120.0, 400.0, 0.5),
        // Bottom-right: Blue
        GpuVertex::from_color_position(0, 0, 255, 255, 520.0, 400.0, 0.5),
    ]
}

/// Textured triangle demo: three vertices with UV coordinates.
/// White vertex color so texture is unmodulated. W=1.0 (orthographic).
pub fn textured_triangle_vertices() -> [GpuVertex; 3] {
    [
        // Top-center: UV (0.5, 0.0)
        GpuVertex::from_full(255, 255, 255, 255, 320.0, 80.0, 0.5, 0.5, 0.0, 1.0),
        // Bottom-left: UV (0.0, 1.0)
        GpuVertex::from_full(255, 255, 255, 255, 120.0, 400.0, 0.5, 0.0, 1.0, 1.0),
        // Bottom-right: UV (1.0, 1.0)
        GpuVertex::from_full(255, 255, 255, 255, 520.0, 400.0, 0.5, 1.0, 1.0, 1.0),
    ]
}

/// Teapot scene lighting: key light + fill light + 2 unused slots.
pub fn teapot_lights() -> [DirectionalLight; 4] {
    [
        // Key light: upper-right, warm white.
        DirectionalLight {
            direction: Vec3::new(0.5, 0.8, 0.3).normalize(),
            color: Vec3::new(0.8, 0.8, 0.75),
        },
        // Fill light: left side, cool dim.
        DirectionalLight {
            direction: Vec3::new(-0.6, 0.3, 0.5).normalize(),
            color: Vec3::new(0.2, 0.2, 0.25),
        },
        // Unused.
        DirectionalLight {
            direction: Vec3::Y,
            color: Vec3::ZERO,
        },
        // Unused.
        DirectionalLight {
            direction: Vec3::Y,
            color: Vec3::ZERO,
        },
    ]
}

/// Teapot scene ambient light.
pub fn teapot_ambient() -> AmbientLight {
    AmbientLight {
        color: Vec3::splat(0.15),
    }
}

/// Teapot base surface color (light gray, opaque).
pub const TEAPOT_COLOR: [u8; 4] = [200, 200, 210, 255];

/// Rotation speed in radians per frame (at 60 fps → ~1 revolution per 6 seconds).
pub const TEAPOT_ROTATION_SPEED: f32 = core::f32::consts::TAU / 360.0;
