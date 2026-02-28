//! Field Enum: CULL_MODE

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CullModeE {
    /// No culling (draw all triangles)
    CullNone = 0,
    /// Cull clockwise-wound triangles
    CullCw = 1,
    /// Cull counter-clockwise triangles
    CullCcw = 2,
}

impl CullModeE {
    /// Decode a bit pattern into an encoded enum variant.
    ///
    /// # Errors
    /// Returns an error if the bit pattern does not match any encoded variants.
    pub const fn from_bits(bits: u8) -> Result<Self, crate::encode::UnknownVariant<u8>> {
        match bits {
            0 => Ok(Self::CullNone),
            1 => Ok(Self::CullCw),
            2 => Ok(Self::CullCcw),
            bits => Err(crate::encode::UnknownVariant::new(bits)),
        }
    }

    /// The bit pattern of the variant
    #[must_use]
    pub const fn bits(&self) -> u8 {
        *self as u8
    }
}
