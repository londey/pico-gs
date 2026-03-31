//! DSP and shift-add multiply helpers matching RTL arithmetic modules.
//!
//! These functions replicate the exact bit behavior of the RTL helper
//! modules used by the rasterizer derivative and setup pipeline.

// Spec-ref: unit_005.03_derivative_precomputation.md `0000000000000000` 1970-01-01

/// DSP multiply matching `raster_dsp_mul.sv`: signed 17-bit × unsigned 18-bit.
///
/// Computes `|a| * b`, restores sign.
/// Result is 36-bit signed (as `i64`).
///
/// # Arguments
///
/// * `a` - Signed 17-bit delta (sign-extended from attribute difference).
/// * `b` - Unsigned 18-bit inverse area mantissa (UQ1.17).
///
/// # Returns
///
/// Signed 36-bit product.
pub fn dsp_mul(a: i32, b: u32) -> i64 {
    // Sign-extend a to 18-bit signed, take absolute value
    let a_ext = ((a as i64) << 46) >> 46; // sign-extend to effective 18-bit
    let a_mag = a_ext.unsigned_abs();

    // 18 × 18 unsigned multiply
    let prod = a_mag * (b as u64);

    // Restore sign
    if a < 0 {
        -(prod as i64)
    } else {
        prod as i64
    }
}

/// Shift-add multiply matching `raster_shift_mul_32x11.sv`.
///
/// 32-bit signed × 11-bit signed → 32-bit signed (truncated).
///
/// # Arguments
///
/// * `a` - 32-bit signed operand (derivative or attribute value).
/// * `b` - 11-bit signed operand (bbox offset or edge coefficient).
///
/// # Returns
///
/// Truncated 32-bit signed product.
pub fn shift_mul_32x11(a: i32, b: i32) -> i32 {
    // In the DT we can just multiply and truncate to 32-bit
    let result = (a as i64) * (b as i64);
    result as i32
}
