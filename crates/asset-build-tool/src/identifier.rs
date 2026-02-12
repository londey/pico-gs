use crate::error::AssetError;
use std::collections::HashMap;
use std::path::Path;

/// Generate a Rust identifier from a file path.
///
/// Includes the immediate parent directory name to avoid conflicts
/// (e.g., `textures/player.png` → `TEXTURES_PLAYER`).
pub fn generate_identifier(path: &Path) -> Result<String, AssetError> {
    let filename = path
        .file_stem()
        .and_then(|s| s.to_str())
        .ok_or_else(|| AssetError::Validation(format!("Invalid filename: {}", path.display())))?;

    let parent = path
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str());

    let sanitized_filename = sanitize_to_rust_ident(filename);

    let identifier = if let Some(parent_name) = parent {
        let sanitized_parent = sanitize_to_rust_ident(parent_name);
        format!("{}_{}", sanitized_parent, sanitized_filename)
    } else {
        sanitized_filename
    };

    Ok(identifier.to_uppercase())
}

/// Check a list of source paths for identifier collisions.
///
/// Returns `Ok(())` if no collisions, or `Err(IdentifierCollision)` with
/// the first collision found.
pub fn check_collisions(paths: &[&Path]) -> Result<(), AssetError> {
    let mut seen: HashMap<String, &Path> = HashMap::new();

    for &path in paths {
        let ident = generate_identifier(path)?;
        if let Some(&previous) = seen.get(&ident) {
            return Err(AssetError::IdentifierCollision {
                identifier: ident,
                path_a: previous.to_path_buf(),
                path_b: path.to_path_buf(),
            });
        }
        seen.insert(ident, path);
    }

    Ok(())
}

/// Sanitize a string to a valid Rust identifier component.
fn sanitize_to_rust_ident(s: &str) -> String {
    let mut result = String::with_capacity(s.len());

    for (i, ch) in s.chars().enumerate() {
        if i == 0 {
            if ch.is_alphabetic() || ch == '_' {
                result.push(ch);
            } else if ch.is_numeric() {
                result.push('_');
                result.push(ch);
            } else {
                result.push('_');
            }
        } else if ch.is_alphanumeric() || ch == '_' {
            result.push(ch);
        } else {
            result.push('_');
        }
    }

    if result.is_empty() {
        result.push_str("ASSET");
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn test_sanitize_simple() {
        assert_eq!(sanitize_to_rust_ident("player"), "player");
        assert_eq!(sanitize_to_rust_ident("my_texture"), "my_texture");
    }

    #[test]
    fn test_sanitize_special_chars() {
        assert_eq!(sanitize_to_rust_ident("my-texture"), "my_texture");
        assert_eq!(sanitize_to_rust_ident("button@hover"), "button_hover");
        assert_eq!(sanitize_to_rust_ident("foo.bar"), "foo_bar");
    }

    #[test]
    fn test_sanitize_leading_digit() {
        assert_eq!(sanitize_to_rust_ident("3d-cube"), "_3d_cube");
    }

    #[test]
    fn test_generate_identifier_with_parent() {
        let path = PathBuf::from("textures/player.png");
        assert_eq!(generate_identifier(&path).unwrap(), "TEXTURES_PLAYER");
    }

    #[test]
    fn test_generate_identifier_without_parent() {
        let path = PathBuf::from("cube.obj");
        assert_eq!(generate_identifier(&path).unwrap(), "CUBE");
    }

    #[test]
    fn test_generate_identifier_special_chars() {
        let path = PathBuf::from("ui/button-hover.png");
        assert_eq!(generate_identifier(&path).unwrap(), "UI_BUTTON_HOVER");
    }

    #[test]
    fn test_generate_identifier_deeply_nested() {
        // Only immediate parent is used
        let path = PathBuf::from("assets/textures/characters/player.png");
        assert_eq!(generate_identifier(&path).unwrap(), "CHARACTERS_PLAYER");
    }

    #[test]
    fn test_no_collision() {
        let paths: Vec<&Path> = vec![
            Path::new("textures/player.png"),
            Path::new("ui/player.png"),
            Path::new("textures/enemy.png"),
        ];
        assert!(check_collisions(&paths).is_ok());
    }

    #[test]
    fn test_collision_detected() {
        let paths: Vec<&Path> = vec![
            Path::new("textures/foo@bar.png"),
            Path::new("textures/foo_bar.png"),
        ];
        let err = check_collisions(&paths).unwrap_err();
        match err {
            AssetError::IdentifierCollision { identifier, .. } => {
                assert_eq!(identifier, "TEXTURES_FOO_BAR");
            }
            _ => panic!("Expected IdentifierCollision error"),
        }
    }
}
