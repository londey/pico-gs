//! Debug data types shared between the rasterizer and debug tracing.

/// Rasterizer accumulator debug state — captured per-pixel when debug
/// tracing is enabled.
///
/// This is a pure data type with no dependencies on pipeline logic.
/// It is defined in gs-twin-core so that both the rasterizer crate
/// (which populates it) and the debug_pixel module (which prints it)
/// can reference it without circular dependencies.
#[derive(Debug, Clone, Default)]
pub struct RasterAccumulatorDebug {
    /// All 14 attribute accumulators (32-bit signed each).
    pub acc: [i32; 14],

    /// Top 16 bits of Q accumulator (input to `recip_q`).
    pub q_top: u16,

    /// UQ7.10 reciprocal of Q from `recip_q`.
    pub inv_q: u32,

    /// Top 16 bits of S0 accumulator (signed, before perspective correction).
    pub s0_top: i16,

    /// Top 16 bits of T0 accumulator.
    pub t0_top: i16,

    /// Top 16 bits of S1 accumulator.
    pub s1_top: i16,

    /// Top 16 bits of T1 accumulator.
    pub t1_top: i16,

    /// Full signed product `s0_top * inv_q` (before bit extraction).
    pub s0_product: i64,

    /// Full signed product `t0_top * inv_q`.
    pub t0_product: i64,

    /// Full signed product `s1_top * inv_q`.
    pub s1_product: i64,

    /// Full signed product `t1_top * inv_q`.
    pub t1_product: i64,

    /// CLZ count of the Q input to `recip_q`.
    pub recip_clz: u8,

    /// 10-bit LUT index used by `recip_q`.
    pub recip_lut_index: u16,

    /// Error of the computed 1/Q in UQ7.10 LSBs (positive = too small).
    pub recip_error_lsb: i32,
}
