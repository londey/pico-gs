//! Field Enum: C0_RGB_C

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CcRgbCSourceE {
    /// Previous combiner stage RGB output
    CcCCombined = 0,
    /// Texture 0 RGB
    CcCTex0 = 1,
    /// Texture 1 RGB
    CcCTex1 = 2,
    /// Shade 0 RGB (COLOR0, typically diffuse)
    CcCShade0 = 3,
    /// Constant color 0 RGB
    CcCConst0 = 4,
    /// Constant color 1 RGB
    CcCConst1 = 5,
    /// Constant 1.0
    CcCOne = 6,
    /// Constant 0.0
    CcCZero = 7,
    /// Texture 0 alpha broadcast to RGB
    CcCTex0Alpha = 8,
    /// Texture 1 alpha broadcast to RGB
    CcCTex1Alpha = 9,
    /// Shade 0 alpha broadcast to RGB (COLOR0 alpha)
    CcCShade0Alpha = 10,
    /// Constant color 0 alpha broadcast to RGB
    CcCConst0Alpha = 11,
    /// Previous stage alpha broadcast to RGB
    CcCCombinedAlpha = 12,
    /// Shade 1 RGB (COLOR1, typically specular)
    CcCShade1 = 13,
    /// Shade 1 alpha broadcast to RGB (COLOR1 alpha)
    CcCShade1Alpha = 14,
    /// Reserved (reads as 0)
    CcCRsvd15 = 15,
}

impl CcRgbCSourceE {
    /// Decode a bit pattern into an encoded enum variant.
    ///
    /// # Errors
    /// Returns an error if the bit pattern does not match any encoded variants.
    pub const fn from_bits(bits: u8) -> Result<Self, crate::encode::UnknownVariant<u8>> {
        match bits {
            0 => Ok(Self::CcCCombined),
            1 => Ok(Self::CcCTex0),
            2 => Ok(Self::CcCTex1),
            3 => Ok(Self::CcCShade0),
            4 => Ok(Self::CcCConst0),
            5 => Ok(Self::CcCConst1),
            6 => Ok(Self::CcCOne),
            7 => Ok(Self::CcCZero),
            8 => Ok(Self::CcCTex0Alpha),
            9 => Ok(Self::CcCTex1Alpha),
            10 => Ok(Self::CcCShade0Alpha),
            11 => Ok(Self::CcCConst0Alpha),
            12 => Ok(Self::CcCCombinedAlpha),
            13 => Ok(Self::CcCShade1),
            14 => Ok(Self::CcCShade1Alpha),
            15 => Ok(Self::CcCRsvd15),
            bits => Err(crate::encode::UnknownVariant::new(bits)),
        }
    }

    /// The bit pattern of the variant
    #[must_use]
    pub const fn bits(&self) -> u8 {
        *self as u8
    }
}
