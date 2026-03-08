//! Pixel write — final framebuffer and Z-buffer output.
//!
//! Writes the fragment's RGB565 color to the framebuffer and
//! optionally updates the Z-buffer, controlled by per-draw-call
//! write-enable flags.
//!
//! # RTL Implementation Notes
//!
//! Color writes go through a write-coalescing buffer before reaching
//! the SDRAM arbiter; Z updates go through the Z-buffer tile cache.
//! See UNIT-006, pixel_write stage.

use super::fragment::PixelOut;
use crate::mem::{Framebuffer, RawZBuffer};

/// Write a fragment to the framebuffer and Z-buffer.
///
/// # Arguments
///
/// * `frag` - Final pixel output (RGB565 color + depth).
/// * `framebuffer` - Mutable framebuffer for color writes.
/// * `zbuf` - Mutable Z-buffer for depth writes.
/// * `color_write_en` - Whether color writes are enabled.
/// * `z_write_en` - Whether Z-buffer writes are enabled.
pub fn pixel_write(
    _frag: &PixelOut,
    _framebuffer: &mut Framebuffer,
    _zbuf: &mut RawZBuffer,
    _color_write_en: bool,
    _z_write_en: bool,
) {
    // TODO: implement framebuffer and Z-buffer writes
}
