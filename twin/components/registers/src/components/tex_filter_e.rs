//! Field Enum: FILTER

#[allow(unused_imports)]
use super::_root; // alias to root module of generated code

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TexFilterE {
    /// No interpolation (only legal value; 1-3 reserved)
    Nearest = 0,
}

impl TexFilterE {
    /// Decode a bit pattern into an encoded enum variant.
    ///
    /// # Errors
    /// Returns an error if the bit pattern does not match any encoded variants.
    pub const fn from_bits(bits: u8) -> Result<Self, peakrdl_rust::encode::UnknownVariant<u8>> {
        match bits {
            0 => Ok(Self::Nearest),
            bits => Err(peakrdl_rust::encode::UnknownVariant::new(bits)),
        }
    }

    /// The bit pattern of the variant
    #[must_use]
    pub const fn bits(&self) -> u8 {
        *self as u8
    }
}
