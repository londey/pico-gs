//! Cycle-accurate models of ECP5 FPGA primitives.
//!
//! These models can be explicitly instantiated in a cycle-accurate emulator
//! to match the RTL's use of ECP5 hard resources (block RAM, DSP multipliers,
//! PLL).  Each primitive's `tick()` method advances one clock cycle, matching
//! the documented Lattice ECP5 behavior.

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

pub mod dp16kd;
pub mod mult18x18d;
pub mod pdpw16kd;
mod pll;

pub use dp16kd::{
    BramPort, BramWriteMode, Dp16kd, PortInput, PortOutput, ReadBeforeWrite, W18x1024, W1x16384,
    W2x8192, W36x512, W4x4096, W9x2048, WriteNormal, WriteThrough,
};
pub use mult18x18d::{Combinational, InputRegistered, MulPipeline, Mult18x18d, Pipelined};
pub use pdpw16kd::{
    PdpRead18, PdpRead36, PdpRead9, PdpReadWidth, Pdpw16kd, Pdpw16kdReadInput, Pdpw16kdWriteInput,
};
pub use pll::{Pll, PllConfig, PllOutputs};
