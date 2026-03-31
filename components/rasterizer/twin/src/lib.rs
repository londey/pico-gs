#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::must_use_candidate)]
#![allow(clippy::missing_errors_doc)]
#![allow(clippy::missing_panics_doc)]
// Until 1.0.0, allow dead code and unused dependency warnings
#![allow(dead_code)]
#![allow(unused_crate_dependencies)]

//! Rasterizer component of the pico-gs digital twin.
//!
//! Derivative-based triangle rasterizer matching the RTL pipeline.
//! Sub-modules mirror RTL module boundaries for per-module verification.

pub mod attr_accum;
pub mod deriv;
pub mod dsp_mul;
pub mod edge_walk;
pub mod recip;
pub mod setup;

/// Facade module preserving the original `rasterize::*` public API.
///
/// Re-exports all public items from the decomposed sub-modules under
/// the original `rasterize` namespace, ensuring downstream crates
/// (gs-twin orchestrator, raster_viz tests) compile without changes.
pub mod rasterize {
    pub use crate::edge_walk::{
        rasterize_iter, rasterize_iter_debug, rasterize_iter_hiz, rasterize_iter_hiz_debug,
        rasterize_triangle, rasterize_triangle_hiz, HizMetadata, TriangleIter,
    };
    pub use crate::setup::{triangle_setup, TriangleSetup};
}

pub use rasterize::HizMetadata;
