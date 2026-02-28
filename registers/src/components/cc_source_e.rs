//! Field Enum: C0_RGB_A

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CcSourceE {
    /// Previous combiner stage output
    CcCombined = 0,
    /// Texture unit 0 color/alpha
    CcTex0 = 1,
    /// Texture unit 1 color/alpha
    CcTex1 = 2,
    /// Interpolated vertex color 0 (COLOR0, typically diffuse)
    CcShade0 = 3,
    /// Constant color 0 (per-draw-call)
    CcConst0 = 4,
    /// Constant color 1 (per-draw-call, also used for fog)
    CcConst1 = 5,
    /// Constant 1.0 (0xFF per channel)
    CcOne = 6,
    /// Constant 0.0
    CcZero = 7,
    /// Interpolated vertex color 1 (COLOR1, typically specular)
    CcShade1 = 8,
    /// Reserved (reads as 0)
    CcRsvd9 = 9,
    /// Reserved (reads as 0)
    CcRsvd10 = 10,
    /// Reserved (reads as 0)
    CcRsvd11 = 11,
    /// Reserved (reads as 0)
    CcRsvd12 = 12,
    /// Reserved (reads as 0)
    CcRsvd13 = 13,
    /// Reserved (reads as 0)
    CcRsvd14 = 14,
    /// Reserved (reads as 0)
    CcRsvd15 = 15,
}

impl CcSourceE {
    /// Decode a bit pattern into an encoded enum variant.
    ///
    /// # Errors
    /// Returns an error if the bit pattern does not match any encoded variants.
    pub const fn from_bits(bits: u8) -> Result<Self, crate::encode::UnknownVariant<u8>> {
        match bits {
            0 => Ok(Self::CcCombined),
            1 => Ok(Self::CcTex0),
            2 => Ok(Self::CcTex1),
            3 => Ok(Self::CcShade0),
            4 => Ok(Self::CcConst0),
            5 => Ok(Self::CcConst1),
            6 => Ok(Self::CcOne),
            7 => Ok(Self::CcZero),
            8 => Ok(Self::CcShade1),
            9 => Ok(Self::CcRsvd9),
            10 => Ok(Self::CcRsvd10),
            11 => Ok(Self::CcRsvd11),
            12 => Ok(Self::CcRsvd12),
            13 => Ok(Self::CcRsvd13),
            14 => Ok(Self::CcRsvd14),
            15 => Ok(Self::CcRsvd15),
            bits => Err(crate::encode::UnknownVariant::new(bits)),
        }
    }

    /// The bit pattern of the variant
    #[must_use]
    pub const fn bits(&self) -> u8 {
        *self as u8
    }
}
