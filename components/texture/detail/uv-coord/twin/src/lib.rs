#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]

//! Texture UV coordinate processing -- wrap modes, texel addressing, and
//! bilinear tap computation.
//!
//! Converts Q4.12 signed UV coordinates to integer texel positions with
//! wrap-mode application, and computes bilinear tap positions with
//! fractional weights for bilinear filtering.
//!
//! This crate corresponds to `texture_uv_coord.sv` in the RTL.
//!
//! # Data flow
//!
//! ```text
//! UV (Q4.12) + config
//!   -> texel-space fixed-point -> tap computation
//!   -> wrap mode application -> wrapped tap coordinates + fractional weights
//! ```

use gpu_registers::components::wrap_mode_e::WrapModeE;
use qfixed::{Q, UQ};

// -- BilinearTap --------------------------------------------------------------

/// Address of a single texel within the block-tiled texture layout.
#[derive(Debug, Clone, Copy)]
pub struct BilinearTap {
    /// Block X coordinate (texel X / 4).
    pub block_x: u32,

    /// Block Y coordinate (texel Y / 4).
    pub block_y: u32,

    /// Block index within the mip level (row-major block grid).
    pub block_index: u32,

    /// Row-major offset within the 4x4 block: `(ty & 3) * 4 + (tx & 3)`.
    pub local: u32,
}

impl BilinearTap {
    /// Build a tap from wrapped texel coordinates and the texture's
    /// block-row width.
    fn from_texel(tx: u32, ty: u32, blocks_per_row: u32) -> Self {
        let bx = tx / 4;
        let by = ty / 4;
        Self {
            block_x: bx,
            block_y: by,
            block_index: by * blocks_per_row + bx,
            local: (ty & 3) * 4 + (tx & 3),
        }
    }
}

// -- Wrap-mode helpers --------------------------------------------------------

/// Convert a Q4.12 UV coordinate to an integer texel index, applying
/// the specified wrap mode.
pub fn wrap_texel(coord: Q<4, 12>, dim: u32, dim_log2: u8, wrap: WrapModeE) -> u32 {
    let bits = coord.to_bits() as u16 as i16 as i64;
    let texel_raw: i64 = if dim_log2 <= 12 {
        bits >> (12 - dim_log2)
    } else {
        bits << (dim_log2 - 12)
    };

    wrap_axis(texel_raw, dim as i64, wrap)
}

/// Apply a single-axis wrap mode to a raw (pre-wrap) texel index.
pub fn wrap_axis(texel_raw: i64, dim: i64, wrap: WrapModeE) -> u32 {
    match wrap {
        WrapModeE::Repeat => texel_raw.rem_euclid(dim) as u32,
        WrapModeE::ClampToEdge => texel_raw.clamp(0, dim - 1) as u32,
        WrapModeE::Mirror => {
            let period = dim * 2;
            let t = texel_raw.rem_euclid(period);
            if t < dim {
                t as u32
            } else {
                (period - 1 - t) as u32
            }
        }
        WrapModeE::Octahedral => texel_raw.rem_euclid(dim) as u32,
    }
}

// -- Bilinear tap computation -------------------------------------------------

/// Result of bilinear tap computation: four tap positions and their weights.
#[derive(Debug, Clone, Copy)]
pub struct BilinearTaps {
    /// Four taps: `[00, 10, 01, 11]` where first index is U, second is V.
    pub taps: [BilinearTap; 4],

    /// Per-tap fractional U weight, UQ0.8.
    pub frac_u: u8,

    /// Per-tap fractional V weight, UQ0.8.
    pub frac_v: u8,

    /// Per-tap blending weights, UQ1.8 values summing to exactly 0x100.
    pub weights: [UQ<1, 8>; 4],
}

/// Compute four bilinear taps and their UQ1.8 weights from Q4.12 UVs.
///
/// # Arguments
///
/// * `u`, `v` -- Q4.12 signed texture coordinates.
/// * `width`, `height` -- Texture dimensions (power-of-two).
/// * `w_log2`, `h_log2` -- Log2 of texture dimensions.
/// * `u_wrap`, `v_wrap` -- Wrap modes for each axis.
#[allow(clippy::too_many_arguments)]
pub fn compute_bilinear_taps(
    u: Q<4, 12>,
    v: Q<4, 12>,
    width: u32,
    height: u32,
    w_log2: u8,
    h_log2: u8,
    u_wrap: WrapModeE,
    v_wrap: WrapModeE,
) -> BilinearTaps {
    let u_bits = u.to_bits() as u16 as i16 as i64;
    let v_bits = v.to_bits() as u16 as i16 as i64;

    let u_fixed = if w_log2 <= 4 {
        u_bits >> (4 - w_log2)
    } else {
        u_bits << (w_log2 - 4)
    };
    let v_fixed = if h_log2 <= 4 {
        v_bits >> (4 - h_log2)
    } else {
        v_bits << (h_log2 - 4)
    };

    let u_offset = u_fixed - 0x80;
    let v_offset = v_fixed - 0x80;

    let tx0 = u_offset >> 8;
    let ty0 = v_offset >> 8;
    let tx1 = tx0 + 1;
    let ty1 = ty0 + 1;

    let fu = (u_offset.rem_euclid(256)) as u8;
    let fv = (v_offset.rem_euclid(256)) as u8;

    let dim_w = width as i64;
    let dim_h = height as i64;
    let blocks_per_row = width.div_ceil(4);

    // Wrap each unique coordinate once, then combine into 4 taps.
    let wx0 = wrap_axis(tx0, dim_w, u_wrap);
    let wx1 = wrap_axis(tx1, dim_w, u_wrap);
    let wy0 = wrap_axis(ty0, dim_h, v_wrap);
    let wy1 = wrap_axis(ty1, dim_h, v_wrap);

    let taps = [
        BilinearTap::from_texel(wx0, wy0, blocks_per_row),
        BilinearTap::from_texel(wx1, wy0, blocks_per_row),
        BilinearTap::from_texel(wx0, wy1, blocks_per_row),
        BilinearTap::from_texel(wx1, wy1, blocks_per_row),
    ];

    let one = 0x100u16;
    let fu16 = fu as u16;
    let fv16 = fv as u16;
    let ifu = one - fu16;
    let ifv = one - fv16;

    let raw_weights = [
        (ifu as u32 * ifv as u32) >> 8,
        (fu16 as u32 * ifv as u32) >> 8,
        (ifu as u32 * fv16 as u32) >> 8,
        (fu16 as u32 * fv16 as u32) >> 8,
    ];

    let weights = raw_weights.map(|w| UQ::<1, 8>::from_bits(w as u64));

    BilinearTaps {
        taps,
        frac_u: fu,
        frac_v: fv,
        weights,
    }
}

/// Compute a nearest-mode tap from Q4.12 UVs (single texel, no bilinear offset).
///
/// Returns the wrapped texel coordinates and the corresponding block tap.
#[allow(clippy::too_many_arguments)]
pub fn compute_nearest_tap(
    u: Q<4, 12>,
    v: Q<4, 12>,
    width: u32,
    height: u32,
    w_log2: u8,
    h_log2: u8,
    u_wrap: WrapModeE,
    v_wrap: WrapModeE,
) -> BilinearTap {
    let tx = wrap_texel(u, width, w_log2, u_wrap);
    let ty = wrap_texel(v, height, h_log2, v_wrap);
    BilinearTap::from_texel(tx, ty, width.div_ceil(4))
}
