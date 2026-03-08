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
                assert_eq!(packed, repacked, "RGB565 roundtrip failed for ({r}, {g}, {b})");
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

#[test]
fn ver_010_gouraud_triangle() {
    // 512×480 framebuffer matching the Verilator test
    let mut gpu = Gpu::new(512, 480);

    // Execute the VER-010 register write script
    let script = ver_010_script();
    gpu.reg_write_script(&script);

    // Verify: triangle pixels were written
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

    // Save golden reference PNG
    let out_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("build/dt_out");
    std::fs::create_dir_all(&out_dir).unwrap();
    let png_path = out_dir.join("gouraud_triangle.png");
    gpu.framebuffer_to_png(&png_path).unwrap();
    eprintln!("VER-010 golden image: {}", png_path.display());
}
