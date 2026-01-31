//! Unit tests for fixed-point conversions and GPU register packing.
//!
//! These run on the host via `cargo test` (not on target hardware).

// These tests use the math module directly, compiled for host.
// Since the firmware crate is no_std, we test the conversion logic in isolation.

/// 12.4 signed fixed-point conversion.
mod f32_to_12_4 {
    // Re-implement the conversion for host testing (avoids pulling in no_std crate).
    fn f32_to_12_4(val: f32) -> u16 {
        let clamped = val.clamp(-2048.0, 2047.9375);
        let scaled = (clamped * 16.0) as i16;
        scaled as u16
    }

    #[test]
    fn zero() {
        assert_eq!(f32_to_12_4(0.0), 0);
    }

    #[test]
    fn positive_integer() {
        // 100.0 * 16 = 1600
        assert_eq!(f32_to_12_4(100.0), 1600);
    }

    #[test]
    fn negative_integer() {
        // -100.0 * 16 = -1600; as u16 wraps to 63936
        let result = f32_to_12_4(-100.0);
        let signed = result as i16;
        assert_eq!(signed, -1600);
    }

    #[test]
    fn fractional_quarter_pixel() {
        // 10.25 * 16 = 164
        assert_eq!(f32_to_12_4(10.25), 164);
    }

    #[test]
    fn max_positive() {
        // 2047.9375 * 16 = 32767 (i16::MAX)
        let result = f32_to_12_4(2047.9375);
        assert_eq!(result as i16, 32767);
    }

    #[test]
    fn min_negative() {
        // -2048.0 * 16 = -32768 (i16::MIN)
        let result = f32_to_12_4(-2048.0);
        assert_eq!(result as i16, -32768);
    }

    #[test]
    fn clamps_above_max() {
        let result = f32_to_12_4(3000.0);
        assert_eq!(result as i16, 32767);
    }

    #[test]
    fn clamps_below_min() {
        let result = f32_to_12_4(-3000.0);
        assert_eq!(result as i16, -32768);
    }

    #[test]
    fn sub_pixel_resolution() {
        // 0.0625 (1/16) is the smallest representable fraction.
        assert_eq!(f32_to_12_4(0.0625), 1);
    }
}

/// 1.15 signed fixed-point conversion.
mod f32_to_1_15 {
    fn f32_to_1_15(val: f32) -> u16 {
        let clamped = val.clamp(-1.0, 0.99997);
        let scaled = (clamped * 32768.0) as i16;
        scaled as u16
    }

    #[test]
    fn zero() {
        assert_eq!(f32_to_1_15(0.0), 0);
    }

    #[test]
    fn positive_half() {
        // 0.5 * 32768 = 16384
        assert_eq!(f32_to_1_15(0.5), 16384);
    }

    #[test]
    fn negative_half() {
        let result = f32_to_1_15(-0.5);
        assert_eq!(result as i16, -16384);
    }

    #[test]
    fn max_positive() {
        // 0.99997 * 32768 ≈ 32767
        let result = f32_to_1_15(0.99997);
        assert_eq!(result as i16, 32767);
    }

    #[test]
    fn min_negative() {
        // -1.0 * 32768 = -32768
        let result = f32_to_1_15(-1.0);
        assert_eq!(result as i16, -32768);
    }

    #[test]
    fn clamps_above_max() {
        let result = f32_to_1_15(2.0);
        assert_eq!(result as i16, 32767);
    }

    #[test]
    fn clamps_below_min() {
        let result = f32_to_1_15(-2.0);
        assert_eq!(result as i16, -32768);
    }
}

/// 25-bit unsigned Z depth conversion.
mod f32_to_z25 {
    fn f32_to_z25(val: f32) -> u32 {
        let clamped = val.clamp(0.0, 1.0);
        (clamped * 0x1FF_FFFFu32 as f32) as u32
    }

    #[test]
    fn near_plane() {
        assert_eq!(f32_to_z25(0.0), 0);
    }

    #[test]
    fn far_plane() {
        assert_eq!(f32_to_z25(1.0), 0x1FF_FFFF);
    }

    #[test]
    fn midpoint() {
        let result = f32_to_z25(0.5);
        // Should be approximately half of 0x1FFFFFF.
        assert!(result > 0x0FF_FFFF - 1 && result < 0x100_0001);
    }

    #[test]
    fn clamps_negative() {
        assert_eq!(f32_to_z25(-0.5), 0);
    }

    #[test]
    fn clamps_above_one() {
        assert_eq!(f32_to_z25(1.5), 0x1FF_FFFF);
    }
}

/// RGBA color packing.
mod rgba_packing {
    fn rgba_to_packed(r: u8, g: u8, b: u8, a: u8) -> u32 {
        ((a as u32) << 24) | ((b as u32) << 16) | ((g as u32) << 8) | (r as u32)
    }

    fn pack_color(r: u8, g: u8, b: u8, a: u8) -> u64 {
        ((a as u64) << 24) | ((b as u64) << 16) | ((g as u64) << 8) | (r as u64)
    }

    #[test]
    fn white_opaque() {
        assert_eq!(rgba_to_packed(255, 255, 255, 255), 0xFFFF_FFFF);
    }

    #[test]
    fn red_opaque() {
        assert_eq!(rgba_to_packed(255, 0, 0, 255), 0xFF00_00FF);
    }

    #[test]
    fn green_opaque() {
        assert_eq!(rgba_to_packed(0, 255, 0, 255), 0xFF00_FF00);
    }

    #[test]
    fn blue_opaque() {
        assert_eq!(rgba_to_packed(0, 0, 255, 255), 0xFFFF_0000);
    }

    #[test]
    fn transparent_black() {
        assert_eq!(rgba_to_packed(0, 0, 0, 0), 0x0000_0000);
    }

    #[test]
    fn pack_color_matches_u64() {
        // pack_color should produce the same lower 32 bits as rgba_to_packed.
        let r = 128u8;
        let g = 64u8;
        let b = 32u8;
        let a = 255u8;
        let packed32 = rgba_to_packed(r, g, b, a);
        let packed64 = pack_color(r, g, b, a);
        assert_eq!(packed32 as u64, packed64);
    }
}

/// Vertex position packing.
mod position_packing {
    fn f32_to_12_4(val: f32) -> u16 {
        let clamped = val.clamp(-2048.0, 2047.9375);
        let scaled = (clamped * 16.0) as i16;
        scaled as u16
    }

    fn f32_to_z25(val: f32) -> u32 {
        let clamped = val.clamp(0.0, 1.0);
        (clamped * 0x1FF_FFFFu32 as f32) as u32
    }

    fn pack_position(x: f32, y: f32, z: f32) -> u64 {
        let x_fixed = f32_to_12_4(x);
        let y_fixed = f32_to_12_4(y);
        let z_fixed = f32_to_z25(z);
        ((z_fixed as u64) << 32) | ((y_fixed as u64 & 0xFFFF) << 16) | (x_fixed as u64 & 0xFFFF)
    }

    #[test]
    fn origin_near() {
        let packed = pack_position(0.0, 0.0, 0.0);
        assert_eq!(packed, 0);
    }

    #[test]
    fn x_field_position() {
        let packed = pack_position(1.0, 0.0, 0.0);
        // x = 1.0 * 16 = 16 = 0x10 in bits [15:0]
        assert_eq!(packed & 0xFFFF, 16);
    }

    #[test]
    fn y_field_position() {
        let packed = pack_position(0.0, 1.0, 0.0);
        // y = 1.0 * 16 = 16 = 0x10 in bits [31:16]
        assert_eq!((packed >> 16) & 0xFFFF, 16);
    }

    #[test]
    fn z_field_far() {
        let packed = pack_position(0.0, 0.0, 1.0);
        // z = 0x1FFFFFF in bits [56:32]
        let z = ((packed >> 32) & 0x1FF_FFFF) as u32;
        assert_eq!(z, 0x1FF_FFFF);
    }

    #[test]
    fn screen_center() {
        let packed = pack_position(320.0, 240.0, 0.5);
        let x = (packed & 0xFFFF) as u16 as i16;
        let y = ((packed >> 16) & 0xFFFF) as u16 as i16;
        assert_eq!(x, 320 * 16);
        assert_eq!(y, 240 * 16);
    }
}
