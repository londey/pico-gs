#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
// Allow some pedantic lints that are too strict for this project
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::must_use_candidate)]
#![allow(clippy::missing_errors_doc)]
#![allow(clippy::missing_panics_doc)]
#![allow(clippy::enum_variant_names)]
// Until 1.0.0, allow dead code and unused dependency warnings
#![allow(dead_code)]
#![allow(unused_crate_dependencies)]

//! gs-twin CLI: render golden references and diff against Verilator output.
//!
//! Usage:
//!   gs-twin-cli render --scene ver_010 --output ref.png --width 512 --height 480
//!   gs-twin-cli diff --reference ref.png --actual verilator_dump.raw --width 320 --height 240

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use gs_twin::hex_parser;
use gs_twin::math::Rgb565;
use gs_twin::test_harness;
use std::path::PathBuf;

/// Shared hex test scripts, embedded at compile time.
mod scripts {
    /// VER-010: Gouraud shaded triangle.
    pub const VER_010: &str = include_str!("../../../tests/scripts/ver_010_gouraud.hex");

    /// VER-011: Depth-tested overlapping triangles.
    pub const VER_011: &str = include_str!("../../../tests/scripts/ver_011_depth_test.hex");

    /// VER-015: Triangle size grid.
    pub const VER_015: &str = include_str!("../../../tests/scripts/ver_015_size_grid.hex");
}

/// Top-level CLI argument parser.
#[derive(Parser)]
#[command(name = "gs-twin-cli")]
#[command(about = "pico-gs digital twin: golden reference renderer and comparator")]
struct Cli {
    /// Subcommand to execute.
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

/// Render a scene from a hex script string.
///
/// Uses framebuffer dimensions from the `## FRAMEBUFFER:` directive when
/// present, overriding the GPU's current dimensions.
///
/// # Arguments
///
/// * `hex_content` - Hex script text to parse and execute.
/// * `gpu` - GPU instance to render into.
///
/// # Errors
///
/// Returns an error if the hex script cannot be parsed.
fn render_hex_scene(hex_content: &str, gpu: &mut gs_twin::Gpu) -> Result<()> {
    let script = hex_parser::parse_hex_str(hex_content)
        .map_err(|e| anyhow::anyhow!("hex parse error: {e}"))?;

    // Use framebuffer dimensions from hex file if available
    if script.fb_width > 0 && script.fb_height > 0 {
        *gpu = gs_twin::Gpu::new(script.fb_width, script.fb_height);
    }

    // Execute each phase separately (respects pipeline drain boundaries)
    for phase in &script.phases {
        gpu.reg_write_script(&phase.commands);
    }
    Ok(())
}

/// CLI entry point: dispatch to render or diff subcommand.
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
                "ver_010" => {
                    render_hex_scene(scripts::VER_010, &mut gpu)?;
                }
                "ver_011" => {
                    render_hex_scene(scripts::VER_011, &mut gpu)?;
                }
                "ver_015" => {
                    render_hex_scene(scripts::VER_015, &mut gpu)?;
                }
                other => {
                    anyhow::bail!("unknown scene: {other}\navailable: ver_010, ver_011, ver_015")
                }
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
            // Load reference PNG → RGB565 pixel vec
            let ref_img = image::open(&reference).context("failed to open reference PNG")?;
            let ref_rgb = ref_img.to_rgb8();
            let mut ref_pixels = Vec::with_capacity((width * height) as usize);
            for y in 0..height {
                for x in 0..width {
                    let p = ref_rgb.get_pixel(x, y);
                    ref_pixels.push(Rgb565::from_rgb8(p[0], p[1], p[2]).0);
                }
            }

            // Load Verilator raw RGB565 dump
            let actual_pixels = gs_twin::mem::load_raw_rgb565(&actual, width, height)
                .context("failed to load raw framebuffer dump")?;

            // Compare
            let result =
                test_harness::compare_framebuffers(&ref_pixels, &actual_pixels, width, height);

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
                test_harness::save_diff_image(
                    &ref_pixels,
                    &actual_pixels,
                    width,
                    height,
                    &diff_path,
                )
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
