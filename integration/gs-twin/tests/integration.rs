//! Integration tests: render known scenes and verify output.

use gs_twin::hex_parser;
use gs_twin::math::Rgb565;
use gs_twin::test_harness;
use gs_twin::Gpu;
use std::path::Path;
use std::path::PathBuf;

#[test]
fn exact_match_identical_framebuffers() {
    let pixels = vec![0u16; 16 * 16];
    let result = test_harness::compare_framebuffers(&pixels, &pixels, 16, 16);
    assert!(result.is_exact_match());
    assert_eq!(result.differing_pixels, 0);
    assert!(result.psnr_db.is_infinite());
}

#[test]
fn exact_match_detects_single_pixel_difference() {
    let mut fb_a = vec![0u16; 4 * 4];
    let mut fb_b = vec![0u16; 4 * 4];

    // One pixel differs (index 2*4+2 = 10)
    fb_a[10] = 0xF800; // pure red
    fb_b[10] = 0x07E0; // pure green

    let result = test_harness::compare_framebuffers(&fb_a, &fb_b, 4, 4);
    assert!(!result.is_exact_match());
    assert_eq!(result.differing_pixels, 1);
    assert_eq!(result.first_diff.unwrap().0, 2); // x
    assert_eq!(result.first_diff.unwrap().1, 2); // y
}

#[test]
fn rgb565_roundtrip_consistency() {
    for r in (0..=255).step_by(8) {
        for g in (0..=255).step_by(4) {
            for b in (0..=255).step_by(8) {
                let packed = Rgb565::from_rgb8(r, g, b);
                let (r2, g2, b2) = packed.to_rgb8();
                let repacked = Rgb565::from_rgb8(r2, g2, b2);
                assert_eq!(
                    packed, repacked,
                    "RGB565 roundtrip failed for ({r}, {g}, {b})"
                );
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Hex script loading — all test scripts loaded from shared .hex files
// ═══════════════════════════════════════════════════════════════════════════

/// Helper to get the golden-image output directory (build/dt_out/).
fn dt_out_dir() -> PathBuf {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("build/dt_out");
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Helper to get the test scripts directory (integration/scripts/).
fn scripts_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("scripts")
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-010: Gouraud Triangle Golden Image Test
// ═══════════════════════════════════════════════════════════════════════════

const VER_010_HEX: &str = include_str!("../../scripts/ver_010_gouraud.hex");

#[test]
fn ver_010_gouraud_triangle() {
    let png_path = dt_out_dir().join("ver_010_gouraud_triangle.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let script = hex_parser::parse_hex_str(VER_010_HEX).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);
    gpu.reg_write_script(&script.all_commands());

    let pixels = gpu.extract_framebuffer_rgb565();
    let non_bg_pixels = pixels.iter().filter(|&&p| p != 0).count();

    assert!(
        non_bg_pixels > 10_000,
        "expected Gouraud triangle pixels, got only {} non-background pixels",
        non_bg_pixels
    );

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-010 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-011: Depth-Tested Overlapping Triangles
// ═══════════════════════════════════════════════════════════════════════════

const VER_011_HEX: &str = include_str!("../../scripts/ver_011_depth_test.hex");

#[test]
fn ver_011_depth_test() {
    let png_path = dt_out_dir().join("ver_011_depth_test.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let script = hex_parser::parse_hex_str(VER_011_HEX).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);

    // Execute each phase separately (matching Verilator harness pipeline drain)
    for phase in &script.phases {
        gpu.reg_write_script(&phase.commands);
    }

    let red = Rgb565::from_rgb8(0xFF, 0, 0).0;
    let blue = Rgb565::from_rgb8(0, 0, 0xFF).0;
    let pixels = gpu.extract_framebuffer_rgb565();
    let red_count = pixels.iter().filter(|&&p| p == red).count();
    let blue_count = pixels.iter().filter(|&&p| p == blue).count();

    assert!(
        red_count > 1000,
        "expected red pixels from Triangle A, got {red_count}"
    );
    assert!(
        blue_count > 1000,
        "expected blue pixels from Triangle B, got {blue_count}"
    );

    // With GEQUAL (reverse-Z), Triangle B (Z=0x8000, near) is closer than
    // Triangle A (Z=0x4000, far), so Hi-Z should NOT reject any tiles —
    // the nearer fragment always passes against the stored minimum.
    let hiz_rejects = gpu.hiz.rejected_tiles();
    eprintln!("VER-011 Hi-Z rejected tiles: {hiz_rejects}");
    assert_eq!(
        hiz_rejects, 0,
        "nearer Triangle B should not be rejected by Hi-Z metadata from further Triangle A"
    );

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-011 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-012: Textured Triangle (needs texture pipeline — ignored for now)
// ═══════════════════════════════════════════════════════════════════════════

const VER_012_HEX: &str = include_str!("../../scripts/ver_012_textured.hex");

#[test]
fn ver_012_textured_triangle() {
    let png_path = dt_out_dir().join("ver_012_textured_triangle.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let script = hex_parser::parse_hex_str(VER_012_HEX).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);
    gpu.reg_write_script(&script.all_commands());

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-012 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-013: Color-Combined Output (needs texture + color combiner — ignored)
// ═══════════════════════════════════════════════════════════════════════════

const VER_013_HEX: &str = include_str!("../../scripts/ver_013_color_combined.hex");

#[test]
fn ver_013_color_combined() {
    let png_path = dt_out_dir().join("ver_013_color_combined.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let script = hex_parser::parse_hex_str(VER_013_HEX).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);
    gpu.reg_write_script(&script.all_commands());

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-013 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-014: Textured Cube (needs texture + Z-test + KICK_021 — ignored)
// ═══════════════════════════════════════════════════════════════════════════

const VER_014_HEX: &str = include_str!("../../scripts/ver_014_textured_cube.hex");

#[test]
fn ver_014_textured_cube() {
    let png_path = dt_out_dir().join("ver_014_textured_cube.png");
    let z_path = dt_out_dir().join("ver_014_textured_cube_z.png");
    let _ = test_harness::write_placeholder_png(&png_path);
    let _ = test_harness::write_placeholder_png(&z_path);

    let script = hex_parser::parse_hex_str(VER_014_HEX).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);
    for phase in &script.phases {
        gpu.reg_write_script(&phase.commands);
    }

    gpu.framebuffer_to_png(&png_path).unwrap();
    gpu.zbuffer_to_png(&z_path).unwrap();
    eprintln!("VER-014 golden image: {}", png_path.display());
    eprintln!("VER-014 Z-buffer:     {}", z_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-015: Triangle Size Grid
// ═══════════════════════════════════════════════════════════════════════════

const VER_015_HEX: &str = include_str!("../../scripts/ver_015_size_grid.hex");

#[test]
fn ver_015_size_grid() {
    let png_path = dt_out_dir().join("ver_015_size_grid.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let script = hex_parser::parse_hex_str(VER_015_HEX).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);
    gpu.reg_write_script(&script.all_commands());

    let pixels = gpu.extract_framebuffer_rgb565();
    let non_bg_pixels = pixels.iter().filter(|&&p| p != 0).count();

    assert!(
        non_bg_pixels > 0,
        "expected size grid pixels, got 0 non-background pixels",
    );

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-015 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-016: Perspective Road
// ═══════════════════════════════════════════════════════════════════════════

const VER_016_HEX: &str = include_str!("../../scripts/ver_016_perspective_road.hex");

#[test]
fn ver_016_perspective_road() {
    let png_path = dt_out_dir().join("ver_016_perspective_road.png");
    let z_path = dt_out_dir().join("ver_016_perspective_road_z.png");
    let _ = test_harness::write_placeholder_png(&png_path);
    let _ = test_harness::write_placeholder_png(&z_path);

    let script = hex_parser::parse_hex_str(VER_016_HEX).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);
    for phase in &script.phases {
        gpu.reg_write_script(&phase.commands);
    }

    gpu.framebuffer_to_png(&png_path).unwrap();
    gpu.zbuffer_to_png(&z_path).unwrap();
    eprintln!("VER-016 golden image: {}", png_path.display());
    eprintln!("VER-016 Z-buffer:     {}", z_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-017: BC1 Texture (uses ## INCLUDE: for shared texture data)
// ═══════════════════════════════════════════════════════════════════════════

#[test]
fn ver_017_bc1_texture() {
    let png_path = dt_out_dir().join("ver_017_bc1_texture.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let hex_path = scripts_dir().join("ver_017_bc1_texture.hex");
    let script = hex_parser::parse_hex_file(&hex_path).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);
    gpu.reg_write_script(&script.all_commands());

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-017 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-018: BC2 Texture (explicit alpha)
// ═══════════════════════════════════════════════════════════════════════════

#[test]
fn ver_018_bc2_texture() {
    let png_path = dt_out_dir().join("ver_018_bc2_texture.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let hex_path = scripts_dir().join("ver_018_bc2_texture.hex");
    let script = hex_parser::parse_hex_file(&hex_path).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);
    gpu.reg_write_script(&script.all_commands());

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-018 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-019: BC3 Texture (interpolated alpha)
// ═══════════════════════════════════════════════════════════════════════════

#[test]
fn ver_019_bc3_texture() {
    let png_path = dt_out_dir().join("ver_019_bc3_texture.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let hex_path = scripts_dir().join("ver_019_bc3_texture.hex");
    let script = hex_parser::parse_hex_file(&hex_path).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);
    gpu.reg_write_script(&script.all_commands());

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-019 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-020: BC4 Texture (single-channel grayscale)
// ═══════════════════════════════════════════════════════════════════════════

#[test]
fn ver_020_bc4_texture() {
    let png_path = dt_out_dir().join("ver_020_bc4_texture.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let hex_path = scripts_dir().join("ver_020_bc4_texture.hex");
    let script = hex_parser::parse_hex_file(&hex_path).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);
    gpu.reg_write_script(&script.all_commands());

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-020 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-021: RGBA8888 Texture (uncompressed 32bpp)
// ═══════════════════════════════════════════════════════════════════════════

#[test]
fn ver_021_rgba8888_texture() {
    let png_path = dt_out_dir().join("ver_021_rgba8888_texture.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let hex_path = scripts_dir().join("ver_021_rgba8888_texture.hex");
    let script = hex_parser::parse_hex_file(&hex_path).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);
    gpu.reg_write_script(&script.all_commands());

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-021 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-022: R8 Texture (single-channel grayscale uncompressed)
// ═══════════════════════════════════════════════════════════════════════════

#[test]
fn ver_022_r8_texture() {
    let png_path = dt_out_dir().join("ver_022_r8_texture.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let hex_path = scripts_dir().join("ver_022_r8_texture.hex");
    let script = hex_parser::parse_hex_file(&hex_path).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);
    gpu.reg_write_script(&script.all_commands());

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-022 golden image: {}", png_path.display());
}
