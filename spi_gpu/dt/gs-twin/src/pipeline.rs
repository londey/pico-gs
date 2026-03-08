//! Graphics pipeline stages matching the RTL fragment pipeline.
//!
//! The GPU accepts pre-transformed screen-space vertices via register
//! writes (Q12.4 coordinates, RGBA8888 colors).
//! The rasterizer converts these to fragments which flow through the
//! pixel pipeline stages defined in ARCHITECTURE.md.
//!
//! # Pipeline flow
//!
//! ```text
//! Rasterizer ──→ RasterFragment
//!   → stipple_test → depth_range_clip → early_z_test
//!   → tex_sample ──→ TexturedFragment
//!   → color_combine_0 → color_combine_1 ──→ ColoredFragment
//!   → alpha_test → alpha_blend
//!   → dither ──→ PixelOut
//!   → pixel_write
//! ```

pub mod fragment;
pub mod rasterize;

// ── Fragment pipeline stages (per-pixel) ─────────────────────────────────────

pub mod alpha_blend;
pub mod alpha_test;
pub mod color_combine;
pub mod depth_range;
pub mod dither;
pub mod early_z;
pub mod pixel_write;
pub mod stipple;
pub mod tex_sample;

// ── Display scanout pipeline ─────────────────────────────────────────────────

pub mod display;
