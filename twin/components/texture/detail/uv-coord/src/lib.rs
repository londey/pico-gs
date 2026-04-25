#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]

//! Texture UV coordinate processing -- wrap modes and texel addressing.
//!
//! Converts Q4.12 signed UV coordinates to integer texel positions with
//! wrap-mode application, then resolves the texel into a block-tiled
//! address (block index plus 2-bit sub-texel position) for the
//! NEAREST-filtered texture sampling pipeline.
//!
//! This crate corresponds to `texture_uv_coord.sv` in the RTL and
//! implements UNIT-011.01.
//!
//! # Data flow
//!
//! ```text
//! UV (Q4.12) + config
//!   -> wrap mode application -> wrapped integer texel coordinates
//!   -> block-tiled tap (block_x, block_y, block_index, local)
//! ```

use gpu_registers::components::wrap_mode_e::WrapModeE;
use qfixed::Q;

// -- BilinearTap --------------------------------------------------------------

/// Address of a single texel within the block-tiled texture layout.
///
/// Despite the historical name, this struct describes a single texel
/// (the tap returned by NEAREST sampling). The pico-gs pipeline does
/// not implement bilinear filtering; the type name is retained because
/// it remains a well-suited descriptor for a single-texel address.
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

// -- Nearest tap computation --------------------------------------------------

/// Compute a nearest-mode tap from Q4.12 UVs (single texel, no bilinear offset).
///
/// Returns the wrapped texel coordinates and the corresponding block tap.
///
/// # Arguments
///
/// * `u`, `v` -- Q4.12 signed texture coordinates.
/// * `width`, `height` -- Texture dimensions (power-of-two).
/// * `w_log2`, `h_log2` -- Log2 of texture dimensions.
/// * `u_wrap`, `v_wrap` -- Wrap modes for each axis.
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
