//! Register: FB_CONFIG

/// FB_CONFIG
///
/// Render target configuration: color/Z-buffer base addresses and
/// power-of-two surface dimensions.
/// COLOR_BASE and Z_BASE are 16-bit values multiplied by 512
/// to form the byte address (512-byte granularity, 32 MiB
/// addressable), matching the texture BASE_ADDR encoding.
/// WIDTH_LOG2 and HEIGHT_LOG2 define the surface dimensions in
/// pixels as 1 << n; both the color buffer and Z-buffer use 4×4
/// block-tiled layout at these dimensions.  A paired Z-buffer at
/// Z_BASE always has the same dimensions as the color buffer.
/// The host reprograms this register between render passes to
/// switch between display framebuffer and off-screen render
/// targets; the pixel writer uses WIDTH_LOG2 for tiled address
/// calculation (shift-only, no multiply).
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct FbConfigReg(u64);

unsafe impl Send for FbConfigReg {}
unsafe impl Sync for FbConfigReg {}

impl core::default::Default for FbConfigReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for FbConfigReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl FbConfigReg {
    pub const COLOR_BASE_OFFSET: usize = 0;
    pub const COLOR_BASE_WIDTH: usize = 16;
    pub const COLOR_BASE_MASK: u64 = 0xFFFF;

    /// COLOR_BASE
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn color_base(&self) -> u16 {
        let val = (self.0 >> Self::COLOR_BASE_OFFSET) & Self::COLOR_BASE_MASK;
        val as u16
    }

    /// COLOR_BASE
    #[inline(always)]
    pub fn set_color_base(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::COLOR_BASE_MASK << Self::COLOR_BASE_OFFSET))
            | ((val & Self::COLOR_BASE_MASK) << Self::COLOR_BASE_OFFSET);
    }

    pub const Z_BASE_OFFSET: usize = 16;
    pub const Z_BASE_WIDTH: usize = 16;
    pub const Z_BASE_MASK: u64 = 0xFFFF;

    /// Z_BASE
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn z_base(&self) -> u16 {
        let val = (self.0 >> Self::Z_BASE_OFFSET) & Self::Z_BASE_MASK;
        val as u16
    }

    /// Z_BASE
    #[inline(always)]
    pub fn set_z_base(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::Z_BASE_MASK << Self::Z_BASE_OFFSET))
            | ((val & Self::Z_BASE_MASK) << Self::Z_BASE_OFFSET);
    }

    pub const WIDTH_LOG2_OFFSET: usize = 32;
    pub const WIDTH_LOG2_WIDTH: usize = 4;
    pub const WIDTH_LOG2_MASK: u64 = 0xF;

    /// WIDTH_LOG2
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn width_log2(&self) -> u8 {
        let val = (self.0 >> Self::WIDTH_LOG2_OFFSET) & Self::WIDTH_LOG2_MASK;
        val as u8
    }

    /// WIDTH_LOG2
    #[inline(always)]
    pub fn set_width_log2(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::WIDTH_LOG2_MASK << Self::WIDTH_LOG2_OFFSET))
            | ((val & Self::WIDTH_LOG2_MASK) << Self::WIDTH_LOG2_OFFSET);
    }

    pub const HEIGHT_LOG2_OFFSET: usize = 36;
    pub const HEIGHT_LOG2_WIDTH: usize = 4;
    pub const HEIGHT_LOG2_MASK: u64 = 0xF;

    /// HEIGHT_LOG2
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn height_log2(&self) -> u8 {
        let val = (self.0 >> Self::HEIGHT_LOG2_OFFSET) & Self::HEIGHT_LOG2_MASK;
        val as u8
    }

    /// HEIGHT_LOG2
    #[inline(always)]
    pub fn set_height_log2(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::HEIGHT_LOG2_MASK << Self::HEIGHT_LOG2_OFFSET))
            | ((val & Self::HEIGHT_LOG2_MASK) << Self::HEIGHT_LOG2_OFFSET);
    }

    pub const RSVD_OFFSET: usize = 40;
    pub const RSVD_WIDTH: usize = 24;
    pub const RSVD_MASK: u64 = 0xFF_FFFF;

    /// RSVD
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn rsvd(&self) -> u32 {
        let val = (self.0 >> Self::RSVD_OFFSET) & Self::RSVD_MASK;
        val as u32
    }

    /// RSVD
    #[inline(always)]
    pub fn set_rsvd(&mut self, val: u32) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::RSVD_MASK << Self::RSVD_OFFSET))
            | ((val & Self::RSVD_MASK) << Self::RSVD_OFFSET);
    }
}

impl core::fmt::Debug for FbConfigReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("FbConfigReg")
            .field("color_base", &self.color_base())
            .field("z_base", &self.z_base())
            .field("width_log2", &self.width_log2())
            .field("height_log2", &self.height_log2())
            .field("rsvd", &self.rsvd())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = FbConfigReg::default();
        assert_eq!(reg.color_base(), 0);
        assert_eq!(reg.z_base(), 0);
        assert_eq!(reg.width_log2(), 0);
        assert_eq!(reg.height_log2(), 0);
        assert_eq!(reg.rsvd(), 0);
    }
}
