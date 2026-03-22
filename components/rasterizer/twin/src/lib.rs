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

pub mod rasterize;
pub mod recip;
