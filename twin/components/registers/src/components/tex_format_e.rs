//! Field Enum: FORMAT

#[allow(unused_imports)]
use super::_root; // alias to root module of generated code

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TexFormatE {
    /// 8 bpp palette index, 2x2 quadrant color selection (only legal value; 1-15 reserved)
    Indexed82x2 = 0,
}

impl TexFormatE {
    /// Decode a bit pattern into an encoded enum variant.
    ///
    /// # Errors
    /// Returns an error if the bit pattern does not match any encoded variants.
    pub const fn from_bits(bits: u8) -> Result<Self, peakrdl_rust::encode::UnknownVariant<u8>> {
        match bits {
            0 => Ok(Self::Indexed82x2),
            bits => Err(peakrdl_rust::encode::UnknownVariant::new(bits)),
        }
    }

    /// The bit pattern of the variant
    #[must_use]
    pub const fn bits(&self) -> u8 {
        *self as u8
    }
}
