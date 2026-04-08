//! Bit-accurate fixed-point types with Q-notation for RTL digital twin modeling.
//!
//! Provides `Q<I, F>` (signed) and `UQ<I, F>` (unsigned) fixed-point types
//! where `I` is the number of integer bits (including sign for `Q`) and `F`
//! is the number of fractional bits.
//! Total bit width is `I + F`, backed by `i64`/`u64` internally.
//!
//! Arithmetic operators produce widened outputs that cannot overflow:
//! - `Q<I,F> + Q<I,F>` → `Q<{I+1}, F>`
//! - `Q<I,F> - Q<I,F>` → `Q<{I+1}, F>`
//! - `Q<I,F> * Q<I,F>` → `Q<{I+I}, {F+F}>`
//! - `-Q<I,F>` → `Q<{I+1}, F>`
//! - `UQ<I,F> - UQ<I,F>` → `Q<{I+1}, F>` (signed, since result can be negative)
//!
//! Use `.truncate()` or `.saturate()` to narrow results back down.
//! Use `wrapping_add`/`wrapping_sub`/`wrapping_mul` for same-type RTL
//! truncation semantics.
//! Use `saturating_add`/`saturating_sub`/`saturating_mul` to clamp.

#![no_std]
#![deny(unsafe_code)]
#![allow(incomplete_features)]
#![feature(generic_const_exprs)]
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
