//! GPU command types shared between the register-write interface and memory.

/// Depth comparison function.
///
/// # RTL Implementation Notes
/// Encoded as a 3-bit register field (RENDER_MODE[15:13]).
/// The comparison is performed on raw 16-bit Z-buffer values.
///
/// Codes: `3'b000` = LESS, `3'b001` = LEQUAL, `3'b010` = EQUAL,
/// `3'b011` = GEQUAL, `3'b100` = GREATER, `3'b101` = NOTEQUAL,
/// `3'b110` = ALWAYS, `3'b111` = NEVER.
#[derive(Debug, Clone, Copy, Default)]
pub enum DepthFunc {
    Never,
    #[default]
    Less,
    LessEqual,
    Equal,
    Greater,
    GreaterEqual,
    NotEqual,
    Always,
}
