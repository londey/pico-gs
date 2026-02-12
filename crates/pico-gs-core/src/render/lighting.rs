// Spec-ref: unit_024_lighting_calculator.md `85a7cbe7c1a2f427` 2026-02-12
//! Gouraud lighting calculation for directional lights + ambient.

use crate::render::{AmbientLight, DirectionalLight};
use glam::Vec3;

/// Compute Gouraud lighting for a single vertex.
///
/// Evaluates: ambient + sum(max(0, dot(N, L[i])) * light_color[i])
/// for up to 4 directional lights plus ambient.
///
/// Returns lit vertex color as [R, G, B, A] with channels clamped to 0-255.
pub fn compute_lighting(
    normal: Vec3,
    base_color: [u8; 4],
    lights: &[DirectionalLight; 4],
    ambient: &AmbientLight,
) -> [u8; 4] {
    // Start with ambient contribution.
    let mut lit_r = ambient.color.x;
    let mut lit_g = ambient.color.y;
    let mut lit_b = ambient.color.z;

    // Add directional light contributions.
    for light in lights {
        let n_dot_l = normal.dot(light.direction).max(0.0);
        lit_r += n_dot_l * light.color.x;
        lit_g += n_dot_l * light.color.y;
        lit_b += n_dot_l * light.color.z;
    }

    // Modulate by base vertex color and clamp to 0-255.
    let r = ((lit_r * base_color[0] as f32) as u32).min(255) as u8;
    let g = ((lit_g * base_color[1] as f32) as u32).min(255) as u8;
    let b = ((lit_b * base_color[2] as f32) as u32).min(255) as u8;
    let a = base_color[3];

    [r, g, b, a]
}
