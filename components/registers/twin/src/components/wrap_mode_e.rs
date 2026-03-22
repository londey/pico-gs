//! Field Enum: U_WRAP

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WrapModeE {
    /// Wrap around
    Repeat = 0,
    /// Clamp to [0, size-1]
    ClampToEdge = 1,
    /// Reflect at boundaries
    Mirror = 2,
    /// Coupled diagonal mirror for octahedral mapping
    Octahedral = 3,
}

impl WrapModeE {
    /// Decode a bit pattern into an encoded enum variant.
    ///
    /// # Errors
    /// Returns an error if the bit pattern does not match any encoded variants.
    pub const fn from_bits(bits: u8) -> Result<Self, crate::encode::UnknownVariant<u8>> {
        match bits {
            0 => Ok(Self::Repeat),
            1 => Ok(Self::ClampToEdge),
            2 => Ok(Self::Mirror),
            3 => Ok(Self::Octahedral),
            bits => Err(crate::encode::UnknownVariant::new(bits)),
        }
    }

    /// The bit pattern of the variant
    #[must_use]
    pub const fn bits(&self) -> u8 {
        *self as u8
    }
}
