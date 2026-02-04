use asset_build_tool::{AssetBuildConfig, build_assets};
use std::path::{Path, PathBuf};

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());

    let source_dir = manifest_dir.join("assets");
    let assets_out_dir = out_dir.join("assets");

    // Rerun if the source assets directory changes
    println!("cargo:rerun-if-changed={}", source_dir.display());

    // Also rerun if individual asset files change
    rerun_if_changed_recursive(&source_dir);

    let config = AssetBuildConfig {
        source_dir,
        out_dir: assets_out_dir,
        patch_size: 16,
        index_limit: 32,
    };

    match build_assets(&config) {
        Ok(generated) => {
            for asset in &generated {
                println!(
                    "cargo:rerun-if-changed={}",
                    asset.source_path.display()
                );
            }
            eprintln!(
                "asset_build_tool: converted {} asset(s)",
                generated.len()
            );
        }
        Err(e) => {
            panic!("Asset build failed: {}", e);
        }
    }
}

/// Emit `cargo:rerun-if-changed` for all files under a directory.
fn rerun_if_changed_recursive(dir: &Path) {
    if !dir.is_dir() {
        return;
    }
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                rerun_if_changed_recursive(&path);
            } else {
                println!("cargo:rerun-if-changed={}", path.display());
            }
        }
    }
}
