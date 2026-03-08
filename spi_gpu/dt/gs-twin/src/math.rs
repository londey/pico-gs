//! Fixed-point arithmetic and linear algebra matching the RTL bit-for-bit.
//!
//! Every numeric type in this module corresponds to a specific wire format
//! in the pico-gs RTL. The type aliases encode the Q format (TI convention:
//! Qm.n = m integer bits including sign + n fractional bits, total = m+n bits).
//!
//! # RTL Numeric Contract
//!
//! The twin and RTL must agree on:
//!   - Q format (bit width + radix point) for each pipeline stage
//!   - Rounding mode after multiplication (truncate toward zero)
//!   - Overflow behavior (saturate, not wrap)
//!   - Intermediate precision for multiply-accumulate chains
//!
//! If you change a Q format here, the corresponding RTL module must change
//! to match, and vice versa.
//!
//! # Fixed-Point Multiplication Convention
//!
//! When the RTL multiplies two Q16.16 values in a MULT18X18D, the raw
//! product is 36 bits (Q18.18 from the 18×18 multiplier, though only 32
//! of the input bits are significant). We model this by widening to
//! [`MulAccum`] for intermediate results, then truncating back to the
//! target format. The truncation discards low fractional bits (toward
//! zero), matching Verilog's default behavior for sized assignments.

use fixed::types::{I12F4, I16F16, I2F14, I4F12, U0F16, U1F7};
use serde::{Deserialize, Serialize};

// ═══════════════════════════════════════════════════════════════════════════
//  Scalar Q-format aliases — one per pipeline wire format
// ═══════════════════════════════════════════════════════════════════════════

/// **Vertex / clip-space coordinate: Q16.16 (32-bit signed)**
///
/// Used for: object-space positions, MVP matrix elements, clip-space
/// coordinates. Range ±32767.9999... with ~15µ resolution.
///
/// # RTL Implementation Notes
/// Matrix elements are loaded as 32-bit register writes. The vertex
/// transform MAC chain uses MULT18X18D with the full 32-bit operand
/// split across two 18-bit multiplier inputs.
pub type Coord = I16F16;

/// **Multiply-accumulate intermediate: Q16.16 (same width, used for clarity)**
///
/// In the RTL, the MULT18X18D produces a 36-bit result. We keep the
/// same Q16.16 format but document that intermediate additions may
/// use wider accumulators internally. If the RTL widens to 48 bits
/// for the accumulator, update this alias.
///
/// TODO: If your RTL uses a wider accumulator (e.g. ALU54B cascade),
/// change this to I24F24 or similar and adjust truncation points.
pub type MulAccum = I16F16;

/// **Screen-space coordinate: Q12.4 (16-bit signed)**
///
/// After viewport transform. Integer part covers pixel coordinates
/// (up to 2048 pixels), fractional part provides 4 bits of sub-pixel
/// precision for edge function evaluation (1/16th pixel).
///
/// # RTL Implementation Notes
/// The viewport transform outputs 16-bit values. The rasterizer's
/// edge function evaluator operates on these directly.
pub type ScreenCoord = I12F4;

/// **Depth / Z-buffer: Q4.12 (16-bit signed)**
///
/// Post-viewport depth value stored in the Z-buffer SRAM. Range [0, ~8)
/// with 12 bits of fractional precision. The depth buffer comparison
/// operates on these raw 16-bit values.
///
/// # RTL Implementation Notes
/// Z-buffer is a 16-bit-wide SRAM region. Depth comparison is a
/// simple 16-bit signed comparison in the fragment stage.
pub type Depth = I4F12;

/// **Barycentric / edge function accumulator: Q16.16 (32-bit signed)**
///
/// Edge functions produce products of two Q12.4 screen coordinates,
/// yielding Q24.8 raw products. We accumulate in Q16.16 for headroom.
///
/// # RTL Implementation Notes
/// Edge function evaluation uses MULT18X18D for the cross products.
/// The 36-bit result is truncated to 32 bits (Q16.16) for the
/// inside/outside test and barycentric normalization.
pub type EdgeAccum = I16F16;

/// **Texture coordinate: Q2.14 (16-bit signed)**
///
/// UV coordinates in [0, 1) with 14 bits of fractional precision.
/// Two integer bits allow for slight overshoot during interpolation
/// before wrapping.
///
/// # RTL Implementation Notes
/// Texture coordinates are interpolated in the rasterizer using the
/// same MULT18X18D + accumulate path as barycentrics. Wrapping to
/// [0, 1) is a simple bitmask on the fractional part.
pub type TexCoord = I2F14;

/// **Reciprocal W: Q0.16 (16-bit unsigned)**
///
/// 1/w for perspective-correct interpolation. Unsigned because w is
/// always positive after clipping. Full 16-bit fractional precision.
///
/// # RTL Implementation Notes
/// 1/w is computed by the host (RP2350) or via a lookup table +
/// Newton-Raphson iteration in the clip stage. The RTL receives
/// this as a pre-computed 16-bit value per vertex.
pub type WRecip = U0F16;

/// **Color channel: Q1.7 (8-bit unsigned)**
///
/// Per-channel intensity for vertex color interpolation. Range [0, ~1.99]
/// with 7 bits of fractional precision. The extra integer bit provides
/// headroom for interpolation overshoot before clamping to [0, 1).
///
/// # RTL Implementation Notes
/// Vertex colors arrive as RGB565. For interpolation, each channel is
/// expanded: R5→Q1.7 (shift left 2), G6→Q1.7 (shift left 1),
/// B5→Q1.7 (shift left 2). After interpolation, truncate back to 5/6/5.
pub type ColorChannel = U1F7;

// ═══════════════════════════════════════════════════════════════════════════
//  Truncation helpers — model RTL's sized assignment behavior
// ═══════════════════════════════════════════════════════════════════════════

/// Truncate a wide fixed-point value to a narrower format.
///
/// This models Verilog's behavior when assigning a wider wire to a
/// narrower register: low fractional bits are discarded (truncation
/// toward zero), and high integer bits are silently lost (wrapping).
///
/// Use [`saturating_narrow`] when the RTL uses explicit saturation.
///
/// # RTL Implementation Notes
/// Default Verilog assignment truncates. If a module uses explicit
/// saturation logic, use [`saturating_narrow`] instead.
pub fn truncating_narrow<Src, Dst>(src: Src) -> Dst
where
    Src: fixed::traits::Fixed,
    Dst: fixed::traits::Fixed + fixed::traits::FromFixed,
{
    Dst::wrapping_from_fixed(src)
}

/// Narrow with saturation (clamp to destination range).
///
/// Use when the RTL explicitly saturates (e.g. depth clamped to [0, max]).
pub fn saturating_narrow<Src, Dst>(src: Src) -> Dst
where
    Src: fixed::traits::Fixed,
    Dst: fixed::traits::Fixed + fixed::traits::FromFixed,
{
    Dst::saturating_from_fixed(src)
}

// ═══════════════════════════════════════════════════════════════════════════
//  Vector / matrix types — fixed-point throughout
// ═══════════════════════════════════════════════════════════════════════════

/// 4-component vector in clip/model space (homogeneous coordinates).
/// All components are [`Coord`] (Q16.16).
#[derive(Debug, Clone, Copy, Default)]
pub struct Vec4 {
    pub x: Coord,
    pub y: Coord,
    pub z: Coord,
    pub w: Coord,
}

/// 3-component vector (object-space positions).
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct Vec3 {
    pub x: Coord,
    pub y: Coord,
    pub z: Coord,
}

/// 2-component texture coordinate vector.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct TexVec2 {
    pub u: TexCoord,
    pub v: TexCoord,
}

/// 3-component barycentric coordinate (for debug / analysis).
#[derive(Debug, Clone, Copy, Default)]
pub struct Bary3 {
    pub w0: EdgeAccum,
    pub w1: EdgeAccum,
    pub w2: EdgeAccum,
}

/// 4×4 matrix in column-major order, Q16.16 elements.
///
/// # RTL Implementation Notes
/// The host pre-computes the MVP matrix in floating point on the
/// RP2350's FPU, then quantizes each element to Q16.16 before
/// writing to the GPU's matrix register bank (16 consecutive
/// 32-bit register writes).
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Mat4 {
    /// Column-major storage: `cols[col][row]`.
    /// Stored as raw i32 bits of Q16.16 values for serde compatibility.
    pub cols: [[i32; 4]; 4],
}

impl Default for Mat4 {
    fn default() -> Self {
        Self::identity()
    }
}

impl Mat4 {
    /// Identity matrix in Q16.16.
    pub fn identity() -> Self {
        let one = Coord::ONE.to_bits();
        let zero = 0i32;
        Self {
            cols: [
                [one, zero, zero, zero],
                [zero, one, zero, zero],
                [zero, zero, one, zero],
                [zero, zero, zero, one],
            ],
        }
    }

    /// Construct from f32 values (for test convenience).
    /// Quantizes each element to Q16.16 (truncating, matching host behavior).
    pub fn from_f32(cols: [[f32; 4]; 4]) -> Self {
        let mut out = [[0i32; 4]; 4];
        for c in 0..4 {
            for r in 0..4 {
                out[c][r] = Coord::from_num(cols[c][r]).to_bits();
            }
        }
        Self { cols: out }
    }

    /// Read an element as a [`Coord`].
    #[inline]
    fn elem(&self, col: usize, row: usize) -> Coord {
        Coord::from_bits(self.cols[col][row])
    }

    /// Matrix × Vec4 multiply.
    ///
    /// Each output component is a 4-element dot product. In the RTL this
    /// is a 4-stage multiply-accumulate chain using MULT18X18D slices.
    ///
    /// # Numeric Behavior
    /// Each multiply produces a Q16.16 result (truncated from the
    /// MULT18X18D's 36-bit output). Accumulation uses wrapping addition
    /// at Q16.16 width.
    pub fn transform(&self, v: Vec4) -> Vec4 {
        Vec4 {
            x: self.dot_row(0, v),
            y: self.dot_row(1, v),
            z: self.dot_row(2, v),
            w: self.dot_row(3, v),
        }
    }

    /// Compute one row of the matrix-vector product.
    fn dot_row(&self, row: usize, v: Vec4) -> Coord {
        let a = self.elem(0, row).wrapping_mul(v.x);
        let b = self.elem(1, row).wrapping_mul(v.y);
        let c = self.elem(2, row).wrapping_mul(v.z);
        let d = self.elem(3, row).wrapping_mul(v.w);
        a.wrapping_add(b).wrapping_add(c).wrapping_add(d)
    }

    /// Matrix × Matrix multiply.
    pub fn mul(&self, rhs: &Mat4) -> Mat4 {
        let mut out = [[0i32; 4]; 4];
        for (c, out_col) in out.iter_mut().enumerate() {
            let rhs_col = Vec4 {
                x: rhs.elem(c, 0),
                y: rhs.elem(c, 1),
                z: rhs.elem(c, 2),
                w: rhs.elem(c, 3),
            };
            let result = self.transform(rhs_col);
            out_col[0] = result.x.to_bits();
            out_col[1] = result.y.to_bits();
            out_col[2] = result.z.to_bits();
            out_col[3] = result.w.to_bits();
        }
        Mat4 { cols: out }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Color types
// ═══════════════════════════════════════════════════════════════════════════

/// RGB565 packed pixel, matching the framebuffer SRAM format.
///
/// Bit layout: `RRRRR_GGGGGG_BBBBB` (MSB first).
///
/// # RTL Implementation Notes
/// This is the native pixel format written to/read from the framebuffer
/// SRAM. The SRAM data bus is 16 bits wide, so one pixel per access.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rgb565(pub u16);

impl Rgb565 {
    /// Pack from 8-bit channels.
    ///
    /// Truncates (right-shifts) to 5-6-5 bits. This matches the RTL's
    /// behavior: no rounding, just discard low bits.
    pub fn from_rgb8(r: u8, g: u8, b: u8) -> Self {
        let r5 = (r >> 3) as u16;
        let g6 = (g >> 2) as u16;
        let b5 = (b >> 3) as u16;
        Self((r5 << 11) | (g6 << 5) | b5)
    }

    /// Unpack to 8-bit channels with bit replication for full range.
    pub fn to_rgb8(self) -> (u8, u8, u8) {
        let r5 = (self.0 >> 11) & 0x1F;
        let g6 = (self.0 >> 5) & 0x3F;
        let b5 = self.0 & 0x1F;
        (
            ((r5 << 3) | (r5 >> 2)) as u8,
            ((g6 << 2) | (g6 >> 4)) as u8,
            ((b5 << 3) | (b5 >> 2)) as u8,
        )
    }

    /// Expand to per-channel [`ColorChannel`] (Q1.7) for interpolation.
    ///
    /// # RTL Implementation Notes
    /// R5 is shifted left by 2 to fill Q1.7 (bits [6:2], low 2 bits zero).
    /// G6 is shifted left by 1 (bits [6:1], low 1 bit zero).
    /// B5 is shifted left by 2 (same as R).
    pub fn to_channels(self) -> (ColorChannel, ColorChannel, ColorChannel) {
        let r5 = ((self.0 >> 11) & 0x1F) as u8;
        let g6 = ((self.0 >> 5) & 0x3F) as u8;
        let b5 = (self.0 & 0x1F) as u8;
        (
            ColorChannel::from_bits(r5 << 2),
            ColorChannel::from_bits(g6 << 1),
            ColorChannel::from_bits(b5 << 2),
        )
    }

    /// Pack from [`ColorChannel`] (Q1.7) back to RGB565.
    ///
    /// Truncates each channel: R takes bits [6:2], G takes [6:1], B takes [6:2].
    pub fn from_channels(r: ColorChannel, g: ColorChannel, b: ColorChannel) -> Self {
        let r5 = (r.to_bits() >> 2) as u16;
        let g6 = (g.to_bits() >> 1) as u16;
        let b5 = (b.to_bits() >> 2) as u16;
        Self((r5 << 11) | (g6 << 5) | b5)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Convenience constructors for tests
// ═══════════════════════════════════════════════════════════════════════════

impl Vec4 {
    /// Construct from f32 values (quantizes to Q16.16).
    pub fn from_f32(x: f32, y: f32, z: f32, w: f32) -> Self {
        Self {
            x: Coord::from_num(x),
            y: Coord::from_num(y),
            z: Coord::from_num(z),
            w: Coord::from_num(w),
        }
    }
}

impl Vec3 {
    /// Construct from f32 values (quantizes to Q16.16).
    pub fn from_f32(x: f32, y: f32, z: f32) -> Self {
        Self {
            x: Coord::from_num(x),
            y: Coord::from_num(y),
            z: Coord::from_num(z),
        }
    }
}

impl TexVec2 {
    /// Construct from f32 values (quantizes to Q2.14).
    pub fn from_f32(u: f32, v: f32) -> Self {
        Self {
            u: TexCoord::from_num(u),
            v: TexCoord::from_num(v),
        }
    }
}
