//! Field Enum: FILTER

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TexFilterE {
    /// No interpolation
    Nearest = 0,
    /// 2x2 tap filter
    Bilinear = 1,
    /// Mipmap blend, requires MIP_LEVELS>1
    Trilinear = 2,
}

impl TexFilterE {
    /// Decode a bit pattern into an encoded enum variant.
    ///
    /// # Errors
    /// Returns an error if the bit pattern does not match any encoded variants.
    pub const fn from_bits(bits: u8) -> Result<Self, crate::encode::UnknownVariant<u8>> {
        match bits {
            0 => Ok(Self::Nearest),
            1 => Ok(Self::Bilinear),
            2 => Ok(Self::Trilinear),
            bits => Err(crate::encode::UnknownVariant::new(bits)),
        }
    }

    /// The bit pattern of the variant
    #[must_use]
    pub const fn bits(&self) -> u8 {
        *self as u8
    }
}
