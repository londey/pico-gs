use clap::{Parser, Subcommand};
use std::path::PathBuf;
use std::process;

#[derive(Parser)]
#[command(name = "asset-prep")]
#[command(about = "Convert PNG/OBJ assets to RP2350 firmware format (debug CLI)", long_about = None)]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// Suppress progress output (only show errors)
    #[arg(short, long, global = true)]
    quiet: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Convert a PNG image to RGBA8888 texture format
    Texture {
        /// Input PNG file path
        input: PathBuf,

        /// Output directory for generated .rs and .bin files
        #[arg(short, long)]
        output: PathBuf,
    },
    /// Convert an OBJ mesh to patch format
    Mesh {
        /// Input OBJ file path
        input: PathBuf,

        /// Output directory for generated files
        #[arg(short, long)]
        output: PathBuf,

        /// Maximum vertices per patch
        #[arg(long, default_value = "16")]
        patch_size: usize,

        /// Maximum indices per patch
        #[arg(long, default_value = "32")]
        index_limit: usize,
    },
}

fn main() {
    let cli = Cli::parse();

    // Initialize logging (suppressed if --quiet)
    if !cli.quiet {
        env_logger::Builder::from_default_env()
            .filter_level(log::LevelFilter::Info)
            .init();
    }

    let result = match cli.command {
        Commands::Texture { input, output } => asset_build_tool::convert_texture(&input, &output)
            .map(|t| {
                if !cli.quiet {
                    eprintln!(
                        "Success: Texture converted — {} ({}×{}, {} KB)",
                        t.identifier,
                        t.width,
                        t.height,
                        t.size_bytes() / 1024
                    );
                }
            }),
        Commands::Mesh {
            input,
            output,
            patch_size,
            index_limit,
        } => asset_build_tool::convert_mesh(&input, &output, patch_size, index_limit).map(|m| {
            if !cli.quiet {
                eprintln!(
                    "Success: Mesh converted — {} ({} vertices -> {} patches)",
                    m.identifier,
                    m.original_vertex_count,
                    m.patch_count()
                );
            }
        }),
    };

    if let Err(e) = result {
        eprintln!("Error: {}", e);
        process::exit(1);
    }
}
