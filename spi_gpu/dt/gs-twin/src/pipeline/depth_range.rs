//! Depth range clip — discard fragments outside [z_min, z_max].
//!
//! Fragments with Z values outside the configured depth range are
//! discarded before the early Z test, avoiding unnecessary Z-buffer
//! traffic.
//!
//! # RTL Implementation Notes
//!
//! Can kill the fragment (✗).
//! Precedes the early Z test in the pipeline.

use super::fragment::RasterFragment;

/// Clip a fragment against the depth range.
///
/// # Arguments
///
/// * `frag` - Rasterizer output fragment.
/// * `z_range_min` - Minimum allowed depth (unsigned 16-bit, inclusive).
/// * `z_range_max` - Maximum allowed depth (unsigned 16-bit, inclusive).
///
/// # Returns
///
/// `Some(frag)` if the fragment's depth is within range, `None` if clipped.
pub fn depth_range_clip(
    frag: RasterFragment,
    _z_range_min: u16,
    _z_range_max: u16,
) -> Option<RasterFragment> {
    // TODO: implement z range comparison
    Some(frag)
}
