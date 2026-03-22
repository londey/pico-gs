//! Field Enum: ALPHA_TEST_FUNC

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlphaTestE {
    /// Always pass (alpha test disabled)
    AtAlways = 0,
    /// Pass if fragment alpha < ALPHA_REF
    AtLess = 1,
    /// Pass if fragment alpha >= ALPHA_REF (cutout transparency)
    AtGequal = 2,
    /// Pass if fragment alpha != ALPHA_REF
    AtNotequal = 3,
}

impl AlphaTestE {
    /// Decode a bit pattern into an encoded enum variant.
    ///
    /// # Errors
    /// Returns an error if the bit pattern does not match any encoded variants.
    pub const fn from_bits(bits: u8) -> Result<Self, crate::encode::UnknownVariant<u8>> {
        match bits {
            0 => Ok(Self::AtAlways),
            1 => Ok(Self::AtLess),
            2 => Ok(Self::AtGequal),
            3 => Ok(Self::AtNotequal),
            bits => Err(crate::encode::UnknownVariant::new(bits)),
        }
    }

    /// The bit pattern of the variant
    #[must_use]
    pub const fn bits(&self) -> u8 {
        *self as u8
    }
}
