//! Field Enum: DITHER_PATTERN

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DitherPatternE {
    /// Blue noise 16x16 (default)
    BlueNoise16x16 = 0,
}

impl DitherPatternE {
    /// Decode a bit pattern into an encoded enum variant.
    ///
    /// # Errors
    /// Returns an error if the bit pattern does not match any encoded variants.
    pub const fn from_bits(bits: u8) -> Result<Self, crate::encode::UnknownVariant<u8>> {
        match bits {
            0 => Ok(Self::BlueNoise16x16),
            bits => Err(crate::encode::UnknownVariant::new(bits)),
        }
    }

    /// The bit pattern of the variant
    #[must_use]
    pub const fn bits(&self) -> u8 {
        *self as u8
    }
}
