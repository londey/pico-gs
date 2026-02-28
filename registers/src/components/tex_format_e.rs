//! Field Enum: FORMAT

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TexFormatE {
    /// 4 bpp, 64 bits per 4x4 block, opaque or 1-bit alpha
    Bc1 = 0,
    /// 8 bpp, 128 bits per 4x4 block, explicit alpha
    Bc2 = 1,
    /// 8 bpp, 128 bits per 4x4 block, interpolated alpha
    Bc3 = 2,
    /// 4 bpp, 64 bits per 4x4 block, single channel
    Bc4 = 3,
    /// 16 bpp, 5-6-5 uncompressed, 4x4 tiled
    Rgb565 = 4,
    /// 32 bpp, 8-8-8-8 uncompressed, 4x4 tiled
    Rgba8888 = 5,
    /// 8 bpp, single channel, 4x4 tiled
    R8 = 6,
}

impl TexFormatE {
    /// Decode a bit pattern into an encoded enum variant.
    ///
    /// # Errors
    /// Returns an error if the bit pattern does not match any encoded variants.
    pub const fn from_bits(bits: u8) -> Result<Self, crate::encode::UnknownVariant<u8>> {
        match bits {
            0 => Ok(Self::Bc1),
            1 => Ok(Self::Bc2),
            2 => Ok(Self::Bc3),
            3 => Ok(Self::Bc4),
            4 => Ok(Self::Rgb565),
            5 => Ok(Self::Rgba8888),
            6 => Ok(Self::R8),
            bits => Err(crate::encode::UnknownVariant::new(bits)),
        }
    }

    /// The bit pattern of the variant
    #[must_use]
    pub const fn bits(&self) -> u8 {
        *self as u8
    }
}
