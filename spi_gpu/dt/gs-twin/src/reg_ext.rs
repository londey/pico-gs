//! Helpers for constructing gpu-registers types from raw `u64` values.
//!
//! The generated register types are `#[repr(transparent)]` wrappers over `u64`,
//! but `from_raw()` lives on a `pub(crate)` trait and is inaccessible to
//! external crates.
//! Since the types are transparent newtypes, `transmute` from `u64` is
//! trivially sound.

use gpu_registers::components::gpu_regs::named_types::{
    fb_config_reg::FbConfigReg, fb_control_reg::FbControlReg, render_mode_reg::RenderModeReg,
    vertex_reg::VertexReg,
};

/// Construct a `RenderModeReg` from a raw 64-bit register value.
///
/// # Safety rationale
///
/// `RenderModeReg` is `#[repr(transparent)]` over `u64`, so this transmute
/// is a no-op at the machine level.
#[allow(unsafe_code)]
pub fn render_mode_from_raw(raw: u64) -> RenderModeReg {
    unsafe { core::mem::transmute(raw) }
}

/// Construct a `FbConfigReg` from a raw 64-bit register value.
#[allow(unsafe_code)]
pub fn fb_config_from_raw(raw: u64) -> FbConfigReg {
    unsafe { core::mem::transmute(raw) }
}

/// Construct a `FbControlReg` from a raw 64-bit register value.
#[allow(unsafe_code)]
pub fn fb_control_from_raw(raw: u64) -> FbControlReg {
    unsafe { core::mem::transmute(raw) }
}

/// Construct a `VertexReg` from a raw 64-bit register value.
#[allow(unsafe_code)]
pub fn vertex_from_raw(raw: u64) -> VertexReg {
    unsafe { core::mem::transmute(raw) }
}
