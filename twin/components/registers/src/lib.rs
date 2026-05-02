//! Control/Status Register crate generated with PeakRDL-rust
//!
//! The bulk of this crate is auto-generated from
//! `rtl/components/registers/rdl/gpu_regs.rdl` by
//! `rtl/components/registers/scripts/generate.sh`.  Hand-maintained items in
//! this file (re-exports and convenience constants) live alongside the
//! generated `components/` tree to give consumers stable, ergonomic access
//! to commonly used register addresses and field encodings.
#![no_std]
#![allow(clippy::cast_lossless)]
#![allow(clippy::cast_possible_wrap)]
#![allow(clippy::cast_sign_loss)]
#![allow(clippy::derivable_impls)]
#![allow(clippy::doc_markdown)]
#![allow(clippy::identity_op)]
#![allow(clippy::inline_always)]
#![allow(clippy::let_and_return)]
#![allow(clippy::trivially_copy_pass_by_ref)]
#![allow(clippy::unnecessary_cast)]

// `_root` is an internal alias used by the PeakRDL-generated `components/`
// tree to reach back into this crate's root for cross-module re-exports
// (see e.g. `components/gpu_regs.rs`).  Keep it private to the crate.
#[cfg(not(doctest))]
use crate as _root;

#[cfg(not(doctest))]
pub mod components;

#[cfg(not(doctest))]
pub use crate::components::gpu_regs::GpuRegs;

// ---------------------------------------------------------------------------
// Convenience constants
// ---------------------------------------------------------------------------
//
// These constants mirror the authoritative SystemRDL definitions in
// `rtl/components/registers/rdl/gpu_regs.rdl` and exist for callers that
// need raw 7-bit register indices or bare bit positions (for example, the
// SPI command FIFO and the digital twin register decoder).  Update these
// alongside any RDL change that affects the same field.

/// 7-bit register index of TEX0_CFG (texture sampler 0 configuration).
pub const TEX0_CFG_ADDR: u8 = 0x10;

/// 7-bit register index of TEX1_CFG (texture sampler 1 configuration).
pub const TEX1_CFG_ADDR: u8 = 0x11;

/// 7-bit register index of PALETTE0 (palette slot 0 load control).
pub const PALETTE0_ADDR: u8 = 0x12;

/// 7-bit register index of PALETTE1 (palette slot 1 load control).
pub const PALETTE1_ADDR: u8 = 0x13;

/// `tex_format_e` encoding for INDEXED8_2X2 (the only currently legal
/// texture format).  Values 1..=15 are reserved.
pub const TEX_FORMAT_INDEXED8_2X2: u8 = 0;

/// Bit position of `TEXn_CFG.PALETTE_IDX` (selects palette slot 0 or 1).
pub const TEX_CFG_PALETTE_IDX_SHIFT: u32 = 24;

/// Field mask of `TEXn_CFG.PALETTE_IDX` (single bit) before shifting.
pub const TEX_CFG_PALETTE_IDX_MASK: u64 = 0x1;

/// Field mask of `PALETTEn.BASE_ADDR` (16 bits, ×512 to form SDRAM byte
/// address) before shifting.
pub const PALETTE_BASE_ADDR_MASK: u64 = 0xFFFF;

/// Bit position of `PALETTEn.LOAD_TRIGGER` (self-clearing pulse).
pub const PALETTE_LOAD_TRIGGER_BIT: u64 = 1 << 16;

/// 7-bit register index of FB_CACHE_CTRL (color tile cache flush/invalidate).
///
/// See INT-010 §0x45 for the full register description and blocking
/// semantics.  The RDL byte address `0x228` corresponds to SPI register
/// index `0x45` because the RDL uses byte addresses with an 8-byte stride
/// per register (`0x45 * 8 = 0x228`).
pub const FB_CACHE_CTRL: u8 = 0x45;

/// Bit position of `FB_CACHE_CTRL.FLUSH_TRIGGER` (self-clearing pulse).
///
/// Writing 1 to this bit triggers a write-back of all dirty 4×4 tiles
/// in the color-buffer cache (UNIT-013) and blocks the SPI command stream
/// until the flush completes.  See INT-010 §0x45.
pub const FB_CACHE_CTRL_FLUSH_TRIGGER_BIT: u8 = 0;

/// Bit position of `FB_CACHE_CTRL.INVALIDATE_TRIGGER` (self-clearing pulse).
///
/// Writing 1 to this bit drops all valid and dirty bits in the
/// color-buffer cache (UNIT-013) and resets the per-tile uninitialized
/// flag array, blocking the SPI command stream until the sweep completes.
/// See INT-010 §0x45.
pub const FB_CACHE_CTRL_INVALIDATE_TRIGGER_BIT: u8 = 1;
