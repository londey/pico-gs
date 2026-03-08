//! gs-twin CLI: render golden references and diff against Verilator output.
//!
//! Usage:
//!   gs-twin-cli render --scene single_triangle --output ref.png
//!   gs-twin-cli diff --reference ref.png --actual verilator_dump.raw --width 320 --height 240

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use gs_twin::pipeline::command_proc;
use gs_twin::reg::{self, RegWrite};
use gs_twin::test_harness;
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "gs-twin-cli")]
#[command(about = "pico-gs digital twin: golden reference renderer and comparator")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Render a built-in test scene to a PNG file.
    Render {
        #[arg(long)]
        scene: String,

        #[arg(long)]
        output: PathBuf,

        #[arg(long, default_value = "320")]
        width: u32,

        #[arg(long, default_value = "240")]
        height: u32,
    },

    /// Compare a reference PNG against a raw RGB565 framebuffer dump.
    /// Primary criterion: exact bit match. PSNR reported for diagnostics.
    Diff {
        /// Reference PNG from the twin
        #[arg(long)]
        reference: PathBuf,

        /// Raw RGB565 framebuffer dump from Verilator
        #[arg(long)]
        actual: PathBuf,

        #[arg(long, default_value = "320")]
        width: u32,

        #[arg(long, default_value = "240")]
        height: u32,

        /// Optional diff image output
        #[arg(long)]
        diff_image: Option<PathBuf>,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Render {
            scene,
            output,
            width,
            height,
        } => {
            let mut gpu = gs_twin::Gpu::new(width, height);

            match scene.as_str() {
                "single_triangle" => {
                    let (commands, vertices) = test_harness::single_triangle_scene();
                    gpu.execute(&commands);
                    command_proc::draw_triangles(&vertices, &gpu.state, &mut gpu.memory);
                }
                "ver_010" => {
                    gpu.reg_write_script(&ver_010_script());
                }
                "ver_011" => {
                    gpu.reg_write_script(&ver_011_zclear_script());
                    gpu.reg_write_script(&ver_011_tri_a_script());
                    gpu.reg_write_script(&ver_011_tri_b_script());
                }
                "ver_015" => {
                    gpu.reg_write_script(&ver_015_script());
                }
                other => anyhow::bail!(
                    "unknown scene: {other}\navailable: single_triangle, ver_010, ver_011, ver_015"
                ),
            };

            gpu.framebuffer_to_png(&output)
                .context("failed to write PNG")?;

            println!("Rendered '{scene}' -> {}", output.display());
        }

        Commands::Diff {
            reference,
            actual,
            width,
            height,
            diff_image,
        } => {
            // Load reference PNG → RGB565 framebuffer
            let ref_img = image::open(&reference).context("failed to open reference PNG")?;
            let ref_rgb = ref_img.to_rgb8();
            let mut ref_fb = gs_twin::mem::Framebuffer::new(width, height);
            for y in 0..height {
                for x in 0..width {
                    let p = ref_rgb.get_pixel(x, y);
                    ref_fb.put_pixel(x, y, gs_twin::math::Rgb565::from_rgb8(p[0], p[1], p[2]));
                }
            }

            // Load Verilator raw RGB565 dump
            let actual_fb = gs_twin::mem::Framebuffer::load_raw_rgb565(&actual, width, height)
                .context("failed to load raw framebuffer dump")?;

            // Compare
            let result = test_harness::compare_framebuffers(&ref_fb, &actual_fb);

            println!("Comparison results:");
            println!("  Total pixels:     {}", result.total_pixels);
            println!("  Differing pixels: {}", result.differing_pixels);

            if let Some((x, y, expected, got)) = result.first_diff {
                println!("  First diff at:    ({x}, {y})");
                println!("    Expected: 0x{:04X}", expected.0);
                println!("    Got:      0x{:04X}", got.0);
            }

            println!("  Max channel diff: {}", result.max_channel_diff);
            println!(
                "  PSNR:             {:.2} dB (diagnostic only)",
                result.psnr_db
            );

            if let Some(diff_path) = diff_image {
                test_harness::save_diff_image(&ref_fb, &actual_fb, &diff_path)
                    .context("failed to save diff image")?;
                println!("  Diff image:       {}", diff_path.display());
            }

            if result.is_exact_match() {
                println!("  Result: EXACT MATCH ✓");
            } else {
                println!(
                    "  Result: MISMATCH ✗ ({} pixels differ)",
                    result.differing_pixels
                );
                std::process::exit(1);
            }
        }
    }

    Ok(())
}

// ── VER-010 register write script ────────────────────────────────────────────

fn pack_vertex(x: i32, y: i32, z: u16) -> u64 {
    let x_q12_4 = (x * 16) as u16;
    let y_q12_4 = (y * 16) as u16;
    (z as u64) << 32 | (y_q12_4 as u64) << 16 | (x_q12_4 as u64)
}

fn rgba(r: u8, g: u8, b: u8, a: u8) -> u32 {
    (r as u32) << 24 | (g as u32) << 16 | (b as u32) << 8 | (a as u32)
}

fn pack_color(diffuse: u32, specular: u32) -> u64 {
    (diffuse as u64) << 32 | (specular as u64)
}

fn pack_fb_config(color_base: u16, z_base: u16, width_log2: u8, height_log2: u8) -> u64 {
    ((height_log2 as u64) & 0xF) << 36
        | ((width_log2 as u64) & 0xF) << 32
        | (z_base as u64) << 16
        | (color_base as u64)
}

fn pack_fb_control(x: u16, y: u16, width: u16, height: u16) -> u64 {
    ((height & 0x3FF) as u64) << 30
        | ((width & 0x3FF) as u64) << 20
        | ((y & 0x3FF) as u64) << 10
        | ((x & 0x3FF) as u64)
}

fn pack_vertex_q4(x_q4: i16, y_q4: i16, z: u16) -> u64 {
    (z as u64) << 32 | (y_q4 as u16 as u64) << 16 | (x_q4 as u16 as u64)
}

fn ver_010_script() -> Vec<RegWrite> {
    let render_mode_gouraud_color: u64 = (1 << 0) | (1 << 4);
    vec![
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
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0xFF, 0, 0, 0xFF), 0xFF000000),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(256, 40, 0),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0xFF, 0xFF), 0xFF000000),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(448, 400, 0),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0xFF, 0, 0xFF), 0xFF000000),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_KICK_012,
            data: pack_vertex(64, 400, 0),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: 0,
        },
    ]
}

// ── VER-011 register write scripts ──────────────────────────────────────────

const RENDER_MODE_ZCLEAR: u64 = (1 << 2) | (1 << 3) | (6 << 13);
const RENDER_MODE_DEPTH_TEST: u64 = (1 << 0) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 13);
const ZBUFFER_BASE_512: u16 = 0x0800;

fn ver_011_zclear_script() -> Vec<RegWrite> {
    vec![
        RegWrite {
            addr: reg::ADDR_FB_CONFIG,
            data: pack_fb_config(0, ZBUFFER_BASE_512, 9, 9),
        },
        RegWrite {
            addr: reg::ADDR_FB_CONTROL,
            data: pack_fb_control(0, 0, 512, 480),
        },
        RegWrite {
            addr: reg::ADDR_RENDER_MODE,
            data: RENDER_MODE_ZCLEAR,
        },
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
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0xFF, 0, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(80, 100, 0x8000),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0xFF, 0, 0, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(320, 100, 0x8000),
        },
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
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0xFF, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(160, 80, 0x4000),
        },
        RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0xFF, 0xFF), 0),
        },
        RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex(400, 80, 0x4000),
        },
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

// ── VER-015 register write script ───────────────────────────────────────────

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

    let tris: [(i16, i16, i16); 8] = [
        (64 * 16, 120 * 16, 8),
        (192 * 16, 120 * 16, 16),
        (320 * 16, 120 * 16, 32),
        (448 * 16, 120 * 16, 64),
        (64 * 16, 360 * 16, 128),
        (192 * 16, 360 * 16, 256),
        (320 * 16, 360 * 16, 512),
        (448 * 16, 360 * 16, 1024),
    ];

    for (cx, cy, hs) in tris {
        s.push(RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0xFF, 0, 0, 0xFF), 0xFF000000),
        });
        s.push(RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex_q4(cx, cy - hs, 0),
        });
        s.push(RegWrite {
            addr: reg::ADDR_COLOR,
            data: pack_color(rgba(0, 0, 0xFF, 0xFF), 0xFF000000),
        });
        s.push(RegWrite {
            addr: reg::ADDR_VERTEX_NOKICK,
            data: pack_vertex_q4(cx + hs, cy + hs, 0),
        });
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
