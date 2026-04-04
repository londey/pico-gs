//! Z-buffer tile cache — 4-way set-associative write-back cache with
//! per-tile uninitialized flag tracking.
//!
//! This crate models the RTL `zbuf_tile_cache.sv` module including the
//! internal uninit flag EBR.
//! On cache miss, the uninit flag determines whether to lazy-fill
//! (zeros, no SDRAM read) or fetch from SDRAM.
//!
//! See UNIT-012 (Z-buffer tile cache).

// Spec-ref: unit_012_zbuf_tile_cache.md `cdf298cadd037658` 2026-04-04

pub mod uninit_flags;
pub mod zbuf_cache;

pub use uninit_flags::UninittedFlagArray;
pub use zbuf_cache::ZbufTileCache;
