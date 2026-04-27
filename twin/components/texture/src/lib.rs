// Spec-ref: unit_011_texture_sampler.md

//! Texture sampling component of the pico-gs digital twin.
//!
//! Facade crate that wires together the INDEXED8_2X2 sampling pipeline:
//!
//! | Crate | UNIT | Stage |
//! |-------|------|-------|
//! | [`gs_tex_uv_coord`] | UNIT-011.01 | UV wrap + half-resolution split |
//! | [`gs_tex_l1_cache`] | UNIT-011.03 | Half-resolution index cache |
//! | [`gs_tex_palette_lut`] | UNIT-011.06 | Shared 2-slot palette LUT |
//!
//! The top-level [`tex_sample::TextureSampler`] facade owns one
//! [`gs_tex_l1_cache::IndexCache`] per hardware sampler; the shared
//! [`gs_tex_palette_lut::PaletteLut`] is owned by the orchestrator and
//! passed by reference into [`tex_sample::tex_sample`] each fragment.

pub mod tex_sample;

// ── Re-exports for downstream consumers ─────────────────────────────────────

/// Half-resolution texture index cache (UNIT-011.03).
pub mod tex_index_cache {
    pub use gs_tex_l1_cache::*;
}

/// Shared two-slot palette LUT (UNIT-011.06).
pub mod tex_palette {
    pub use gs_tex_palette_lut::*;
}

/// UV coordinate wrap + quadrant extraction (UNIT-011.01).
pub mod tex_uv {
    pub use gs_tex_uv_coord::*;
}
