use anyhow::{bail, Context, Result};
use std::collections::HashSet;
use std::path::Path;

/// Generate a Rust identifier from a file path
/// Includes parent directory name to avoid conflicts (e.g., textures/player.png → TEXTURES_PLAYER)
pub fn generate_identifier(path: &Path) -> Result<String> {
    let filename = path
        .file_stem()
        .context("Invalid filename")?
        .to_str()
        .context("Non-UTF8 filename")?;

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

/// Sanitize a string to a valid Rust identifier
/// Replaces invalid characters with underscores, ensures it starts with letter/underscore
fn sanitize_to_rust_ident(s: &str) -> String {
    let mut result = String::with_capacity(s.len());

    for (i, ch) in s.chars().enumerate() {
        if i == 0 {
            // First character must be letter or underscore
            if ch.is_alphabetic() || ch == '_' {
                result.push(ch);
            } else if ch.is_numeric() {
                result.push('_');
                result.push(ch);
            } else {
                result.push('_');
            }
        } else {
            // Subsequent characters can be alphanumeric or underscore
            if ch.is_alphanumeric() || ch == '_' {
                result.push(ch);
            } else {
                result.push('_');
            }
        }
    }

    // Handle empty result
    if result.is_empty() {
        result.push_str("ASSET");
    }

    result
}

/// Detect identifier conflicts in a set of file paths
pub fn detect_conflicts(paths: &[&Path]) -> Result<Vec<String>> {
    let mut seen = HashSet::new();
    let mut conflicts = Vec::new();

    for path in paths {
        let ident = generate_identifier(path)?;
        if !seen.insert(ident.clone()) {
            conflicts.push(ident);
        }
    }

    Ok(conflicts)
}

/// Check if identifier already exists and suggest alternative
pub fn check_conflict(identifier: &str, existing: &HashSet<String>) -> Option<String> {
    if existing.contains(identifier) {
        Some(format!(
            "Identifier '{}' conflicts with existing asset. \
             Consider renaming the source file or moving it to a different directory.",
            identifier
        ))
    } else {
        None
    }
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
    fn test_sanitize_with_invalid_chars() {
        assert_eq!(sanitize_to_rust_ident("my-texture"), "my_texture");
        assert_eq!(sanitize_to_rust_ident("texture.old"), "texture_old");
        assert_eq!(sanitize_to_rust_ident("123start"), "_123start");
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
    fn test_conflict_detection() {
        let paths: Vec<&Path> = vec![
            Path::new("textures/player.png"),
            Path::new("ui/player.png"), // Different parent, no conflict
            Path::new("textures/enemy.png"),
        ];
        let conflicts = detect_conflicts(&paths).unwrap();
        assert_eq!(conflicts.len(), 0);
    }
}
