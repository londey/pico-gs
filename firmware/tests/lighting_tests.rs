//! Unit tests for Gouraud lighting calculations.
//!
//! Re-implements lighting logic for host testing (firmware crate is no_std).

use glam::Vec3;

// --- Re-implemented types and functions (mirrors render/mod.rs + render/lighting.rs) ---

struct DirectionalLight {
    direction: Vec3,
    color: Vec3,
}

struct AmbientLight {
    color: Vec3,
}

fn compute_lighting(
    normal: Vec3,
    base_color: [u8; 4],
    lights: &[DirectionalLight; 4],
    ambient: &AmbientLight,
) -> [u8; 4] {
    let mut lit_r = ambient.color.x;
    let mut lit_g = ambient.color.y;
    let mut lit_b = ambient.color.z;

    for light in lights {
        let n_dot_l = normal.dot(light.direction).max(0.0);
        lit_r += n_dot_l * light.color.x;
        lit_g += n_dot_l * light.color.y;
        lit_b += n_dot_l * light.color.z;
    }

    let r = ((lit_r * base_color[0] as f32) as u32).min(255) as u8;
    let g = ((lit_g * base_color[1] as f32) as u32).min(255) as u8;
    let b = ((lit_b * base_color[2] as f32) as u32).min(255) as u8;
    let a = base_color[3];

    [r, g, b, a]
}

/// Create a zero-intensity directional light (for filling unused slots).
fn zero_light() -> DirectionalLight {
    DirectionalLight {
        direction: Vec3::Y,
        color: Vec3::ZERO,
    }
}

// --- Tests ---

mod ambient_only {
    use super::*;

    #[test]
    fn full_ambient_white_surface() {
        let lights = [zero_light(), zero_light(), zero_light(), zero_light()];
        let ambient = AmbientLight { color: Vec3::ONE };
        let result = compute_lighting(Vec3::Y, [255, 255, 255, 255], &lights, &ambient);
        assert_eq!(result, [255, 255, 255, 255]);
    }

    #[test]
    fn half_ambient_white_surface() {
        let lights = [zero_light(), zero_light(), zero_light(), zero_light()];
        let ambient = AmbientLight {
            color: Vec3::splat(0.5),
        };
        let result = compute_lighting(Vec3::Y, [255, 255, 255, 255], &lights, &ambient);
        // 0.5 * 255 = 127
        assert_eq!(result[0], 127);
        assert_eq!(result[1], 127);
        assert_eq!(result[2], 127);
    }

    #[test]
    fn ambient_modulated_by_base_color() {
        let lights = [zero_light(), zero_light(), zero_light(), zero_light()];
        let ambient = AmbientLight { color: Vec3::ONE };
        let result = compute_lighting(Vec3::Y, [128, 64, 32, 200], &lights, &ambient);
        assert_eq!(result, [128, 64, 32, 200]);
    }

    #[test]
    fn zero_ambient_gives_black() {
        let lights = [zero_light(), zero_light(), zero_light(), zero_light()];
        let ambient = AmbientLight { color: Vec3::ZERO };
        let result = compute_lighting(Vec3::Y, [255, 255, 255, 255], &lights, &ambient);
        assert_eq!(result, [0, 0, 0, 255]);
    }
}

mod single_directional {
    use super::*;

    #[test]
    fn light_facing_normal_full_contribution() {
        let lights = [
            DirectionalLight {
                direction: Vec3::Y,
                color: Vec3::ONE,
            },
            zero_light(),
            zero_light(),
            zero_light(),
        ];
        let ambient = AmbientLight { color: Vec3::ZERO };
        // Normal facing up, light pointing up → dot = 1.0.
        let result = compute_lighting(Vec3::Y, [255, 255, 255, 255], &lights, &ambient);
        assert_eq!(result, [255, 255, 255, 255]);
    }

    #[test]
    fn light_opposite_normal_no_contribution() {
        let lights = [
            DirectionalLight {
                direction: Vec3::NEG_Y,
                color: Vec3::ONE,
            },
            zero_light(),
            zero_light(),
            zero_light(),
        ];
        let ambient = AmbientLight { color: Vec3::ZERO };
        // Normal up, light pointing down → dot = -1.0, clamped to 0.
        let result = compute_lighting(Vec3::Y, [255, 255, 255, 255], &lights, &ambient);
        assert_eq!(result, [0, 0, 0, 255]);
    }

    #[test]
    fn light_at_45_degrees() {
        let light_dir = Vec3::new(0.0, 1.0, 1.0).normalize();
        let lights = [
            DirectionalLight {
                direction: light_dir,
                color: Vec3::ONE,
            },
            zero_light(),
            zero_light(),
            zero_light(),
        ];
        let ambient = AmbientLight { color: Vec3::ZERO };
        let result = compute_lighting(Vec3::Y, [255, 255, 255, 255], &lights, &ambient);
        // dot(Y, normalize(0,1,1)) ≈ 0.707
        // 0.707 * 255 ≈ 180
        assert!(result[0] >= 178 && result[0] <= 182, "r={}", result[0]);
    }

    #[test]
    fn colored_light() {
        let lights = [
            DirectionalLight {
                direction: Vec3::Y,
                color: Vec3::new(1.0, 0.0, 0.0), // Red light only
            },
            zero_light(),
            zero_light(),
            zero_light(),
        ];
        let ambient = AmbientLight { color: Vec3::ZERO };
        let result = compute_lighting(Vec3::Y, [255, 255, 255, 255], &lights, &ambient);
        assert_eq!(result[0], 255); // Red channel lit
        assert_eq!(result[1], 0);   // Green dark
        assert_eq!(result[2], 0);   // Blue dark
    }
}

mod multiple_lights {
    use super::*;

    #[test]
    fn two_lights_additive() {
        let lights = [
            DirectionalLight {
                direction: Vec3::Y,
                color: Vec3::splat(0.5),
            },
            DirectionalLight {
                direction: Vec3::Y,
                color: Vec3::splat(0.5),
            },
            zero_light(),
            zero_light(),
        ];
        let ambient = AmbientLight { color: Vec3::ZERO };
        let result = compute_lighting(Vec3::Y, [255, 255, 255, 255], &lights, &ambient);
        // 0.5 + 0.5 = 1.0, * 255 = 255
        assert_eq!(result, [255, 255, 255, 255]);
    }

    #[test]
    fn ambient_plus_directional() {
        let lights = [
            DirectionalLight {
                direction: Vec3::Y,
                color: Vec3::splat(0.5),
            },
            zero_light(),
            zero_light(),
            zero_light(),
        ];
        let ambient = AmbientLight {
            color: Vec3::splat(0.3),
        };
        let result = compute_lighting(Vec3::Y, [255, 255, 255, 255], &lights, &ambient);
        // 0.3 + 0.5 = 0.8, * 255 = 204
        assert_eq!(result[0], 204);
    }
}

mod clamping {
    use super::*;

    #[test]
    fn overexposed_clamps_to_255() {
        let lights = [
            DirectionalLight {
                direction: Vec3::Y,
                color: Vec3::splat(2.0), // Oversaturated
            },
            zero_light(),
            zero_light(),
            zero_light(),
        ];
        let ambient = AmbientLight { color: Vec3::ONE };
        let result = compute_lighting(Vec3::Y, [255, 255, 255, 255], &lights, &ambient);
        // (1.0 + 2.0) * 255 = 765, clamped to 255.
        assert_eq!(result, [255, 255, 255, 255]);
    }

    #[test]
    fn alpha_passes_through_unchanged() {
        let lights = [
            DirectionalLight {
                direction: Vec3::Y,
                color: Vec3::ONE,
            },
            zero_light(),
            zero_light(),
            zero_light(),
        ];
        let ambient = AmbientLight { color: Vec3::ZERO };
        let result = compute_lighting(Vec3::Y, [255, 255, 255, 128], &lights, &ambient);
        assert_eq!(result[3], 128);
    }
}
