use asset_prep::png_converter;
use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "asset-prep")]
#[command(about = "Asset preparation tool for RP2350 firmware", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// Suppress all non-error output
    #[arg(short, long, global = true)]
    quiet: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Convert PNG texture to RGBA8888 format
    Texture {
        /// Input PNG file
        input: PathBuf,

        /// Output directory
        #[arg(short, long)]
        output: PathBuf,
    },
    /// Convert OBJ mesh to patch format
    Mesh {
        /// Input OBJ file
        input: PathBuf,

        /// Output directory
        #[arg(short, long)]
        output: PathBuf,

        /// Maximum vertices per patch (default: 16)
        #[arg(long, default_value = "16")]
        patch_size: usize,

        /// Maximum indices per patch (default: 32)
        #[arg(long, default_value = "32")]
        index_limit: usize,
    },
    /// Batch convert all assets in a directory
    Batch {
        /// Input directory
        input: PathBuf,

        /// Output directory
        #[arg(short, long)]
        output: PathBuf,
    },
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Texture { input, output } => {
            // Convert PNG to TextureAsset
            let texture = png_converter::convert_texture(input, cli.quiet)?;

            // Note: Output file generation (US3) not yet implemented
            // For MVP, we've validated the conversion works
            eprintln!(
                "\n✓ Texture conversion successful: {} ({}×{}, {} KB)",
                texture.identifier,
                texture.width,
                texture.height,
                texture.size_bytes() / 1024
            );
            eprintln!("Note: Output file generation will be added in Phase 5");
            eprintln!("Output directory: {}", output.display());

            Ok(())
        }
        Commands::Mesh {
            input,
            output,
            patch_size,
            index_limit,
        } => {
            eprintln!("Mesh conversion not yet implemented");
            eprintln!("Input: {:?}", input);
            eprintln!("Output: {:?}", output);
            eprintln!("Patch size: {}, Index limit: {}", patch_size, index_limit);
            Ok(())
        }
        Commands::Batch { input, output } => {
            eprintln!("Batch conversion not yet implemented");
            eprintln!("Input: {:?}", input);
            eprintln!("Output: {:?}", output);
            Ok(())
        }
    }
}
