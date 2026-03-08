//! Integration tests: render known scenes and verify output.

use gs_twin::pipeline::command_proc;
use gs_twin::reg::{self, RegWrite};
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
                assert_eq!(
                    packed, repacked,
                    "RGB565 roundtrip failed for ({r}, {g}, {b})"
                );
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-010: Gouraud Triangle Golden Image Test
// ═══════════════════════════════════════════════════════════════════════════
//
// This test reproduces the exact register-write sequence from the Verilator
// testbench (spi_gpu/tests/harness/scripts/ver_010_gouraud.cpp).

/// Pack screen-space coordinates into VERTEX register format.
///
/// `[15:0]=X (Q12.4), [31:16]=Y (Q12.4), [47:32]=Z (u16), [63:48]=Q (1/W)`
fn pack_vertex(x: i32, y: i32, z: u16) -> u64 {
    let x_q12_4 = (x * 16) as u16;
    let y_q12_4 = (y * 16) as u16;
    let q: u16 = 0;
    (q as u64) << 48 | (z as u64) << 32 | (y_q12_4 as u64) << 16 | (x_q12_4 as u64)
}

/// Pack RGBA8888 color: `{R[31:24], G[23:16], B[15:8], A[7:0]}`.
fn rgba(r: u8, g: u8, b: u8, a: u8) -> u32 {
    (r as u32) << 24 | (g as u32) << 16 | (b as u32) << 8 | (a as u32)
}

/// Pack diffuse + specular into COLOR register: `[63:32]=diffuse, [31:0]=specular`.
fn pack_color(diffuse: u32, specular: u32) -> u64 {
    (diffuse as u64) << 32 | (specular as u64)
}

/// Pack FB_CONFIG: `[15:0]=color_base, [31:16]=z_base, [35:32]=w_log2, [39:36]=h_log2`.
fn pack_fb_config(color_base: u16, z_base: u16, width_log2: u8, height_log2: u8) -> u64 {
    ((height_log2 as u64) & 0xF) << 36
        | ((width_log2 as u64) & 0xF) << 32
        | (z_base as u64) << 16
        | (color_base as u64)
}

/// Pack FB_CONTROL: `[9:0]=x, [19:10]=y, [29:20]=w, [39:30]=h`.
fn pack_fb_control(x: u16, y: u16, width: u16, height: u16) -> u64 {
    ((height & 0x3FF) as u64) << 30
        | ((width & 0x3FF) as u64) << 20
        | ((y & 0x3FF) as u64) << 10
        | ((x & 0x3FF) as u64)
}

/// Build the VER-010 register write script.
///
/// Exact translation of ver_010_gouraud.cpp.
fn ver_010_script() -> Vec<RegWrite> {
    let render_mode_gouraud_color: u64 = (1 << 0) | (1 << 4); // GOURAUD_EN | COLOR_WRITE_EN

    vec![
        // 1. Configure framebuffer: 512×512 surface, base = 0
        RegWrite {
            addr: reg::ADDR_FB_CONFIG,
            data: pack_fb_config(0x0000, 0x0000, 9, 9),
        },
        // 2. Scissor: full 512×480 viewport
        RegWrite {
            addr: reg::ADDR_FB_CONTROL,
            data: pack_fb_control(0, 0, 512, 480),
        },
        // 3. Render mode: Gouraud + color write, no Z
        RegWrite {
            addr: reg::ADDR_RENDER_MODE,
            data: render_mode_gouraud_color,
        },
        // 4. V0: red at top center (256, 40)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0xFF, 0x00, 0x00, 0xFF), 0xFF000000),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(256, 40, 0x0000),
        },
        // 5. V1: blue at bottom right (448, 400)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0x00, 0x00, 0xFF, 0xFF), 0xFF000000),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(448, 400, 0x0000),
        },
        // 6. V2: green at bottom left (64, 400) — KICK triggers rasterization
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0x00, 0xFF, 0x00, 0xFF), 0xFF000000),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_KICK_012,
            data: pack_vertex(64, 400, 0x0000),
        },
        // 7. Dummy trailing command (benign, see FIFO note in ver_010_gouraud.cpp)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: 0,
        },
    ]
}

/// Helper to get the golden-image output directory (build/dt_out/).
fn dt_out_dir() -> std::path::PathBuf {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("build/dt_out");
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn ver_010_gouraud_triangle() {
    let mut gpu = Gpu::new(512, 480);
    gpu.reg_write_script(&ver_010_script());

    let non_bg_pixels = gpu
        .memory
        .framebuffer
        .pixels
        .iter()
        .filter(|&&p| p != gs_twin::math::Rgb565(0))
        .count();

    assert!(
        non_bg_pixels > 10_000,
        "expected Gouraud triangle pixels, got only {} non-background pixels",
        non_bg_pixels
    );

    let png_path = dt_out_dir().join("gouraud_triangle.png");
    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-010 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-011: Depth-Tested Overlapping Triangles
// ═══════════════════════════════════════════════════════════════════════════
//
// Exact translation of ver_011_depth_test.cpp.
// Two overlapping flat-colored triangles at different depths.
// Triangle A (far, red, Z=0x8000) first; Triangle B (near, blue, Z=0x4000)
// second.  In the overlap region, B must occlude A.

const ZBUFFER_BASE_512: u16 = 0x0800;

/// Z-buffer clear RENDER_MODE:
///   Z_TEST_EN=1, Z_WRITE_EN=1, COLOR_WRITE_EN=0, Z_COMPARE=ALWAYS (3'b110).
const RENDER_MODE_ZCLEAR: u64 = (1 << 2) | (1 << 3) | (6 << 13);

/// Depth-tested RENDER_MODE:
///   GOURAUD_EN=1, Z_TEST_EN=1, Z_WRITE_EN=1, COLOR_WRITE_EN=1, Z_COMPARE=LEQUAL (3'b001).
const RENDER_MODE_DEPTH_TEST: u64 = (1 << 0) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 13);

fn ver_011_zclear_script() -> Vec<RegWrite> {
    vec![
        RegWrite {
            addr: reg::ADDR_FB_CONFIG,
            data: pack_fb_config(0x0000, ZBUFFER_BASE_512, 9, 9),
        },
        RegWrite {
            addr: reg::ADDR_FB_CONTROL,
            data: pack_fb_control(0, 0, 512, 480),
        },
        RegWrite {
            addr: reg::ADDR_RENDER_MODE,
            data: RENDER_MODE_ZCLEAR,
        },
        // Triangle 1: (0,0)-(511,0)-(0,479)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(0, 0, 0xFFFF),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(511, 0, 0xFFFF),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_KICK_012,
            data: pack_vertex(0, 479, 0xFFFF),
        },
        // Triangle 2: (511,0)-(511,479)-(0,479)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(511, 0, 0xFFFF),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(511, 479, 0xFFFF),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_KICK_012,
            data: pack_vertex(0, 479, 0xFFFF),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: 0,
        },
    ]
}

fn ver_011_tri_a_script() -> Vec<RegWrite> {
    vec![
        RegWrite {
            addr: reg::ADDR_RENDER_MODE,
            data: RENDER_MODE_DEPTH_TEST,
        },
        // V0: red at (80, 100), Z=0x8000
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0xFF, 0, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(80, 100, 0x8000),
        },
        // V1: red at (320, 100)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0xFF, 0, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(320, 100, 0x8000),
        },
        // V2: red at (200, 380)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0xFF, 0, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_KICK_012,
            data: pack_vertex(200, 380, 0x8000),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: 0,
        },
    ]
}

fn ver_011_tri_b_script() -> Vec<RegWrite> {
    vec![
        // V0: blue at (160, 80), Z=0x4000
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0xFF, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(160, 80, 0x4000),
        },
        // V1: blue at (400, 80)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0xFF, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(400, 80, 0x4000),
        },
        // V2: blue at (280, 360)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0xFF, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_KICK_012,
            data: pack_vertex(280, 360, 0x4000),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: 0,
        },
    ]
}

#[test]
fn ver_011_depth_test() {
    let mut gpu = Gpu::new(512, 480);

    gpu.reg_write_script(&ver_011_zclear_script());
    gpu.reg_write_script(&ver_011_tri_a_script());
    gpu.reg_write_script(&ver_011_tri_b_script());

    // In the overlap region, blue (nearer Z=0x4000) should occlude red (Z=0x8000).
    // Check that both colors are present.
    let red = gs_twin::math::Rgb565::from_rgb8(0xFF, 0, 0);
    let blue = gs_twin::math::Rgb565::from_rgb8(0, 0, 0xFF);
    let red_count = gpu
        .memory
        .framebuffer
        .pixels
        .iter()
        .filter(|&&p| p == red)
        .count();
    let blue_count = gpu
        .memory
        .framebuffer
        .pixels
        .iter()
        .filter(|&&p| p == blue)
        .count();

    assert!(
        red_count > 1000,
        "expected red pixels from Triangle A, got {red_count}"
    );
    assert!(
        blue_count > 1000,
        "expected blue pixels from Triangle B, got {blue_count}"
    );

    let png_path = dt_out_dir().join("depth_test.png");
    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-011 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-012: Textured Triangle (needs texture pipeline — ignored for now)
// ═══════════════════════════════════════════════════════════════════════════
//
// Exact translation of ver_012_textured.cpp.
// Single textured triangle with 16x16 checker pattern (white/black 4x4 blocks).
// Requires: TEX0_CFG register, UV interpolation, texture sampling.

const ADDR_TEX0_CFG: u8 = 0x10;

/// Pack TEX0_CFG register value.
fn pack_tex0_cfg(
    enable: u8,
    filter: u8,
    format: u8,
    width_log2: u8,
    height_log2: u8,
    u_wrap: u8,
    v_wrap: u8,
    mip_levels: u8,
    base_addr_512: u16,
) -> u64 {
    (enable as u64 & 0x1)
        | ((filter as u64 & 0x3) << 2)
        | ((format as u64 & 0x7) << 4)
        | ((width_log2 as u64 & 0xF) << 8)
        | ((height_log2 as u64 & 0xF) << 12)
        | ((u_wrap as u64 & 0x3) << 16)
        | ((v_wrap as u64 & 0x3) << 18)
        | ((mip_levels as u64 & 0xF) << 20)
        | ((base_addr_512 as u64) << 32)
}

/// Pack UV0 coordinates into 64-bit UV0_UV1 register format (Q1.15).
fn pack_uv(u0: f32, v0: f32) -> u64 {
    let to_q1_15 = |val: f32| -> u16 { (val * 32768.0) as i16 as u16 };
    let u_packed = to_q1_15(u0);
    let v_packed = to_q1_15(v0);
    (v_packed as u64) << 16 | (u_packed as u64)
}

const TEX0_BASE_ADDR_512: u16 = 0x0800;

fn ver_012_script() -> Vec<RegWrite> {
    let render_mode_textured: u64 = 1 << 4; // COLOR_WRITE_EN only
    let color_white = pack_color(rgba(0xFF, 0xFF, 0xFF, 0xFF), 0);

    vec![
        RegWrite {
            addr: reg::ADDR_FB_CONFIG,
            data: pack_fb_config(0, 0, 9, 9),
        },
        RegWrite {
            addr: reg::ADDR_FB_CONTROL,
            data: pack_fb_control(0, 0, 512, 512),
        },
        RegWrite {
            addr: ADDR_TEX0_CFG,
            data: pack_tex0_cfg(1, 0, 4, 4, 4, 0, 0, 0, TEX0_BASE_ADDR_512),
        },
        RegWrite {
            addr: reg::ADDR_RENDER_MODE,
            data: render_mode_textured,
        },
        // V0: (320, 60) UV=(0.5, 0.0)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: color_white,
        },
        RegWrite {
            addr: reg::ADDR_UV0_UV1,
            data: pack_uv(0.5, 0.0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(320, 60, 0),
        },
        // V1: (511, 380) UV=(1.0, 1.0)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: color_white,
        },
        RegWrite {
            addr: reg::ADDR_UV0_UV1,
            data: pack_uv(1.0, 1.0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(511, 380, 0),
        },
        // V2: (100, 380) UV=(0.0, 1.0)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: color_white,
        },
        RegWrite {
            addr: reg::ADDR_UV0_UV1,
            data: pack_uv(0.0, 1.0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_KICK_012,
            data: pack_vertex(100, 380, 0),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: 0,
        },
    ]
}

#[test]
#[ignore = "requires texture pipeline (TEX0_CFG, UV interpolation, texture sampling)"]
fn ver_012_textured_triangle() {
    let mut gpu = Gpu::new(512, 512);
    // TODO: upload checker texture to GPU memory at TEX0_BASE_ADDR
    gpu.reg_write_script(&ver_012_script());

    let png_path = dt_out_dir().join("textured_triangle.png");
    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-012 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-013: Color-Combined Output (needs texture + color combiner — ignored)
// ═══════════════════════════════════════════════════════════════════════════
//
// Exact translation of ver_013_color_combined.cpp.
// Textured, vertex-shaded triangle with MODULATE color combiner.

const ADDR_CC_MODE: u8 = 0x18;
const CC_MODE_MODULATE: u64 = 0x7670_7670_7371_7371;

fn ver_013_script() -> Vec<RegWrite> {
    let render_mode_combined: u64 = (1 << 0) | (1 << 4); // GOURAUD_EN | COLOR_WRITE_EN

    vec![
        RegWrite {
            addr: reg::ADDR_FB_CONFIG,
            data: pack_fb_config(0, 0, 9, 9),
        },
        RegWrite {
            addr: reg::ADDR_FB_CONTROL,
            data: pack_fb_control(0, 0, 512, 512),
        },
        RegWrite {
            addr: ADDR_TEX0_CFG,
            data: pack_tex0_cfg(1, 0, 4, 4, 4, 0, 0, 0, TEX0_BASE_ADDR_512),
        },
        RegWrite {
            addr: ADDR_CC_MODE,
            data: CC_MODE_MODULATE,
        },
        RegWrite {
            addr: reg::ADDR_RENDER_MODE,
            data: render_mode_combined,
        },
        // V0: red at (320, 60), UV=(0.5, 0.0)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0xFF, 0, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_UV0_UV1,
            data: pack_uv(0.5, 0.0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(320, 60, 0),
        },
        // V1: blue at (511, 380), UV=(1.0, 1.0)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0xFF, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_UV0_UV1,
            data: pack_uv(1.0, 1.0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(511, 380, 0),
        },
        // V2: green at (100, 380), UV=(0.0, 1.0)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0xFF, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_UV0_UV1,
            data: pack_uv(0.0, 1.0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_KICK_012,
            data: pack_vertex(100, 380, 0),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: 0,
        },
    ]
}

#[test]
#[ignore = "requires texture pipeline + color combiner (CC_MODE, MODULATE)"]
fn ver_013_color_combined() {
    let mut gpu = Gpu::new(512, 512);
    // TODO: upload mid-gray checker texture, configure CC_MODE
    gpu.reg_write_script(&ver_013_script());

    let png_path = dt_out_dir().join("color_combined.png");
    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-013 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-014: Textured Cube (needs texture + Z-test + KICK_021 — ignored)
// ═══════════════════════════════════════════════════════════════════════════
//
// Exact translation of ver_014_textured_cube.cpp.
// Twelve triangles (six faces), depth-tested textured rendering with
// painter's order.  Back faces use KICK_021 for reversed winding.

const COLOR_WHITE: u64 = ((0xFF_FF_FF_FFu64) << 32) | 0x00_00_00_00u64;
const COLOR_BLACK: u64 = 0;

const RENDER_MODE_ZCLEAR_014: u64 = (1 << 2) | (1 << 3) | (6 << 13);
const RENDER_MODE_TEXTURED_DEPTH: u64 = (1 << 0) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 13);

fn ver_014_zclear_script() -> Vec<RegWrite> {
    vec![
        RegWrite {
            addr: reg::ADDR_FB_CONFIG,
            data: pack_fb_config(0, ZBUFFER_BASE_512, 9, 9),
        },
        RegWrite {
            addr: reg::ADDR_FB_CONTROL,
            data: pack_fb_control(0, 0, 512, 512),
        },
        RegWrite {
            addr: reg::ADDR_RENDER_MODE,
            data: RENDER_MODE_ZCLEAR_014,
        },
        // Triangle 1: (0,0)-(511,0)-(0,511)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: COLOR_BLACK,
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(0, 0, 0xFFFF),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: COLOR_BLACK,
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(511, 0, 0xFFFF),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: COLOR_BLACK,
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_KICK_012,
            data: pack_vertex(0, 511, 0xFFFF),
        },
        // Triangle 2: (511,0)-(511,511)-(0,511)
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: COLOR_BLACK,
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(511, 0, 0xFFFF),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: COLOR_BLACK,
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(511, 511, 0xFFFF),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: COLOR_BLACK,
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_KICK_012,
            data: pack_vertex(0, 511, 0xFFFF),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: 0,
        },
    ]
}

fn ver_014_setup_script() -> Vec<RegWrite> {
    vec![
        RegWrite {
            addr: reg::ADDR_FB_CONFIG,
            data: pack_fb_config(0, ZBUFFER_BASE_512, 9, 9),
        },
        RegWrite {
            addr: reg::ADDR_FB_CONTROL,
            data: pack_fb_control(0, 0, 512, 512),
        },
        RegWrite {
            addr: ADDR_TEX0_CFG,
            data: pack_tex0_cfg(1, 0, 4, 4, 4, 0, 0, 0, TEX0_BASE_ADDR_512),
        },
        RegWrite {
            addr: reg::ADDR_RENDER_MODE,
            data: RENDER_MODE_TEXTURED_DEPTH,
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: 0,
        },
    ]
}

/// Build the VER-014 cube triangle script (all 12 triangles).
fn ver_014_triangles_script() -> Vec<RegWrite> {
    let mut s = Vec::new();

    // Helper to push a triangle (3 vertices with color, UV, vertex)
    let mut tri = |verts: [(i32, i32, u16, f32, f32); 3], kick: u8| {
        for (i, (x, y, z, u, v)) in verts.iter().enumerate() {
            s.push(RegWrite {
                addr: reg::ADDR_COLOR,
                data: COLOR_WHITE,
            });
            s.push(RegWrite {
                addr: reg::ADDR_UV0_UV1,
                data: pack_uv(*u, *v),
            });
            let kick_addr = if i == 2 {
                kick
            } else {
                reg::ADDR_VERTEX_NOKICK
            };
            s.push(RegWrite {
                addr: kick_addr,
                data: pack_vertex(*x, *y, *z),
            });
        }
    };

    // Face 1: -Z (back, Z=0x5800) — CW → KICK_021
    tri(
        [
            (192, 192, 0x5800, 0.0, 0.0),
            (192, 320, 0x5800, 0.0, 1.0),
            (320, 192, 0x5800, 1.0, 0.0),
        ],
        reg::ADDR_VERTEX_KICK_021,
    );
    tri(
        [
            (320, 192, 0x5800, 1.0, 0.0),
            (192, 320, 0x5800, 0.0, 1.0),
            (320, 320, 0x5800, 1.0, 1.0),
        ],
        reg::ADDR_VERTEX_KICK_021,
    );

    // Face 2: -X (left) — CW → KICK_021
    tri(
        [
            (128, 128, 0x3800, 1.0, 0.0),
            (64, 192, 0x4800, 0.0, 0.0),
            (128, 384, 0x3800, 1.0, 1.0),
        ],
        reg::ADDR_VERTEX_KICK_021,
    );
    tri(
        [
            (64, 192, 0x4800, 0.0, 0.0),
            (64, 320, 0x4800, 0.0, 1.0),
            (128, 384, 0x3800, 1.0, 1.0),
        ],
        reg::ADDR_VERTEX_KICK_021,
    );

    // Face 3: -Y (bottom) — CW → KICK_021
    tri(
        [
            (128, 384, 0x3800, 0.0, 0.0),
            (384, 384, 0x3800, 1.0, 0.0),
            (192, 448, 0x4800, 0.0, 1.0),
        ],
        reg::ADDR_VERTEX_KICK_021,
    );
    tri(
        [
            (384, 384, 0x3800, 1.0, 0.0),
            (320, 448, 0x4800, 1.0, 1.0),
            (192, 448, 0x4800, 0.0, 1.0),
        ],
        reg::ADDR_VERTEX_KICK_021,
    );

    // Face 4: +X (right, front) — CCW → KICK_012
    tri(
        [
            (384, 128, 0x3800, 0.0, 0.0),
            (448, 192, 0x4800, 1.0, 0.0),
            (384, 384, 0x3800, 0.0, 1.0),
        ],
        reg::ADDR_VERTEX_KICK_012,
    );
    tri(
        [
            (448, 192, 0x4800, 1.0, 0.0),
            (448, 320, 0x4800, 1.0, 1.0),
            (384, 384, 0x3800, 0.0, 1.0),
        ],
        reg::ADDR_VERTEX_KICK_012,
    );

    // Face 5: +Y (top, front) — CCW → KICK_012
    tri(
        [
            (128, 128, 0x3800, 0.0, 0.0),
            (384, 128, 0x3800, 1.0, 0.0),
            (192, 64, 0x4800, 0.5, 1.0),
        ],
        reg::ADDR_VERTEX_KICK_012,
    );
    tri(
        [
            (384, 128, 0x3800, 1.0, 0.0),
            (320, 64, 0x4800, 1.0, 1.0),
            (192, 64, 0x4800, 0.5, 1.0),
        ],
        reg::ADDR_VERTEX_KICK_012,
    );

    // Face 6: +Z (front, nearest, Z=0x3800) — CCW → KICK_012
    tri(
        [
            (128, 128, 0x3800, 0.0, 0.0),
            (384, 128, 0x3800, 1.0, 0.0),
            (128, 384, 0x3800, 0.0, 1.0),
        ],
        reg::ADDR_VERTEX_KICK_012,
    );
    tri(
        [
            (384, 128, 0x3800, 1.0, 0.0),
            (384, 384, 0x3800, 1.0, 1.0),
            (128, 384, 0x3800, 0.0, 1.0),
        ],
        reg::ADDR_VERTEX_KICK_012,
    );

    s.push(RegWrite {
        addr: reg::ADDR_COLOR,
        data: 0,
    });
    s
}

#[test]
#[ignore = "requires texture pipeline (TEX0_CFG, UV interpolation, texture sampling)"]
fn ver_014_textured_cube() {
    let mut gpu = Gpu::new(512, 512);
    // TODO: upload checker texture to GPU memory
    gpu.reg_write_script(&ver_014_zclear_script());
    gpu.reg_write_script(&ver_014_setup_script());
    gpu.reg_write_script(&ver_014_triangles_script());

    let png_path = dt_out_dir().join("textured_cube.png");
    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-014 golden image: {}", png_path.display());
}

// ═══════════════════════════════════════════════════════════════════════════
//  VER-015: Triangle Size Grid
// ═══════════════════════════════════════════════════════════════════════════
//
// Exact translation of ver_015_size_grid.cpp.
// 8 Gouraud triangles in a 4×2 grid with sizes 1..128 pixels per side.

/// Pack raw Q12.4 coordinates into VERTEX register format.
///
/// Unlike `pack_vertex()` which takes integer pixels, this takes pre-scaled
/// Q12.4 values directly (matching the C++ `pack_vertex_q4`).
fn pack_vertex_q4(x_q4: i16, y_q4: i16, z: u16) -> u64 {
    let q: u16 = 0;
    (q as u64) << 48 | (z as u64) << 32 | (y_q4 as u16 as u64) << 16 | (x_q4 as u16 as u64)
}

fn ver_015_script() -> Vec<RegWrite> {
    let render_mode_gouraud_color: u64 = (1 << 0) | (1 << 4);
    let mut s = vec![
        RegWrite {
            addr: reg::ADDR_FB_CONFIG,
            data: pack_fb_config(0, 0, 9, 9),
        },
        RegWrite {
            addr: reg::ADDR_FB_CONTROL,
            data: pack_fb_control(0, 0, 512, 480),
        },
        RegWrite {
            addr: reg::ADDR_RENDER_MODE,
            data: render_mode_gouraud_color,
        },
    ];

    // Grid: 4 columns × 2 rows
    // Cell centers: col={64,192,320,448} × row={120,360} pixels
    // Sizes: 1, 2, 4, 8, 16, 32, 64, 128 pixels
    // Half-sizes in Q12.4: 8, 16, 32, 64, 128, 256, 512, 1024
    let tris: [(i16, i16, i16); 8] = [
        (64 * 16, 120 * 16, 8),     //   1px
        (192 * 16, 120 * 16, 16),   //   2px
        (320 * 16, 120 * 16, 32),   //   4px
        (448 * 16, 120 * 16, 64),   //   8px
        (64 * 16, 360 * 16, 128),   //  16px
        (192 * 16, 360 * 16, 256),  //  32px
        (320 * 16, 360 * 16, 512),  //  64px
        (448 * 16, 360 * 16, 1024), // 128px
    ];

    for (cx, cy, hs) in tris {
        // V0: (cx, cy - hs) — top, red
        s.push(RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0xFF, 0, 0, 0xFF), 0xFF000000),
        });
        s.push(RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex_q4(cx, cy - hs, 0),
        });
        // V1: (cx + hs, cy + hs) — bottom right, blue
        s.push(RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0xFF, 0xFF), 0xFF000000),
        });
        s.push(RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex_q4(cx + hs, cy + hs, 0),
        });
        // V2: (cx - hs, cy + hs) — bottom left, green
        s.push(RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0xFF, 0, 0xFF), 0xFF000000),
        });
        s.push(RegWrite {
            addr: reg::ADDR_VERTEX_KICK_012,
            data: pack_vertex_q4(cx - hs, cy + hs, 0),
        });
    }

    s.push(RegWrite {
        addr: reg::ADDR_COLOR,
        data: 0,
    });
    s
}

#[test]
fn ver_015_size_grid() {
    let mut gpu = Gpu::new(512, 480);
    gpu.reg_write_script(&ver_015_script());

    let non_bg_pixels = gpu
        .memory
        .framebuffer
        .pixels
        .iter()
        .filter(|&&p| p != gs_twin::math::Rgb565(0))
        .count();

    // Should have pixels from all 8 triangles (even the 1px one renders at least 1 pixel)
    assert!(
        non_bg_pixels > 0,
        "expected size grid pixels, got 0 non-background pixels",
    );

    let png_path = dt_out_dir().join("size_grid.png");
    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-015 golden image: {}", png_path.display());
}
