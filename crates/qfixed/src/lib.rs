//! Bit-accurate fixed-point types with Q-notation for RTL digital twin modeling.
//!
//! Provides `Q<I, F>` (signed) and `UQ<I, F>` (unsigned) fixed-point types
//! where `I` is the number of integer bits (including sign for `Q`) and `F`
//! is the number of fractional bits.
//! Total bit width is `I + F`, backed by `i64`/`u64` internally.
//!
//! Overflow behavior matches Rust integers: traps in debug, wraps in release.
//! Explicit `wrapping_*` methods are provided for intentional rollover.
//! Multiplication always requires explicit width management via `widening_mul`
//! or `wrapping_mul`.

#![no_std]
#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::must_use_candidate)]
#![allow(clippy::missing_errors_doc)]
#![allow(clippy::missing_panics_doc)]
// Until 1.0.0, allow dead code and unused dependency warnings.
#![allow(dead_code)]
#![allow(unused_crate_dependencies)]

mod convert;
mod fmt;
mod ops;
mod q;
#[cfg(feature = "serde")]
mod serde_impl;
mod uq;

pub use q::Q;
pub use uq::UQ;
