//! Cycle-accurate GPU emulator for the pico-gs graphics processor.
//!
//! Uses a double-buffered pure-function architecture: every module reads
//! from `prev: &GpuState` and returns its portion of the next state.
//! This prevents evaluation-order bugs — you cannot read a value written
//! in the same cycle.
//!
//! ECP5 FPGA primitives (block RAM, DSP multipliers) are explicitly
//! instantiated using the `ecp5_model` crate, matching the RTL's use
//! of hard resources.
//!
//! SDRAM is modeled cycle-accurately using the `sdram_model` crate,
//! including CAS latency, row activation, auto-refresh, and burst
//! transfers.

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

mod clock;
mod modules;
mod state;
mod tick;

pub use clock::ClockState;
pub use state::{
    DisplayState, GpuState, InfraState, MemoryArbiterState, PixelPipelineState, RasterizerState,
};
pub use tick::Emulator;
