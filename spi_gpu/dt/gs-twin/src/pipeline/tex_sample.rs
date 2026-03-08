//! Texture sampling — fetch texels from TEX0 and TEX1 units.
//!
//! Samples both texture units using the fragment's perspective-corrected
//! UV coordinates and LOD.
//! The rasterizer has already performed perspective correction
//! (true U = S×(1/Q), true V = T×(1/Q)), so no per-pixel division
//! is needed here.
//!
//! # RTL Implementation Notes
//!
//! Each texture unit has an independent 4-way set-associative cache.
//! Cache misses stall the pipeline until the SDRAM fill completes.
//! See UNIT-006, texture_cache.sv.

use super::fragment::{ColorQ412, RasterFragment, TexturedFragment};
use crate::mem::TextureStore;

/// Sample TEX0 and TEX1, producing a `TexturedFragment`.
///
/// Consumes the UV and LOD lanes from the rasterizer output;
/// produces tex0 and tex1 sampled colors.
///
/// # Arguments
///
/// * `frag` - Rasterizer fragment with UV/LOD data.
/// * `textures` - Texture store for cache/sample access.
///
/// # Returns
///
/// A `TexturedFragment` with sampled texel colors.
/// `comb` is `None` (populated later by color combiner stage 0).
pub fn tex_sample(frag: RasterFragment, _textures: &TextureStore) -> TexturedFragment {
    // TODO: implement texture sampling via UV/LOD lookup
    // Stub: white texels (1.0 in Q4.12 = opaque white)
    let white = ColorQ412::default();

    TexturedFragment {
        x: frag.x,
        y: frag.y,
        z: frag.z,
        shade0: frag.shade0,
        shade1: frag.shade1,
        tex0: white,
        tex1: white,
        comb: None,
    }
}
