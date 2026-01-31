/// Core type definitions for assets
pub mod types;

/// Identifier generation and sanitization
pub mod identifier;

/// PNG to RGBA8888 texture conversion
pub mod png_converter;

/// OBJ to mesh patch conversion
pub mod obj_converter;

/// Mesh splitting and patching algorithms
pub mod mesh_patcher;

/// Output file generation (Rust + binary)
pub mod output_gen;

use std::io::{self, Write};

/// Result type alias for asset-prep operations
pub type Result<T> = anyhow::Result<T>;

/// Progress reporting utility that respects --quiet flag
pub struct ProgressReporter {
    quiet: bool,
}

impl ProgressReporter {
    pub fn new(quiet: bool) -> Self {
        Self { quiet }
    }

    /// Print informational message to stdout (suppressed if --quiet)
    pub fn info(&self, msg: &str) {
        if !self.quiet {
            println!("{}", msg);
        }
    }

    /// Print warning message to stderr (always shown)
    pub fn warn(&self, msg: &str) {
        eprintln!("Warning: {}", msg);
    }

    /// Print error message to stderr (always shown)
    pub fn error(&self, msg: &str) {
        eprintln!("Error: {}", msg);
    }

    /// Print success message to stdout (suppressed if --quiet)
    pub fn success(&self, msg: &str) {
        if !self.quiet {
            println!("✓ {}", msg);
        }
    }

    /// Flush stdout
    pub fn flush(&self) -> io::Result<()> {
        io::stdout().flush()
    }
}
