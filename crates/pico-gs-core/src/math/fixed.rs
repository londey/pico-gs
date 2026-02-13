//! Fixed-point conversion helpers for GPU register formats.
//!
//! Converts f32 values to the GPU's fixed-point register formats:
//! - 12.4 signed fixed-point for vertex X/Y screen coordinates
//! - 1.15 signed fixed-point for perspective-correct UV/Q texture coordinates
//! - 25-bit unsigned integer for Z depth values

/// Convert f32 to 12.4 signed fixed-point.
///
/// Range: -2048.0 to +2047.9375 (1/16 pixel resolution).
/// The result is a 16-bit signed value.
pub fn f32_to_12_4(val: f32) -> u16 {
    let clamped = val.clamp(-2048.0, 2047.9375);
    let scaled = (clamped * 16.0) as i16;
    scaled as u16
}

/// Convert f32 to 1.15 signed fixed-point.
///
/// Range: -1.0 to +0.99997 (resolution 1/32768).
/// The result is a 16-bit signed value.
pub fn f32_to_1_15(val: f32) -> u16 {
    let clamped = val.clamp(-1.0, 0.99997);
    let scaled = (clamped * 32768.0) as i16;
    scaled as u16
}

/// Convert f32 depth (0.0 = near, 1.0 = far) to 25-bit unsigned Z.
///
/// Range: 0 to 0x1FFFFFF.
pub fn f32_to_z25(val: f32) -> u32 {
    let clamped = val.clamp(0.0, 1.0);
    let scaled = (clamped * 0x1FF_FFFF as f32) as u32;
    scaled.min(0x1FF_FFFF)
}

/// Pack RGBA bytes into a u32 (ABGR format matching GPU COLOR register).
pub fn rgba_to_packed(r: u8, g: u8, b: u8, a: u8) -> u32 {
    ((a as u32) << 24) | ((b as u32) << 16) | ((g as u32) << 8) | (r as u32)
}
