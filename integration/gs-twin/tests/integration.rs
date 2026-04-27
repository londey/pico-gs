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
//  Palette-blob helpers for INDEXED8_2X2 scenes
// ═══════════════════════════════════════════════════════════════════════════

/// Build a 4096-byte palette blob with entry 0 set to a per-quadrant
/// `[NW, NE, SW, SE]` pattern of RGBA8888 colours.  All other entries
/// are zero.  Mirrors the layout in the new INDEXED8_2X2 hex scripts so
/// the test can pre-load slot 0 directly without round-tripping the
/// payload through SDRAM staging.
fn make_quadrant_blob(nw: [u8; 4], ne: [u8; 4], sw: [u8; 4], se: [u8; 4]) -> [u8; 4096] {
    let mut blob = [0u8; 4096];
    blob[0..4].copy_from_slice(&nw);
    blob[4..8].copy_from_slice(&ne);
    blob[8..12].copy_from_slice(&sw);
    blob[12..16].copy_from_slice(&se);
    blob
}

/// Build a 4096-byte palette blob whose entry 0 and entry 1 are each a
/// uniform RGBA8888 colour (all four quadrants identical).  Used by the
/// scripts that key on indexed lookup rather than the quadrant trick
/// (e.g. VER-016's per-square checker).
fn make_uniform_blob(entry0: [u8; 4], entry1: [u8; 4]) -> [u8; 4096] {
    let mut blob = [0u8; 4096];
    for q in 0..4 {
        blob[q * 4..q * 4 + 4].copy_from_slice(&entry0);
    }
    for q in 0..4 {
        let off = 16 + q * 4;
        blob[off..off + 4].copy_from_slice(&entry1);
    }
    blob
}

const WHITE_RGBA: [u8; 4] = [0xFF, 0xFF, 0xFF, 0xFF];
const BLACK_RGBA: [u8; 4] = [0x00, 0x00, 0x00, 0xFF];
const MID_GREY_RGBA: [u8; 4] = [0x80, 0x80, 0x80, 0xFF];

// ═══════════════════════════════════════════════════════════════════════════
//  VER-012: Textured Triangle (INDEXED8_2X2)
// ═══════════════════════════════════════════════════════════════════════════

const VER_012_HEX: &str = include_str!("../../scripts/ver_012_textured.hex");

#[test]
fn ver_012_textured_triangle() {
    let png_path = dt_out_dir().join("ver_012_textured_triangle.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let script = hex_parser::parse_hex_str(VER_012_HEX).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);

    // Pre-load palette slot 0 with the per-quadrant white/black checker
    // (NW=white, NE=black, SW=black, SE=white) used by VER-012.  The hex
    // script also stages and triggers this load via PALETTE0; the
    // explicit pre-load makes the test resilient to SDRAM staging
    // changes.
    gpu.load_palette(
        0,
        &make_quadrant_blob(WHITE_RGBA, BLACK_RGBA, BLACK_RGBA, WHITE_RGBA),
    );

    for phase in &script.phases {
        gpu.reg_write_script(&phase.commands);
    }

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-012 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-013: Color-Combined Output (INDEXED8_2X2)
// ═══════════════════════════════════════════════════════════════════════════

const VER_013_HEX: &str = include_str!("../../scripts/ver_013_color_combined.hex");

#[test]
fn ver_013_color_combined() {
    let png_path = dt_out_dir().join("ver_013_color_combined.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let script = hex_parser::parse_hex_str(VER_013_HEX).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);

    // Pre-load palette slot 0: per-quadrant white/mid-grey checker
    // matching the VER-013 hex script (NW=white, NE=grey, SW=grey, SE=white).
    gpu.load_palette(
        0,
        &make_quadrant_blob(WHITE_RGBA, MID_GREY_RGBA, MID_GREY_RGBA, WHITE_RGBA),
    );

    for phase in &script.phases {
        gpu.reg_write_script(&phase.commands);
    }

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-013 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-014: Textured Cube (INDEXED8_2X2)
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

    // Pre-load palette slot 0: per-quadrant white/black checker matching
    // the VER-014 hex script (NW=white, NE=black, SW=black, SE=white).
    gpu.load_palette(
        0,
        &make_quadrant_blob(WHITE_RGBA, BLACK_RGBA, BLACK_RGBA, WHITE_RGBA),
    );

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

    // Pre-load palette slot 0: entry 0 = solid white, entry 1 = solid
    // black (uniform across all four quadrants).  Matches the VER-016
    // hex script which uses per-block index variation rather than the
    // quadrant trick to encode the 4x4 grid of 16x16 squares.
    gpu.load_palette(0, &make_uniform_blob(WHITE_RGBA, BLACK_RGBA));

    for phase in &script.phases {
        gpu.reg_write_script(&phase.commands);
    }

    gpu.framebuffer_to_png(&png_path).unwrap();
    gpu.zbuffer_to_png(&z_path).unwrap();
    eprintln!("VER-016 golden image: {}", png_path.display());
    eprintln!("VER-016 Z-buffer:     {}", z_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-017: INDEXED8_2X2 pixel-art texture (256x256 Skyline base-colour)
// ═══════════════════════════════════════════════════════════════════════════

#[test]
fn ver_017_indexed_pixel_art() {
    let png_path = dt_out_dir().join("ver_017_indexed_pixel_art.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let hex_path = scripts_dir().join("ver_017_indexed_pixel_art.hex");
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

// ═══════════════════════════════════════════════════════════════════════════
//  VER-023: Stipple Pattern Test
// ═══════════════════════════════════════════════════════════════════════════

const VER_023_HEX: &str = include_str!("../../scripts/ver_023_stipple_test.hex");

#[test]
fn ver_023_stipple_test() {
    let png_path = dt_out_dir().join("ver_023_stipple_test.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let script = hex_parser::parse_hex_str(VER_023_HEX).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);

    // Execute each phase separately (matching Verilator harness pipeline drain)
    for phase in &script.phases {
        gpu.reg_write_script(&phase.commands);
    }

    let green = Rgb565::from_rgb8(0, 0xFF, 0).0;
    let red = Rgb565::from_rgb8(0xFF, 0, 0).0;
    let blue = Rgb565::from_rgb8(0, 0, 0xFF).0;
    let pixels = gpu.extract_framebuffer_rgb565();

    let green_count = pixels.iter().filter(|&&p| p == green).count();
    let red_count = pixels.iter().filter(|&&p| p == red).count();
    let blue_count = pixels.iter().filter(|&&p| p == blue).count();

    // Triangle A (green, no stipple) should have many pixels
    assert!(
        green_count > 1000,
        "expected green pixels from solid Triangle A, got {green_count}"
    );

    // Triangle B (red, checkerboard stipple) should have pixels (~50% pass)
    assert!(
        red_count > 1000,
        "expected red pixels from checkerboard-stippled Triangle B, got {red_count}"
    );

    // Triangle C (blue, diamond stipple) should have pixels (~53% pass)
    assert!(
        blue_count > 1000,
        "expected blue pixels from diamond-stippled Triangle C, got {blue_count}"
    );

    // Verify stipple is discarding pixels: both stippled triangles should
    // have fewer pixels than the solid green triangle (which also receives
    // pixels through stipple holes in the overlap regions).
    assert!(
        red_count < green_count,
        "checkerboard stipple should discard ~half of red: red={red_count} green={green_count}"
    );
    assert!(
        blue_count < green_count,
        "diamond stipple should discard pixels: blue={blue_count} green={green_count}"
    );

    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-023 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-024: Alpha Blend Modes
// ═══════════════════════════════════════════════════════════════════════════

const VER_024_HEX: &str = include_str!("../../scripts/ver_024_alpha_blend.hex");

#[test]
fn ver_024_alpha_blend() {
    let png_path = dt_out_dir().join("ver_024_alpha_blend.png");
    let _ = test_harness::write_placeholder_png(&png_path);

    let script = hex_parser::parse_hex_str(VER_024_HEX).unwrap();
    let mut gpu = Gpu::new(script.fb_width, script.fb_height);

    for phase in &script.phases {
        gpu.reg_write_script(&phase.commands);
    }

    let pixels = gpu.extract_framebuffer_rgb565();

    // Save PNG first for visual inspection
    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-024 golden image: {}", png_path.display());

    // Background is a dark/light grey checkerboard.
    // Foreground triangles are red with Gouraud alpha gradient (opaque
    // top vertices, transparent bottom vertex).
    let w = script.fb_width as usize;

    // Helper: count pixels in a quadrant matching a predicate.
    let count_in_quad = |qx_min: usize, qy_min: usize, pred: &dyn Fn(u16) -> bool| -> usize {
        pixels
            .iter()
            .enumerate()
            .filter(|&(i, &p)| {
                let x = i % w;
                let y = i / w;
                x >= qx_min && x < qx_min + 128 && y >= qy_min && y < qy_min + 128 && pred(p)
            })
            .count()
    };

    // Verify checkerboard is present: should have at least 2 distinct
    // grey levels (dark and light) that aren't black.
    let is_grey = |p: u16| -> bool {
        let r = (p >> 11) & 0x1F;
        let g = (p >> 5) & 0x3F;
        let b = p & 0x1F;
        // Grey: channels roughly equal (accounting for 5/6/5 bit widths)
        let g5 = g >> 1; // scale G6 to G5 for comparison
        r > 2 && r.abs_diff(b) <= 2 && r.abs_diff(g5) <= 2
    };
    let grey_count = pixels.iter().filter(|&&p| is_grey(p)).count();
    assert!(
        grey_count > 20_000,
        "checkerboard background expected grey pixels, got {grey_count}"
    );

    // Top-left (DISABLED): red pixels that completely overwrite the
    // background (high R, no contribution from grey dest).
    let tl_red = count_in_quad(0, 0, &|p| {
        let r = (p >> 11) & 0x1F;
        r > 20
    });
    assert!(
        tl_red > 500,
        "DISABLED mode should have red pixels overwriting bg, got {tl_red}"
    );

    // Top-right (ADD): red + grey = brighter-than-grey pixels with R.
    // Red channel should be elevated above the background grey level.
    let tr_bright = count_in_quad(128, 0, &|p| {
        let r = (p >> 11) & 0x1F;
        r > 15
    });
    assert!(
        tr_bright > 500,
        "ADD mode should produce bright red-tinted pixels, got {tr_bright}"
    );

    // Bottom-left (SUBTRACT): red - grey.  Red channel stays high (src
    // red > dst grey red), green/blue channels clamp to 0.  Result is a
    // darker red compared to the source.
    let bl_sub = count_in_quad(0, 128, &|p| {
        let r = (p >> 11) & 0x1F;
        r > 8
    });
    assert!(
        bl_sub > 500,
        "SUBTRACT mode should produce reddish pixels, got {bl_sub}"
    );

    // Bottom-right (BLEND): alpha gradient.  Near the opaque top edge
    // we should see red; near the transparent bottom tip we should see
    // the checkerboard showing through.  Count pixels where red is
    // present but not at full intensity (blended).
    let br_blend = count_in_quad(128, 128, &|p| {
        let r = (p >> 11) & 0x1F;
        // Partially blended: red present but below full red
        r > 4 && r < 28
    });
    assert!(
        br_blend > 500,
        "BLEND mode should produce partially-blended red pixels, got {br_blend}"
    );
}
