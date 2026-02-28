//! Register: AREA_SETUP

/// AREA_SETUP
///
/// Barycentric interpolation area normalization.
/// INV_AREA is the reciprocal of (2*triangle_area >> AREA_SHIFT)
/// in UQ0.16 fixed point.  AREA_SHIFT is the barrel-shift count
/// applied to edge function values before the 16x16 multiply.
/// The host computes both values from the triangle vertex
/// positions before each vertex kick.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct AreaSetupReg(u64);

unsafe impl Send for AreaSetupReg {}
unsafe impl Sync for AreaSetupReg {}

impl core::default::Default for AreaSetupReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for AreaSetupReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl AreaSetupReg {
    pub const INV_AREA_OFFSET: usize = 0;
    pub const INV_AREA_WIDTH: usize = 16;
    pub const INV_AREA_MASK: u64 = 0xFFFF;

    /// INV_AREA
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn inv_area(&self) -> u16 {
        let val = (self.0 >> Self::INV_AREA_OFFSET) & Self::INV_AREA_MASK;
        val as u16
    }

    /// INV_AREA
    #[inline(always)]
    pub fn set_inv_area(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::INV_AREA_MASK << Self::INV_AREA_OFFSET))
            | ((val & Self::INV_AREA_MASK) << Self::INV_AREA_OFFSET);
    }

    pub const AREA_SHIFT_OFFSET: usize = 16;
    pub const AREA_SHIFT_WIDTH: usize = 4;
    pub const AREA_SHIFT_MASK: u64 = 0xF;

    /// AREA_SHIFT
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn area_shift(&self) -> u8 {
        let val = (self.0 >> Self::AREA_SHIFT_OFFSET) & Self::AREA_SHIFT_MASK;
        val as u8
    }

    /// AREA_SHIFT
    #[inline(always)]
    pub fn set_area_shift(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::AREA_SHIFT_MASK << Self::AREA_SHIFT_OFFSET))
            | ((val & Self::AREA_SHIFT_MASK) << Self::AREA_SHIFT_OFFSET);
    }

    pub const RSVD_OFFSET: usize = 20;
    pub const RSVD_WIDTH: usize = 44;
    pub const RSVD_MASK: u64 = 0xFFF_FFFF_FFFF;

    /// RSVD
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn rsvd(&self) -> u64 {
        let val = (self.0 >> Self::RSVD_OFFSET) & Self::RSVD_MASK;
        val
    }

    /// RSVD
    #[inline(always)]
    pub fn set_rsvd(&mut self, val: u64) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::RSVD_MASK << Self::RSVD_OFFSET))
            | ((val & Self::RSVD_MASK) << Self::RSVD_OFFSET);
    }
}

impl core::fmt::Debug for AreaSetupReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("AreaSetupReg")
            .field("inv_area", &self.inv_area())
            .field("area_shift", &self.area_shift())
            .field("rsvd", &self.rsvd())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = AreaSetupReg::default();
        assert_eq!(reg.inv_area(), 0);
        assert_eq!(reg.area_shift(), 0);
        assert_eq!(reg.rsvd(), 0);
    }
}
