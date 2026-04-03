#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]
#![allow(dead_code)]
#![allow(unused_crate_dependencies)]

//! Texture filtering — sample gathering, bilinear blending, and wrap modes.
//!
//! This module contains the blending logic for texture sampling.
//! UV coordinate processing (wrap modes, bilinear tap computation) is
//! delegated to [`gs_tex_uv_coord`].
//! The [`SampleGatherer`] trait computes tap coordinates and fetches texels;
//! the [`BilinearBlender`] trait blends them into a single output texel.
//!
//! # Data flow
//!
//! ```text
//! UV (Q4.12) + config
//!   → SampleGatherer::gather() → GatheredSample {texels, weights}
//!   → BilinearBlender::blend() → TexelUq18
//! ```

use gpu_registers::components::gpu_regs::named_types::tex_cfg_reg::TexCfgReg;
use gpu_registers::components::tex_filter_e::TexFilterE;
use qfixed::{Q, UQ};

use gs_tex_block_decoder::tex_fetch::BlockFetcher;
use gs_tex_uv_coord::{compute_bilinear_taps, compute_nearest_tap};
use gs_twin_core::texel::TexelUq18;

// ── GatheredSample ──────────────────────────────────────────────────────────

/// Result of sample gathering: four texels and their blending weights.
///
/// For nearest filtering, only `texels[0]` is meaningful and
/// `weights[0]` is 1.0 (0x100).
///
/// For bilinear filtering, all four texels and weights are used.
/// Tap order: `[00, 10, 01, 11]` where the first index is U (x)
/// and the second is V (y).
/// Weights are UQ1.8 values summing to exactly 0x100 (1.0).
#[derive(Debug, Clone, Copy)]
pub struct GatheredSample {
    /// Four texels at the tap positions.
    pub texels: [TexelUq18; 4],

    /// Per-tap blending weights, UQ1.8 UNORM.
    pub weights: [UQ<1, 8>; 4],

    /// Filter mode that produced this sample.
    pub mode: TexFilterE,
}

// -- SampleGatherer trait ---------------------------------------------------------

/// Compute tap coordinates from UV + config, fetch texels via the block fetcher.
pub trait SampleGatherer {
    /// Gather texels for one filtered sample.
    ///
    /// # Arguments
    ///
    /// * `fetcher` - Block fetcher for cache lookup + decode.
    /// * `u`, `v` - Texture coordinates, Q4.12 signed.
    /// * `cfg` - Texture configuration (dimensions, format, wrap modes, filter).
    /// * `sdram` - SDRAM backing store.
    fn gather(
        &self,
        fetcher: &mut dyn BlockFetcher,
        u: Q<4, 12>,
        v: Q<4, 12>,
        cfg: &TexCfgReg,
        sdram: &[u16],
    ) -> GatheredSample;
}

// -- BilinearBlender trait --------------------------------------------------------

/// Blend gathered texels into a single output texel.
pub trait BilinearBlender {
    /// Blend the texels in a [`GatheredSample`] into one [`TexelUq18`].
    fn blend(&self, sample: &GatheredSample) -> TexelUq18;
}

// -- Concrete SampleGatherer ------------------------------------------------------

/// Standard sample gatherer supporting nearest and bilinear filtering.
pub struct StandardGatherer;

impl SampleGatherer for StandardGatherer {
    fn gather(
        &self,
        fetcher: &mut dyn BlockFetcher,
        u: Q<4, 12>,
        v: Q<4, 12>,
        cfg: &TexCfgReg,
        sdram: &[u16],
    ) -> GatheredSample {
        let w_log2 = cfg.width_log2();
        let h_log2 = cfg.height_log2();
        let width = 1u32 << w_log2;
        let height = 1u32 << h_log2;
        let base_words = cfg.base_addr() as u32 * 256;
        let format = cfg
            .format()
            .unwrap_or(gpu_registers::components::tex_format_e::TexFormatE::Rgb565);
        let filter = cfg.filter().unwrap_or(TexFilterE::Nearest);

        match filter {
            TexFilterE::Nearest => {
                let tap = compute_nearest_tap(
                    u,
                    v,
                    width,
                    height,
                    w_log2,
                    h_log2,
                    cfg.u_wrap(),
                    cfg.v_wrap(),
                );

                let block = fetcher.get_block(
                    base_words,
                    tap.block_x,
                    tap.block_y,
                    tap.block_index,
                    format,
                    sdram,
                );
                let texel = block[tap.local as usize];

                GatheredSample {
                    texels: [
                        texel,
                        TexelUq18::default(),
                        TexelUq18::default(),
                        TexelUq18::default(),
                    ],
                    weights: [
                        UQ::from_bits(0x100),
                        UQ::from_bits(0),
                        UQ::from_bits(0),
                        UQ::from_bits(0),
                    ],
                    mode: TexFilterE::Nearest,
                }
            }
            TexFilterE::Bilinear | TexFilterE::Trilinear => {
                let result = compute_bilinear_taps(
                    u,
                    v,
                    width,
                    height,
                    w_log2,
                    h_log2,
                    cfg.u_wrap(),
                    cfg.v_wrap(),
                );

                let texels = result.taps.map(|tap| {
                    let block = fetcher.get_block(
                        base_words,
                        tap.block_x,
                        tap.block_y,
                        tap.block_index,
                        format,
                        sdram,
                    );
                    block[tap.local as usize]
                });

                GatheredSample {
                    texels,
                    weights: result.weights,
                    mode: filter,
                }
            }
        }
    }
}

// ── Concrete BilinearBlender ────────────────────────────────────────────────

/// Standard bilinear blender using UQ1.8 × UQ1.8 multiply-accumulate.
///
/// Matches the RTL's 9×9 DSP sub-mode: four UQ2.16 partial products
/// accumulated and truncated to UQ1.8.
pub struct StandardBlender;

impl BilinearBlender for StandardBlender {
    fn blend(&self, sample: &GatheredSample) -> TexelUq18 {
        match sample.mode {
            TexFilterE::Nearest => sample.texels[0],
            TexFilterE::Bilinear | TexFilterE::Trilinear => {
                bilinear_blend(&sample.texels, &sample.weights)
            }
        }
    }
}

/// Blend four UQ1.8 texels using bilinear weights.
///
/// Per channel: `result = Σ(texel[i] × weight[i])` for i in 0..4.
pub fn bilinear_blend(texels: &[TexelUq18; 4], weights: &[UQ<1, 8>; 4]) -> TexelUq18 {
    let blend = |c0: UQ<1, 8>, c1: UQ<1, 8>, c2: UQ<1, 8>, c3: UQ<1, 8>| -> UQ<1, 8> {
        let acc = c0.to_bits() as u32 * weights[0].to_bits() as u32
            + c1.to_bits() as u32 * weights[1].to_bits() as u32
            + c2.to_bits() as u32 * weights[2].to_bits() as u32
            + c3.to_bits() as u32 * weights[3].to_bits() as u32;
        UQ::from_bits((acc >> 8) as u64)
    };

    TexelUq18 {
        r: blend(texels[0].r, texels[1].r, texels[2].r, texels[3].r),
        g: blend(texels[0].g, texels[1].g, texels[2].g, texels[3].g),
        b: blend(texels[0].b, texels[1].b, texels[2].b, texels[3].b),
        a: blend(texels[0].a, texels[1].a, texels[2].a, texels[3].a),
    }
}
