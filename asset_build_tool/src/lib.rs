/// Error types for asset conversion.
pub mod error;

/// Core type definitions for assets.
pub mod types;

/// Identifier generation and sanitization.
pub mod identifier;

/// PNG to RGBA8888 texture conversion.
pub mod png_converter;

/// OBJ to mesh data conversion.
pub mod obj_converter;

/// Mesh splitting and patching algorithms.
pub mod mesh_patcher;

/// Output file generation (Rust wrappers + binary data).
pub mod output_gen;

pub use error::AssetError;
pub use types::{AssetBuildConfig, GeneratedAsset, MeshAsset, MeshPatch, TextureAsset};

use std::fs;
use std::path::{Path, PathBuf};

/// Process all assets in `config.source_dir` and write outputs to `config.out_dir`.
///
/// Scans for `.png` files in `textures/` and `.obj` files in `meshes/` subdirectories.
/// Returns a list of generated assets (for `cargo:rerun-if-changed` directives).
///
/// If the source directory is empty or contains no asset files, succeeds with an
/// empty `mod.rs` (per FR-040b).
pub fn build_assets(config: &AssetBuildConfig) -> Result<Vec<GeneratedAsset>, AssetError> {
    fs::create_dir_all(&config.out_dir)?;

    let textures_dir = config.source_dir.join("textures");
    let meshes_dir = config.source_dir.join("meshes");

    // Collect all source files (sorted for determinism)
    let mut png_files = collect_files(&textures_dir, "png");
    let mut obj_files = collect_files(&meshes_dir, "obj");
    png_files.sort();
    obj_files.sort();

    // Check identifier collisions across all assets
    let all_paths: Vec<&Path> = png_files
        .iter()
        .chain(obj_files.iter())
        .map(|p| p.as_path())
        .collect();
    identifier::check_collisions(&all_paths)?;

    let mut generated = Vec::new();

    // Convert textures
    for png_path in &png_files {
        log::info!("Converting texture: {}", png_path.display());
        let texture = png_converter::load_and_convert(png_path)?;
        let assets = output_gen::write_texture_output(&texture, &config.out_dir)?;
        generated.extend(assets);
    }

    // Convert meshes
    for obj_path in &obj_files {
        log::info!("Converting mesh: {}", obj_path.display());
        let mesh =
            obj_converter::load_and_convert(obj_path, config.patch_size, config.index_limit)?;
        log::info!(
            "  {} vertices, {} triangles -> {} patches",
            mesh.original_vertex_count,
            mesh.original_triangle_count,
            mesh.patches.len()
        );
        let assets = output_gen::write_mesh_output(&mesh, &config.out_dir)?;
        generated.extend(assets);
    }

    // Generate master mod.rs
    output_gen::write_mod_rs(&generated, &config.out_dir)?;

    Ok(generated)
}

/// Convert a single PNG texture. Writes output files to `out_dir`.
pub fn convert_texture(input: &Path, out_dir: &Path) -> Result<TextureAsset, AssetError> {
    fs::create_dir_all(out_dir)?;
    let texture = png_converter::load_and_convert(input)?;
    output_gen::write_texture_output(&texture, out_dir)?;
    Ok(texture)
}

/// Convert a single OBJ mesh. Writes output files to `out_dir`.
pub fn convert_mesh(
    input: &Path,
    out_dir: &Path,
    patch_size: usize,
    index_limit: usize,
) -> Result<MeshAsset, AssetError> {
    fs::create_dir_all(out_dir)?;
    let mesh = obj_converter::load_and_convert(input, patch_size, index_limit)?;
    output_gen::write_mesh_output(&mesh, out_dir)?;
    Ok(mesh)
}

/// Collect files with a given extension from a directory (non-recursive).
fn collect_files(dir: &Path, extension: &str) -> Vec<PathBuf> {
    if !dir.is_dir() {
        return Vec::new();
    }
    let mut files = Vec::new();
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let matches = path.is_file()
                && path
                    .extension()
                    .is_some_and(|ext| ext.eq_ignore_ascii_case(extension));
            if matches {
                files.push(path);
            }
        }
    }
    files
}
