//! gs-twin CLI: render golden references and diff against Verilator output.
//!
//! Usage:
//!   gs-twin-cli render --scene single_triangle --output ref.png
//!   gs-twin-cli diff --reference ref.png --actual verilator_dump.raw --width 320 --height 240

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use gs_twin::pipeline::command_proc;
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

            let (commands, vertices) = match scene.as_str() {
                "single_triangle" => test_harness::single_triangle_scene(),
                other => anyhow::bail!("unknown scene: {other}"),
            };

            gpu.execute(&commands);
            command_proc::draw_triangles(&vertices, &gpu.state, &mut gpu.memory);
            gpu.framebuffer_to_png(&output)
                .context("failed to write PNG")?;

            println!("Rendered '{scene}' → {}", output.display());
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
                    ref_fb.put_pixel(
                        x,
                        y,
                        gs_twin::math::Rgb565::from_rgb8(p[0], p[1], p[2]),
                    );
                }
            }

            // Load Verilator raw RGB565 dump
            let actual_fb =
                gs_twin::mem::Framebuffer::load_raw_rgb565(&actual, width, height)
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
            println!("  PSNR:             {:.2} dB (diagnostic only)", result.psnr_db);

            if let Some(diff_path) = diff_image {
                test_harness::save_diff_image(&ref_fb, &actual_fb, &diff_path)
                    .context("failed to save diff image")?;
                println!("  Diff image:       {}", diff_path.display());
            }

            if result.is_exact_match() {
                println!("  Result: EXACT MATCH ✓");
            } else {
                println!("  Result: MISMATCH ✗ ({} pixels differ)", result.differing_pixels);
                std::process::exit(1);
            }
        }
    }

    Ok(())
}
