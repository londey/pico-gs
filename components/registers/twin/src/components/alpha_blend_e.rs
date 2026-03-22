//! Field Enum: ALPHA_BLEND

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlphaBlendE {
    /// Overwrite destination
    Disabled = 0,
    /// Additive: src + dst, saturate
    Add = 1,
    /// Subtractive: src - dst, saturate
    Subtract = 2,
    /// Alpha blend: src*a + dst*(1-a)
    Blend = 3,
}

impl AlphaBlendE {
    /// Decode a bit pattern into an encoded enum variant.
    ///
    /// # Errors
    /// Returns an error if the bit pattern does not match any encoded variants.
    pub const fn from_bits(bits: u8) -> Result<Self, crate::encode::UnknownVariant<u8>> {
        match bits {
            0 => Ok(Self::Disabled),
            1 => Ok(Self::Add),
            2 => Ok(Self::Subtract),
            3 => Ok(Self::Blend),
            bits => Err(crate::encode::UnknownVariant::new(bits)),
        }
    }

    /// The bit pattern of the variant
    #[must_use]
    pub const fn bits(&self) -> u8 {
        *self as u8
    }
}
