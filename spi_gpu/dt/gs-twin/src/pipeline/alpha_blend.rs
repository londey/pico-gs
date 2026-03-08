//! Alpha blending — blend fragment color with framebuffer destination.
//!
//! Reads the destination pixel from the framebuffer, promotes it to
//! Q4.12, blends with the fragment color using the configured blend
//! mode, and writes the result back through the normal dither path.
//!
//! # RTL Implementation Notes
//!
//! Alpha blending promotes the framebuffer's UNORM RGB565 value to
//! Q4.12 before blending; the result follows the normal
//! dither-and-write path.
//! Requires an SDRAM framebuffer read (dst pixel).

use super::fragment::ColoredFragment;
use crate::mem::Framebuffer;

/// Blend a fragment with the destination framebuffer pixel.
///
/// # Arguments
///
/// * `frag` - Colored fragment (after alpha test).
/// * `framebuffer` - Framebuffer for destination pixel reads.
/// * `blend_en` - Whether alpha blending is enabled.
///
/// # Returns
///
/// The blended `ColoredFragment`.
pub fn alpha_blend(
    frag: ColoredFragment,
    _framebuffer: &Framebuffer,
    _blend_en: bool,
) -> ColoredFragment {
    // TODO: implement dst read, UNORM→Q4.12 promotion, blend
    frag
}
