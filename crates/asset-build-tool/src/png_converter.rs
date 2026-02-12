use crate::error::AssetError;
use crate::identifier::generate_identifier;
use crate::types::TextureAsset;
use image::GenericImageView;
use std::path::Path;

/// Check if a number is a power of two.
fn is_power_of_two(n: u32) -> bool {
    n > 0 && (n & (n - 1)) == 0
}

/// Validate texture dimensions against GPU constraints.
fn validate_dimensions(width: u32, height: u32) -> Result<(), AssetError> {
    if !is_power_of_two(width) || !is_power_of_two(height) {
        return Err(AssetError::Validation(format!(
            "Expected power-of-two dimensions, got {}×{}. Try {}×{} or {}×{}.",
            width,
            height,
            width.next_power_of_two(),
            height.next_power_of_two(),
            width.next_power_of_two() / 2,
            height.next_power_of_two() / 2
        )));
    }

    if width < 8 || height < 8 {
        return Err(AssetError::Validation(format!(
            "Dimensions {}×{} below GPU minimum (8×8)",
            width, height
        )));
    }

    if width > 1024 || height > 1024 {
        return Err(AssetError::Validation(format!(
            "Dimensions {}×{} exceed GPU maximum (1024×1024)",
            width, height
        )));
    }

    Ok(())
}

/// Load a PNG file, validate dimensions, convert to RGBA8888, and return a `TextureAsset`.
pub fn load_and_convert(path: &Path) -> Result<TextureAsset, AssetError> {
    let img = image::open(path).map_err(|e| AssetError::ImageDecode {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;

    let (width, height) = img.dimensions();
    validate_dimensions(width, height)?;

    let rgba = img.to_rgba8();
    let data = rgba.into_raw();

    let identifier = generate_identifier(path)?;

    log::info!(
        "  Dimensions: {}×{} RGBA8, Size: {} bytes ({:.1} KB), Identifier: {}",
        width,
        height,
        data.len(),
        data.len() as f64 / 1024.0,
        identifier
    );

    Ok(TextureAsset {
        source: path.to_path_buf(),
        width,
        height,
        data,
        identifier,
    })
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
    }

    #[test]
    fn test_validate_dimensions_valid() {
        assert!(validate_dimensions(256, 256).is_ok());
        assert!(validate_dimensions(8, 8).is_ok());
        assert!(validate_dimensions(1024, 512).is_ok());
        assert!(validate_dimensions(128, 64).is_ok());
    }

    #[test]
    fn test_validate_dimensions_not_power_of_two() {
        assert!(validate_dimensions(300, 200).is_err());
        assert!(validate_dimensions(100, 256).is_err());
    }

    #[test]
    fn test_validate_dimensions_too_small() {
        assert!(validate_dimensions(4, 4).is_err());
        assert!(validate_dimensions(2, 8).is_err());
    }

    #[test]
    fn test_validate_dimensions_too_large() {
        assert!(validate_dimensions(2048, 1024).is_err());
        assert!(validate_dimensions(1024, 2048).is_err());
    }
}
