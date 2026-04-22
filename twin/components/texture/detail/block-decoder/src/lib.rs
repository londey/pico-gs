#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]
#![allow(dead_code)]
#![allow(unused_crate_dependencies)]

//! Texture block decompressor and fetcher for the pico-gs digital twin.
//!
//! Owns texture format decoders (BC1–BC4, RGB565, RGBA8888, R8) and the
//! two-level cache fetch orchestrator ([`BlockFetcher`](tex_fetch::BlockFetcher)).

pub mod tex_decode;
pub mod tex_fetch;
