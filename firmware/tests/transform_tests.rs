//! Unit tests for the MVP transform pipeline.
//!
//! Re-implements transform logic for host testing (firmware crate is no_std).

use glam::{Mat4, Vec3, Vec4};

// --- Re-implemented transform functions (mirrors render/transform.rs) ---

struct ScreenVertex {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
}

const SCREEN_WIDTH: u32 = 640;
const SCREEN_HEIGHT: u32 = 480;

fn transform_vertex(position: Vec3, mvp: &Mat4) -> ScreenVertex {
    let clip = *mvp * Vec4::new(position.x, position.y, position.z, 1.0);
    let w = clip.w;
    let inv_w = if w.abs() > 1e-6 { 1.0 / w } else { 1.0 };
    let ndc_x = clip.x * inv_w;
    let ndc_y = clip.y * inv_w;
    let ndc_z = clip.z * inv_w;

    let screen_w = SCREEN_WIDTH as f32;
    let screen_h = SCREEN_HEIGHT as f32;
    let sx = (ndc_x + 1.0) * 0.5 * (screen_w - 1.0);
    let sy = (1.0 - ndc_y) * 0.5 * (screen_h - 1.0);
    let sz = (ndc_z + 1.0) * 0.5;

    ScreenVertex {
        x: sx,
        y: sy,
        z: sz.clamp(0.0, 1.0),
        w,
    }
}

fn transform_normal(normal: Vec3, mv: &Mat4) -> Vec3 {
    let n4 = *mv * Vec4::new(normal.x, normal.y, normal.z, 0.0);
    Vec3::new(n4.x, n4.y, n4.z).normalize_or_zero()
}

fn is_front_facing(v0: &ScreenVertex, v1: &ScreenVertex, v2: &ScreenVertex) -> bool {
    let e1x = v1.x - v0.x;
    let e1y = v1.y - v0.y;
    let e2x = v2.x - v0.x;
    let e2y = v2.y - v0.y;
    let cross = e1x * e2y - e1y * e2x;
    cross > 0.0
}

// --- Tests ---

mod identity_transform {
    use super::*;

    #[test]
    fn origin_maps_to_screen_center() {
        let mvp = Mat4::IDENTITY;
        let sv = transform_vertex(Vec3::ZERO, &mvp);
        // NDC (0,0) → screen center.
        let cx = (SCREEN_WIDTH as f32 - 1.0) * 0.5;
        let cy = (SCREEN_HEIGHT as f32 - 1.0) * 0.5;
        assert!((sv.x - cx).abs() < 0.01, "x: {} vs {}", sv.x, cx);
        assert!((sv.y - cy).abs() < 0.01, "y: {} vs {}", sv.y, cy);
    }

    #[test]
    fn z_maps_zero_to_half() {
        let mvp = Mat4::IDENTITY;
        let sv = transform_vertex(Vec3::ZERO, &mvp);
        // NDC z=0 → screen z=0.5
        assert!((sv.z - 0.5).abs() < 0.01);
    }

    #[test]
    fn w_is_one_for_identity() {
        let mvp = Mat4::IDENTITY;
        let sv = transform_vertex(Vec3::new(0.5, 0.3, -0.2), &mvp);
        assert!((sv.w - 1.0).abs() < 0.01);
    }
}

mod viewport_mapping {
    use super::*;

    #[test]
    fn ndc_neg1_neg1_maps_to_top_left() {
        // A point at NDC (-1, -1) should map to screen (0, 479).
        // Identity MVP, so object coords = NDC.
        let mvp = Mat4::IDENTITY;
        let sv = transform_vertex(Vec3::new(-1.0, -1.0, 0.0), &mvp);
        assert!(sv.x.abs() < 0.5, "x should be ~0, got {}", sv.x);
        assert!((sv.y - 479.0).abs() < 0.5, "y should be ~479, got {}", sv.y);
    }

    #[test]
    fn ndc_pos1_pos1_maps_to_bottom_right() {
        // NDC (+1, +1) → screen (639, 0).
        let mvp = Mat4::IDENTITY;
        let sv = transform_vertex(Vec3::new(1.0, 1.0, 0.0), &mvp);
        assert!((sv.x - 639.0).abs() < 0.5, "x should be ~639, got {}", sv.x);
        assert!(sv.y.abs() < 0.5, "y should be ~0, got {}", sv.y);
    }

    #[test]
    fn z_near_maps_to_zero() {
        let mvp = Mat4::IDENTITY;
        let sv = transform_vertex(Vec3::new(0.0, 0.0, -1.0), &mvp);
        assert!((sv.z - 0.0).abs() < 0.01, "z should be ~0, got {}", sv.z);
    }

    #[test]
    fn z_far_maps_to_one() {
        let mvp = Mat4::IDENTITY;
        let sv = transform_vertex(Vec3::new(0.0, 0.0, 1.0), &mvp);
        assert!((sv.z - 1.0).abs() < 0.01, "z should be ~1, got {}", sv.z);
    }
}

mod perspective_projection {
    use super::*;

    #[test]
    fn center_stays_centered() {
        let proj = Mat4::perspective_rh(
            core::f32::consts::FRAC_PI_4, // 45 degree FOV
            640.0 / 480.0,
            0.1,
            100.0,
        );
        let view = Mat4::look_at_rh(
            Vec3::new(0.0, 0.0, 5.0),
            Vec3::ZERO,
            Vec3::Y,
        );
        let mvp = proj * view;

        let sv = transform_vertex(Vec3::ZERO, &mvp);
        let cx = (SCREEN_WIDTH as f32 - 1.0) * 0.5;
        let cy = (SCREEN_HEIGHT as f32 - 1.0) * 0.5;
        assert!((sv.x - cx).abs() < 1.0, "x: {} vs {}", sv.x, cx);
        assert!((sv.y - cy).abs() < 1.0, "y: {} vs {}", sv.y, cy);
    }

    #[test]
    fn closer_objects_are_larger() {
        let proj = Mat4::perspective_rh(
            core::f32::consts::FRAC_PI_4,
            640.0 / 480.0,
            0.1,
            100.0,
        );
        let view = Mat4::look_at_rh(
            Vec3::new(0.0, 0.0, 5.0),
            Vec3::ZERO,
            Vec3::Y,
        );
        let mvp = proj * view;

        // Two points at same X but different Z distances.
        let near_pt = transform_vertex(Vec3::new(1.0, 0.0, 1.0), &mvp);
        let far_pt = transform_vertex(Vec3::new(1.0, 0.0, -1.0), &mvp);

        let cx = (SCREEN_WIDTH as f32 - 1.0) * 0.5;
        let near_offset = (near_pt.x - cx).abs();
        let far_offset = (far_pt.x - cx).abs();
        assert!(near_offset > far_offset, "near {} vs far {}", near_offset, far_offset);
    }

    #[test]
    fn w_increases_with_distance() {
        let proj = Mat4::perspective_rh(
            core::f32::consts::FRAC_PI_4,
            640.0 / 480.0,
            0.1,
            100.0,
        );
        let view = Mat4::look_at_rh(
            Vec3::new(0.0, 0.0, 5.0),
            Vec3::ZERO,
            Vec3::Y,
        );
        let mvp = proj * view;

        let near_pt = transform_vertex(Vec3::new(0.0, 0.0, 1.0), &mvp);
        let far_pt = transform_vertex(Vec3::new(0.0, 0.0, -1.0), &mvp);
        assert!(far_pt.w > near_pt.w, "far W {} > near W {}", far_pt.w, near_pt.w);
    }
}

mod normal_transform {
    use super::*;

    #[test]
    fn identity_preserves_normal() {
        let mv = Mat4::IDENTITY;
        let n = transform_normal(Vec3::Y, &mv);
        assert!((n - Vec3::Y).length() < 0.001);
    }

    #[test]
    fn rotation_rotates_normal() {
        let mv = Mat4::from_rotation_y(core::f32::consts::FRAC_PI_2); // 90 degrees
        let n = transform_normal(Vec3::X, &mv);
        // X rotated 90 degrees around Y → -Z (right-handed).
        assert!((n - Vec3::NEG_Z).length() < 0.01, "got {:?}", n);
    }

    #[test]
    fn result_is_normalized() {
        let mv = Mat4::from_scale(Vec3::new(2.0, 3.0, 4.0));
        let n = transform_normal(Vec3::new(1.0, 1.0, 1.0).normalize(), &mv);
        assert!((n.length() - 1.0).abs() < 0.001);
    }

    #[test]
    fn zero_normal_stays_zero() {
        let mv = Mat4::IDENTITY;
        let n = transform_normal(Vec3::ZERO, &mv);
        assert!(n.length() < 0.001);
    }
}

mod back_face_culling {
    use super::*;

    #[test]
    fn ccw_triangle_is_front_facing() {
        let v0 = ScreenVertex { x: 320.0, y: 100.0, z: 0.5, w: 1.0 };
        let v1 = ScreenVertex { x: 200.0, y: 400.0, z: 0.5, w: 1.0 };
        let v2 = ScreenVertex { x: 440.0, y: 400.0, z: 0.5, w: 1.0 };
        assert!(is_front_facing(&v0, &v1, &v2));
    }

    #[test]
    fn cw_triangle_is_back_facing() {
        let v0 = ScreenVertex { x: 320.0, y: 100.0, z: 0.5, w: 1.0 };
        let v1 = ScreenVertex { x: 440.0, y: 400.0, z: 0.5, w: 1.0 };
        let v2 = ScreenVertex { x: 200.0, y: 400.0, z: 0.5, w: 1.0 };
        assert!(!is_front_facing(&v0, &v1, &v2));
    }

    #[test]
    fn degenerate_line_is_back_facing() {
        let v0 = ScreenVertex { x: 100.0, y: 100.0, z: 0.5, w: 1.0 };
        let v1 = ScreenVertex { x: 200.0, y: 200.0, z: 0.5, w: 1.0 };
        let v2 = ScreenVertex { x: 300.0, y: 300.0, z: 0.5, w: 1.0 };
        assert!(!is_front_facing(&v0, &v1, &v2));
    }
}

mod matrix_builders {
    use super::*;

    #[test]
    fn rotate_y_zero_is_identity() {
        let m = Mat4::from_rotation_y(0.0);
        let diff = (m - Mat4::IDENTITY).abs_diff_eq(Mat4::ZERO, 0.001);
        assert!(diff);
    }

    #[test]
    fn rotate_y_full_turn_is_identity() {
        let m = Mat4::from_rotation_y(core::f32::consts::TAU);
        let diff = (m - Mat4::IDENTITY).abs_diff_eq(Mat4::ZERO, 0.001);
        assert!(diff);
    }

    #[test]
    fn look_at_z_axis() {
        let view = Mat4::look_at_rh(
            Vec3::new(0.0, 0.0, 5.0),
            Vec3::ZERO,
            Vec3::Y,
        );
        // The origin should be at (0, 0, -5) in view space.
        let p = view * Vec4::new(0.0, 0.0, 0.0, 1.0);
        assert!((p.x).abs() < 0.01);
        assert!((p.y).abs() < 0.01);
        assert!((p.z - (-5.0)).abs() < 0.01);
    }
}
