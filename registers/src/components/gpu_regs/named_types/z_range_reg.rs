//! Register: Z_RANGE

/// Z_RANGE
///
/// Depth range clipping (Z scissor) min/max
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct ZRangeReg(u64);

unsafe impl Send for ZRangeReg {}
unsafe impl Sync for ZRangeReg {}

impl core::default::Default for ZRangeReg {
    fn default() -> Self {
        Self(0xFFFF_0000)
    }
}

impl crate::reg::Register for ZRangeReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl ZRangeReg {
    pub const Z_RANGE_MIN_OFFSET: usize = 0;
    pub const Z_RANGE_MIN_WIDTH: usize = 16;
    pub const Z_RANGE_MIN_MASK: u64 = 0xFFFF;

    /// Z_RANGE_MIN
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn z_range_min(&self) -> u16 {
        let val = (self.0 >> Self::Z_RANGE_MIN_OFFSET) & Self::Z_RANGE_MIN_MASK;
        val as u16
    }

    /// Z_RANGE_MIN
    #[inline(always)]
    pub fn set_z_range_min(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::Z_RANGE_MIN_MASK << Self::Z_RANGE_MIN_OFFSET))
            | ((val & Self::Z_RANGE_MIN_MASK) << Self::Z_RANGE_MIN_OFFSET);
    }

    pub const Z_RANGE_MAX_OFFSET: usize = 16;
    pub const Z_RANGE_MAX_WIDTH: usize = 16;
    pub const Z_RANGE_MAX_MASK: u64 = 0xFFFF;

    /// Z_RANGE_MAX
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn z_range_max(&self) -> u16 {
        let val = (self.0 >> Self::Z_RANGE_MAX_OFFSET) & Self::Z_RANGE_MAX_MASK;
        val as u16
    }

    /// Z_RANGE_MAX
    #[inline(always)]
    pub fn set_z_range_max(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::Z_RANGE_MAX_MASK << Self::Z_RANGE_MAX_OFFSET))
            | ((val & Self::Z_RANGE_MAX_MASK) << Self::Z_RANGE_MAX_OFFSET);
    }

    pub const RSVD_OFFSET: usize = 32;
    pub const RSVD_WIDTH: usize = 32;
    pub const RSVD_MASK: u64 = 0xFFFF_FFFF;

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

impl core::fmt::Debug for ZRangeReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("ZRangeReg")
            .field("z_range_min", &self.z_range_min())
            .field("z_range_max", &self.z_range_max())
            .field("rsvd", &self.rsvd())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = ZRangeReg::default();
        assert_eq!(reg.z_range_min(), 0);
        assert_eq!(reg.z_range_max(), 65535);
        assert_eq!(reg.rsvd(), 0);
    }
}
