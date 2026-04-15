#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::must_use_candidate)]
#![allow(clippy::missing_errors_doc)]
#![allow(clippy::missing_panics_doc)]
#![allow(dead_code)]
#![allow(unused_crate_dependencies)]

//! # gs-twin-core
//!
//! Shared types and utilities for the pico-gs digital twin.
//!
//! This crate provides the foundation types used across all pipeline
//! component crates: fragment types, color formats, texel formats,
//! and test infrastructure.

pub mod alpha_test;
pub mod debug_types;
pub mod fragment;
pub mod hex_parser;
pub mod hiz;
pub mod math;
pub mod reg_ext;
pub mod texel;
pub mod triangle;
