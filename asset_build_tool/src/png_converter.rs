use crate::identifier::generate_identifier;
use crate::types::TextureAsset;
use crate::ProgressReporter;
use anyhow::{bail, Context, Result};
use image::{DynamicImage, GenericImageView};
use std::path::{Path, PathBuf};

/// Check if a number is a power of two
fn is_power_of_two(n: u32) -> bool {
    n > 0 && (n & (n - 1)) == 0
}

/// Validate texture dimensions against GPU constraints
fn validate_texture_dimensions(width: u32, height: u32) -> Result<()> {
    // Check power-of-two
    if !is_power_of_two(width) {
        bail!(
            "Texture width {} is not power-of-two. Valid sizes: 8, 16, 32, 64, 128, 256, 512, 1024",
            width
        );
    }
    if !is_power_of_two(height) {
        bail!(
            "Texture height {} is not power-of-two. Valid sizes: 8, 16, 32, 64, 128, 256, 512, 1024",
            height
        );
    }

    // Check range (8×8 to 1024×1024)
    if width < 8 || width > 1024 {
        bail!(
            "Texture width {} out of range. Must be between 8 and 1024 (power-of-two)",
            width
        );
    }
    if height < 8 || height > 1024 {
        bail!(
            "Texture height {} out of range. Must be between 8 and 1024 (power-of-two)",
            height
        );
    }

    Ok(())
}

/// Load and validate PNG image
fn load_and_validate_png(path: &Path) -> Result<DynamicImage> {
    let img = image::open(path)
        .with_context(|| format!("Failed to load PNG image: {}", path.display()))?;

    let (width, height) = img.dimensions();

    validate_texture_dimensions(width, height)
        .with_context(|| format!("Invalid texture dimensions for: {}", path.display()))?;

    Ok(img)
}

/// Convert image to RGBA8 format
fn convert_to_rgba8(img: DynamicImage) -> Vec<u8> {
    let rgba = img.to_rgba8();
    rgba.into_raw()
}

/// Convert PNG texture to RGBA8888 format
///
/// This function:
/// - Loads the PNG image
/// - Validates dimensions (power-of-two, 8-1024 range)
/// - Converts to RGBA8888 format
/// - Generates a unique identifier
/// - Returns a TextureAsset ready for output generation
pub fn convert_texture(input: PathBuf, quiet: bool) -> Result<TextureAsset> {
    let reporter = ProgressReporter::new(quiet);

    // Report start
    reporter.info(&format!("Converting texture: {}", input.display()));

    // Load and validate
    let img = load_and_validate_png(&input)?;
    let (width, height) = img.dimensions();

    reporter.info(&format!(
        "  Dimensions: {}×{} (valid power-of-two)",
        width, height
    ));

    // Convert to RGBA8
    let data = convert_to_rgba8(img);
    let size_bytes = data.len();

    reporter.info(&format!(
        "  Size: {} bytes ({} KB)",
        size_bytes,
        size_bytes / 1024
    ));

    // Generate identifier
    let identifier = generate_identifier(&input)
        .with_context(|| format!("Failed to generate identifier for: {}", input.display()))?;

    reporter.info(&format!("  Identifier: {}", identifier));

    // Create asset
    let asset = TextureAsset {
        source: input.clone(),
        width,
        height,
        data,
        identifier: identifier.clone(),
    };

    // Validate
    if !asset.is_valid_dimensions() {
        bail!("Internal error: TextureAsset has invalid dimensions");
    }

    reporter.success(&format!(
        "Converted {} → {} ({}×{}, {} KB)",
        input.display(),
        identifier,
        width,
        height,
        size_bytes / 1024
    ));

    Ok(asset)
}

/// Handle grayscale PNG by replicating luminance to RGB
fn convert_grayscale_to_rgba(img: &DynamicImage) -> Vec<u8> {
    let rgba = img.to_rgba8();
    rgba.into_raw()
}

/// Handle indexed color PNG by applying palette
fn convert_indexed_to_rgba(img: &DynamicImage) -> Vec<u8> {
    let rgba = img.to_rgba8();
    rgba.into_raw()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_power_of_two() {
        assert!(is_power_of_two(8));
        assert!(is_power_of_two(16));
        assert!(is_power_of_two(256));
        assert!(is_power_of_two(1024));

        assert!(!is_power_of_two(0));
        assert!(!is_power_of_two(7));
        assert!(!is_power_of_two(300));
        assert!(!is_power_of_two(1000));
    }

    #[test]
    fn test_validate_texture_dimensions() {
        // Valid dimensions
        assert!(validate_texture_dimensions(256, 256).is_ok());
        assert!(validate_texture_dimensions(1024, 512).is_ok());
        assert!(validate_texture_dimensions(8, 8).is_ok());

        // Invalid: not power-of-two
        assert!(validate_texture_dimensions(300, 200).is_err());

        // Invalid: out of range
        assert!(validate_texture_dimensions(4, 4).is_err());
        assert!(validate_texture_dimensions(2048, 1024).is_err());
    }
}
