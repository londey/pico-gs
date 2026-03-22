//! Field Enum: Z_COMPARE

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZCompareE {
    /// Less than (<)
    Less = 0,
    /// Less than or equal (<=)
    Lequal = 1,
    /// Equal (=)
    Equal = 2,
    /// Greater than or equal (>=)
    Gequal = 3,
    /// Greater than (>)
    Greater = 4,
    /// Not equal (!=)
    Notequal = 5,
    /// Always pass
    Always = 6,
    /// Never pass
    Never = 7,
}

impl ZCompareE {
    /// Decode a bit pattern into an encoded enum variant.
    ///
    /// # Errors
    /// Returns an error if the bit pattern does not match any encoded variants.
    pub const fn from_bits(bits: u8) -> Result<Self, crate::encode::UnknownVariant<u8>> {
        match bits {
            0 => Ok(Self::Less),
            1 => Ok(Self::Lequal),
            2 => Ok(Self::Equal),
            3 => Ok(Self::Gequal),
            4 => Ok(Self::Greater),
            5 => Ok(Self::Notequal),
            6 => Ok(Self::Always),
            7 => Ok(Self::Never),
            bits => Err(crate::encode::UnknownVariant::new(bits)),
        }
    }

    /// The bit pattern of the variant
    #[must_use]
    pub const fn bits(&self) -> u8 {
        *self as u8
    }
}
