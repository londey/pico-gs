//! Integration tests: render known scenes and verify output.

use gs_twin::pipeline::command_proc;
use gs_twin::test_harness;
use gs_twin::Gpu;
use std::path::Path;

#[test]
fn smoke_test_single_triangle() {
    let mut gpu = Gpu::new(320, 240);

    let (commands, vertices) = test_harness::single_triangle_scene();
    gpu.execute(&commands);

    // Draw the triangle (immediate mode for testing)
    command_proc::draw_triangles(&vertices, &gpu.state, &mut gpu.memory);

    // Verify: at least some pixels were written (not all background)
    let bg = gs_twin::math::Rgb565::from_rgb8(0, 0, 32);
    let non_bg_pixels = gpu
        .memory
        .framebuffer
        .pixels
        .iter()
        .filter(|&&p| p != bg)
        .count();

    assert!(
        non_bg_pixels > 100,
        "expected triangle pixels, got only {} non-background pixels",
        non_bg_pixels
    );

    // Save reference image for visual inspection
    let out_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    std::fs::create_dir_all(&out_dir).unwrap();
    gpu.framebuffer_to_png(&out_dir.join("single_triangle_ref.png"))
        .unwrap();
}

#[test]
fn exact_match_identical_framebuffers() {
    let fb = gs_twin::mem::Framebuffer::new(16, 16);
    let result = test_harness::compare_framebuffers(&fb, &fb);
    assert!(result.is_exact_match());
    assert_eq!(result.differing_pixels, 0);
    assert!(result.psnr_db.is_infinite());
}

#[test]
fn exact_match_detects_single_pixel_difference() {
    let mut fb_a = gs_twin::mem::Framebuffer::new(4, 4);
    let mut fb_b = gs_twin::mem::Framebuffer::new(4, 4);

    // One pixel differs
    fb_a.put_pixel(2, 2, gs_twin::math::Rgb565(0xF800)); // pure red
    fb_b.put_pixel(2, 2, gs_twin::math::Rgb565(0x07E0)); // pure green

    let result = test_harness::compare_framebuffers(&fb_a, &fb_b);
    assert!(!result.is_exact_match());
    assert_eq!(result.differing_pixels, 1);
    assert_eq!(result.first_diff.unwrap().0, 2); // x
    assert_eq!(result.first_diff.unwrap().1, 2); // y
}

#[test]
fn rgb565_roundtrip_consistency() {
    // Verify that from_rgb8 → to_rgb8 → from_rgb8 is idempotent
    // (important: the twin and RTL both truncate on pack, so the
    // roundtrip through 8-bit is lossy but deterministic)
    for r in (0..=255).step_by(8) {
        for g in (0..=255).step_by(4) {
            for b in (0..=255).step_by(8) {
                let packed = gs_twin::math::Rgb565::from_rgb8(r, g, b);
                let (r2, g2, b2) = packed.to_rgb8();
                let repacked = gs_twin::math::Rgb565::from_rgb8(r2, g2, b2);
                assert_eq!(packed, repacked, "RGB565 roundtrip failed for ({r}, {g}, {b})");
            }
        }
    }
}
