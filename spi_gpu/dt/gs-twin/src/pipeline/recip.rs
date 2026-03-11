//! Reciprocal lookup functions matching the RTL's raster_recip_area.sv and
//! raster_recip_q.sv.
//!
//! Both modules use CLZ-based normalization, ROM lookup, and linear
//! interpolation to compute reciprocals without division.
//! The LUT tables are generated from the same mathematical formula used
//! to create the RTL hex files.

/// Result of reciprocal area computation.
///
/// Matches raster_recip_area.sv output: a UQ1.17 normalized mantissa and a
/// 5-bit shift count.  The consumer computes:
///   `derivative = (raw * recip_mantissa) >>> area_shift`
pub struct RecipArea {
    /// UQ1.17 normalized reciprocal mantissa (18-bit unsigned).
    pub mantissa: u32,

    /// Right-shift amount for denormalization (range 1..=22).
    pub area_shift: u8,
}

/// Compute reciprocal of signed triangle area.
///
/// Matches raster_recip_area.sv algorithm:
/// 1. Absolute value of 22-bit signed area
/// 2. CLZ on 22-bit magnitude
/// 3. Normalize and look up in 512-entry ROM
/// 4. Linear interpolation with 9-bit fraction
///
/// Returns `None` for degenerate triangles (area == 0).
pub fn recip_area(area: i32) -> Option<RecipArea> {
    // Treat as 22-bit signed: extract magnitude
    let magnitude = (area.unsigned_abs()) & 0x003F_FFFF; // 22-bit mask
    if magnitude == 0 {
        return None;
    }

    // CLZ on 22-bit magnitude (count leading zeros above bit 21)
    let clz_count = (magnitude.leading_zeros() - 10) as u8; // 32-bit CLZ minus 10 unused bits

    // Normalize: shift left so bit 21 is set
    let normalized = magnitude << clz_count;

    // Extract 9-bit LUT index and 9-bit interpolation fraction
    // Bit 21 = implicit leading 1 (always set)
    // Bits [20:12] = 9-bit index
    // Bits [11:3] = 9-bit fraction
    let lut_index = ((normalized >> 12) & 0x1FF) as usize;
    let lut_frac = (normalized >> 3) & 0x1FF;

    // ROM lookup: 512-entry table, each entry packs seed (UQ1.17) and delta (UQ0.17)
    let entry = RECIP_AREA_TABLE[lut_index];
    let seed = (entry & 0x3_FFFF) as u32; // bits [17:0] = UQ1.17 seed
    let delta = ((entry >> 18) & 0x3_FFFF) as u32; // bits [35:18] = UQ0.17 delta

    // Linear interpolation: correction = (delta * fraction) >> 9
    let interp_product = delta * lut_frac; // 18 × 9 = 27 bits
    let correction = interp_product >> 9; // UQ0.17

    // Interpolated reciprocal
    let mantissa = seed - correction; // UQ1.17

    // area_shift = 22 - clz_count (range 1..=22)
    let area_shift = 22 - clz_count;

    Some(RecipArea {
        mantissa,
        area_shift,
    })
}

/// Result of per-pixel 1/Q reciprocal computation.
///
/// Matches raster_recip_q.sv output: UQ4.14 reciprocal and UQ4.4 LOD.
pub struct RecipQ {
    /// UQ4.14 reciprocal (18-bit unsigned).
    pub recip: u32,

    /// UQ4.4 level-of-detail estimate (CLZ-based).
    pub lod: u8,
}

/// Compute reciprocal of unsigned Q/W value for perspective correction.
///
/// Matches raster_recip_q.sv algorithm:
/// 1. CLZ on 32-bit unsigned input
/// 2. Normalize and look up in 1024-entry ROM
/// 3. Linear interpolation with 8-bit fraction
/// 4. Denormalize to UQ4.14
///
/// Input is the top 16 bits of the Q accumulator, zero-extended to 32 bits.
pub fn recip_q(operand: u32) -> RecipQ {
    if operand == 0 {
        return RecipQ { recip: 0, lod: 0 };
    }

    // CLZ on 32-bit unsigned input
    let clz_count = operand.leading_zeros() as u8;

    // Normalize: shift left so bit 31 is set
    let normalized = operand << (clz_count & 0x1F);

    // Extract 10-bit LUT index and 8-bit interpolation fraction
    // Bit 31 = implicit leading 1
    // Bits [30:21] = 10-bit index
    // Bits [20:13] = 8-bit fraction
    let lut_index = ((normalized >> 21) & 0x3FF) as usize;
    let lut_frac = (normalized >> 13) & 0xFF;

    // ROM lookup: two adjacent entries for delta computation
    let rom_a = RECIP_Q_TABLE[lut_index];
    let lut_index_next = if lut_index == 1023 {
        1023
    } else {
        lut_index + 1
    };
    let rom_b = RECIP_Q_TABLE[lut_index_next];

    // Delta between adjacent entries (non-negative since 1/x is decreasing)
    let delta = rom_a - rom_b; // UQ1.17

    // Linear interpolation: correction = (delta * fraction) >> 8
    let interp_product = delta * lut_frac; // 18 × 8 = 26 bits
    let correction = interp_product >> 8; // UQ1.17

    // Interpolated reciprocal (UQ1.17)
    let raw_recip = rom_a - correction;

    // Denormalize to UQ4.14:
    //   shifted = raw_recip << clz_count (in a 49-bit field)
    //   result = shifted[48:34] zero-extended to 18 bits
    let shifted = (raw_recip as u64) << (clz_count & 0x1F);
    let uq414 = ((shifted >> 34) & 0x7FFF) as u32; // 15 bits, zero-extended to 18

    // LOD = {clz[4:0], 3'b000} — integer mip level from CLZ
    let lod = (clz_count & 0x1F) << 3;

    RecipQ { recip: uq414, lod }
}

// ============================================================================
// LUT Generation
// ============================================================================

/// Generate the 512-entry reciprocal area table.
///
/// Each entry packs:
///   bits [17:0]  = seed: round(2^17 / (1 + i/512)) in UQ1.17
///   bits [35:18] = delta: seed[i] - seed[i+1] in UQ0.17
///
/// Matches recip_area_init.hex used by the RTL.
const fn generate_recip_area_table() -> [u64; 512] {
    let mut table = [0u64; 512];
    let mut i = 0;
    while i < 512 {
        // seed[i] = round(2^17 / (1 + i/512))
        // = round(2^17 * 512 / (512 + i))
        // = (2^17 * 512 + (512 + i) / 2) / (512 + i)
        let numer = (1u64 << 17) * 512;
        let denom = 512 + i as u64;
        let seed = (numer + denom / 2) / denom;

        // For delta, compute seed[i+1]
        let next_denom = 512 + i as u64 + 1;
        let next_seed = if i < 511 {
            (numer + next_denom / 2) / next_denom
        } else {
            // Last entry: delta = 0 (no neighbor beyond 511)
            seed
        };
        let delta = seed - next_seed;

        // Pack: bits [17:0] = seed, bits [35:18] = delta
        table[i] = (seed & 0x3_FFFF) | ((delta & 0x3_FFFF) << 18);
        i += 1;
    }
    table
}

/// Generate the 1024-entry reciprocal Q table.
///
/// Each entry is: round(2^17 / (1 + i/1024)) in UQ1.17 (18 bits).
///
/// Matches recip_q_init.hex used by the RTL.
const fn generate_recip_q_table() -> [u32; 1024] {
    let mut table = [0u32; 1024];
    let mut i = 0;
    while i < 1024 {
        // seed[i] = round(2^17 / (1 + i/1024))
        // = round(2^17 * 1024 / (1024 + i))
        let numer = (1u64 << 17) * 1024;
        let denom = 1024 + i as u64;
        let seed = (numer + denom / 2) / denom;
        table[i] = seed as u32;
        i += 1;
    }
    table
}

/// 512-entry reciprocal area ROM (36-bit packed entries).
static RECIP_AREA_TABLE: [u64; 512] = generate_recip_area_table();

/// 1024-entry reciprocal Q ROM (18-bit UQ1.17 entries).
static RECIP_Q_TABLE: [u32; 1024] = generate_recip_q_table();

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recip_area_table_entry_0() {
        // ROM[0] should be seed = round(2^17 / 1.0) = 131072 = 0x20000
        let entry = RECIP_AREA_TABLE[0];
        let seed = entry & 0x3_FFFF;
        assert_eq!(seed, 0x2_0000, "Entry 0 seed should be 2^17");
    }

    #[test]
    fn recip_area_basic() {
        // area = 100 → 1/100 ≈ 0.01
        let result = recip_area(100).unwrap();
        assert!(result.mantissa > 0);
        assert!(result.area_shift > 0 && result.area_shift <= 22);
    }

    #[test]
    fn recip_area_negative() {
        // Should work for negative areas too (uses absolute value)
        let pos = recip_area(100).unwrap();
        let neg = recip_area(-100).unwrap();
        assert_eq!(pos.mantissa, neg.mantissa);
        assert_eq!(pos.area_shift, neg.area_shift);
    }

    #[test]
    fn recip_area_degenerate() {
        assert!(recip_area(0).is_none());
    }

    #[test]
    fn recip_q_table_entry_0() {
        // ROM[0] should be round(2^17 / 1.0) = 131072 = 0x20000
        assert_eq!(RECIP_Q_TABLE[0], 0x2_0000);
    }

    #[test]
    fn recip_q_basic() {
        // operand = 1: reciprocal should be 1.0 in UQ4.14 = 0x4000.
        let result = recip_q(1);
        assert_eq!(result.recip, 0x4000, "recip(1) should be 1.0 in UQ4.14");
    }

    #[test]
    fn recip_q_two() {
        // operand = 2: reciprocal should be 0.5 in UQ4.14 = 0x2000.
        let result = recip_q(2);
        assert_eq!(result.recip, 0x2000, "recip(2) should be 0.5 in UQ4.14");
    }

    #[test]
    fn recip_q_zero() {
        let result = recip_q(0);
        assert_eq!(result.recip, 0);
        assert_eq!(result.lod, 0);
    }
}
