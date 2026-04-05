//! Cycle-accurate model of the W9825G6KH SDRAM (256 Mbit, 16-bit, 100 MHz).
//!
//! Provides two abstraction levels:
//!
//! - [`SdramController`] — models the controller-level `mem_*` signal interface
//!   used by UNIT-007 (Memory Arbiter).  This is a direct Rust port of the C++
//!   `SdramModelSim` and is what the pico-gs emulator uses.
//!
//! - (Future) `SdramChip` — command-level model accepting raw SDRAM commands
//!   (ACTIVATE, READ, WRITE, etc.) for verifying the SDRAM controller RTL.

#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::must_use_candidate)]
#![allow(clippy::missing_errors_doc)]
#![allow(clippy::missing_panics_doc)]
#![allow(clippy::enum_variant_names)]
#![allow(dead_code)]
#![allow(unused_crate_dependencies)]

mod controller;
pub mod timing;

pub use controller::{SdramController, SdramInput, SdramOutput, SdramState};
