//! Texture sampling component of the pico-gs digital twin.
//!
//! Facade crate that re-exports the texture pipeline sub-crates and
//! provides the top-level [`tex_sample::TextureSampler`] and
//! [`tex_sample::TrilinearBlender`] trait.
//!
//! # Sub-crate layout
//!
//! | Crate | Pipeline stage |
//! |-------|----------------|
//! | [`gs_tex_l1_cache`] | L1 decoded block cache |
//! | [`gs_tex_l2_cache`] | L2 compressed block cache |
//! | [`gs_tex_block_decoder`] | Format decoders + block fetcher |
//! | [`gs_tex_bilinear_filter`] | Bilinear/trilinear filter |

pub mod tex_sample;

// ── Re-exports for downstream consumers ─────────────────────────────────────

/// L1 decoded texture block cache.
pub mod tex_cache {
    pub use gs_tex_l1_cache::*;
}

/// L2 compressed texture block cache.
pub mod tex_compressed {
    pub use gs_tex_l2_cache::*;
}

/// Texture format decoders and block fetcher.
pub mod tex_decode {
    pub use gs_tex_block_decoder::tex_decode::*;
}

/// Block fetcher trait and implementation.
pub mod tex_fetch {
    pub use gs_tex_block_decoder::tex_fetch::*;
}

/// Texture filtering (sample gathering, bilinear blending, wrap modes).
pub mod tex_filter {
    pub use gs_tex_bilinear_filter::*;
}
