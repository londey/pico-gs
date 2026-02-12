use std::path::PathBuf;

/// Errors that can occur during asset conversion.
#[derive(Debug, thiserror::Error)]
pub enum AssetError {
    /// I/O error reading or writing files.
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    /// Failed to decode a PNG image.
    #[error("Image decode error for {path}: {message}")]
    ImageDecode { path: PathBuf, message: String },

    /// Failed to parse an OBJ mesh file.
    #[error("OBJ parse error for {path}: {message}")]
    ObjParse { path: PathBuf, message: String },

    /// Input validation failed (dimensions, empty mesh, etc.).
    #[error("Validation error: {0}")]
    Validation(String),

    /// Two different source files produce the same Rust identifier.
    #[error("Identifier collision: {identifier} is produced by both {path_a} and {path_b}")]
    IdentifierCollision {
        identifier: String,
        path_a: PathBuf,
        path_b: PathBuf,
    },

    /// Error generating output files.
    #[error("Code generation error: {0}")]
    CodeGen(String),
}
