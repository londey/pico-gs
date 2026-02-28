//! Register: FB_CONTROL

/// FB_CONTROL
///
/// Scissor rectangle
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct FbControlReg(u64);

unsafe impl Send for FbControlReg {}
unsafe impl Sync for FbControlReg {}

impl core::default::Default for FbControlReg {
    fn default() -> Self {
        Self(0xFF_FFF0_0000)
    }
}

impl crate::reg::Register for FbControlReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl FbControlReg {
    pub const SCISSOR_X_OFFSET: usize = 0;
    pub const SCISSOR_X_WIDTH: usize = 10;
    pub const SCISSOR_X_MASK: u64 = 0x3FF;

    /// SCISSOR_X
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn scissor_x(&self) -> u16 {
        let val = (self.0 >> Self::SCISSOR_X_OFFSET) & Self::SCISSOR_X_MASK;
        val as u16
    }

    /// SCISSOR_X
    #[inline(always)]
    pub fn set_scissor_x(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::SCISSOR_X_MASK << Self::SCISSOR_X_OFFSET))
            | ((val & Self::SCISSOR_X_MASK) << Self::SCISSOR_X_OFFSET);
    }

    pub const SCISSOR_Y_OFFSET: usize = 10;
    pub const SCISSOR_Y_WIDTH: usize = 10;
    pub const SCISSOR_Y_MASK: u64 = 0x3FF;

    /// SCISSOR_Y
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn scissor_y(&self) -> u16 {
        let val = (self.0 >> Self::SCISSOR_Y_OFFSET) & Self::SCISSOR_Y_MASK;
        val as u16
    }

    /// SCISSOR_Y
    #[inline(always)]
    pub fn set_scissor_y(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::SCISSOR_Y_MASK << Self::SCISSOR_Y_OFFSET))
            | ((val & Self::SCISSOR_Y_MASK) << Self::SCISSOR_Y_OFFSET);
    }

    pub const SCISSOR_WIDTH_OFFSET: usize = 20;
    pub const SCISSOR_WIDTH_WIDTH: usize = 10;
    pub const SCISSOR_WIDTH_MASK: u64 = 0x3FF;

    /// SCISSOR_WIDTH
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn scissor_width(&self) -> u16 {
        let val = (self.0 >> Self::SCISSOR_WIDTH_OFFSET) & Self::SCISSOR_WIDTH_MASK;
        val as u16
    }

    /// SCISSOR_WIDTH
    #[inline(always)]
    pub fn set_scissor_width(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::SCISSOR_WIDTH_MASK << Self::SCISSOR_WIDTH_OFFSET))
            | ((val & Self::SCISSOR_WIDTH_MASK) << Self::SCISSOR_WIDTH_OFFSET);
    }

    pub const SCISSOR_HEIGHT_OFFSET: usize = 30;
    pub const SCISSOR_HEIGHT_WIDTH: usize = 10;
    pub const SCISSOR_HEIGHT_MASK: u64 = 0x3FF;

    /// SCISSOR_HEIGHT
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn scissor_height(&self) -> u16 {
        let val = (self.0 >> Self::SCISSOR_HEIGHT_OFFSET) & Self::SCISSOR_HEIGHT_MASK;
        val as u16
    }

    /// SCISSOR_HEIGHT
    #[inline(always)]
    pub fn set_scissor_height(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::SCISSOR_HEIGHT_MASK << Self::SCISSOR_HEIGHT_OFFSET))
            | ((val & Self::SCISSOR_HEIGHT_MASK) << Self::SCISSOR_HEIGHT_OFFSET);
    }

    pub const RSVD_HI_OFFSET: usize = 40;
    pub const RSVD_HI_WIDTH: usize = 24;
    pub const RSVD_HI_MASK: u64 = 0xFF_FFFF;

    /// RSVD_HI
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn rsvd_hi(&self) -> u32 {
        let val = (self.0 >> Self::RSVD_HI_OFFSET) & Self::RSVD_HI_MASK;
        val as u32
    }

    /// RSVD_HI
    #[inline(always)]
    pub fn set_rsvd_hi(&mut self, val: u32) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::RSVD_HI_MASK << Self::RSVD_HI_OFFSET))
            | ((val & Self::RSVD_HI_MASK) << Self::RSVD_HI_OFFSET);
    }
}

impl core::fmt::Debug for FbControlReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("FbControlReg")
            .field("scissor_x", &self.scissor_x())
            .field("scissor_y", &self.scissor_y())
            .field("scissor_width", &self.scissor_width())
            .field("scissor_height", &self.scissor_height())
            .field("rsvd_hi", &self.rsvd_hi())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = FbControlReg::default();
        assert_eq!(reg.scissor_x(), 0);
        assert_eq!(reg.scissor_y(), 0);
        assert_eq!(reg.scissor_width(), 1023);
        assert_eq!(reg.scissor_height(), 1023);
        assert_eq!(reg.rsvd_hi(), 0);
    }
}
