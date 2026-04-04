//! Z-buffer tile cache — 4-way set-associative write-back cache with
//! per-tile uninitialized flag tracking.
//!
//! This crate models the RTL `zbuf_tile_cache.sv` module including the
//! internal uninit flag EBR.
//! On cache miss, the uninit flag determines whether to lazy-fill
//! (zeros, no SDRAM read) or fetch from SDRAM.
//!
//! See UNIT-009.01 (Z-buffer tile cache).

pub mod uninit_flags;
pub mod zbuf_cache;

pub use uninit_flags::UninittedFlagArray;
pub use zbuf_cache::ZbufTileCache;
