//! Register: CONST_COLOR

/// CONST_COLOR
///
/// Two per-draw-call constant colors packed into one 64-bit register (RGBA8888 UNORM8 each).
/// CONST1 (bits [63:32]) doubles as the fog color.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct ConstColorReg(u64);

unsafe impl Send for ConstColorReg {}
unsafe impl Sync for ConstColorReg {}

impl core::default::Default for ConstColorReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for ConstColorReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl ConstColorReg {
    pub const CONST0_R_OFFSET: usize = 0;
    pub const CONST0_R_WIDTH: usize = 8;
    pub const CONST0_R_MASK: u64 = 0xFF;

    /// CONST0_R
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn const0_r(&self) -> u8 {
        let val = (self.0 >> Self::CONST0_R_OFFSET) & Self::CONST0_R_MASK;
        val as u8
    }

    /// CONST0_R
    #[inline(always)]
    pub fn set_const0_r(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::CONST0_R_MASK << Self::CONST0_R_OFFSET))
            | ((val & Self::CONST0_R_MASK) << Self::CONST0_R_OFFSET);
    }

    pub const CONST0_G_OFFSET: usize = 8;
    pub const CONST0_G_WIDTH: usize = 8;
    pub const CONST0_G_MASK: u64 = 0xFF;

    /// CONST0_G
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn const0_g(&self) -> u8 {
        let val = (self.0 >> Self::CONST0_G_OFFSET) & Self::CONST0_G_MASK;
        val as u8
    }

    /// CONST0_G
    #[inline(always)]
    pub fn set_const0_g(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::CONST0_G_MASK << Self::CONST0_G_OFFSET))
            | ((val & Self::CONST0_G_MASK) << Self::CONST0_G_OFFSET);
    }

    pub const CONST0_B_OFFSET: usize = 16;
    pub const CONST0_B_WIDTH: usize = 8;
    pub const CONST0_B_MASK: u64 = 0xFF;

    /// CONST0_B
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn const0_b(&self) -> u8 {
        let val = (self.0 >> Self::CONST0_B_OFFSET) & Self::CONST0_B_MASK;
        val as u8
    }

    /// CONST0_B
    #[inline(always)]
    pub fn set_const0_b(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::CONST0_B_MASK << Self::CONST0_B_OFFSET))
            | ((val & Self::CONST0_B_MASK) << Self::CONST0_B_OFFSET);
    }

    pub const CONST0_A_OFFSET: usize = 24;
    pub const CONST0_A_WIDTH: usize = 8;
    pub const CONST0_A_MASK: u64 = 0xFF;

    /// CONST0_A
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn const0_a(&self) -> u8 {
        let val = (self.0 >> Self::CONST0_A_OFFSET) & Self::CONST0_A_MASK;
        val as u8
    }

    /// CONST0_A
    #[inline(always)]
    pub fn set_const0_a(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::CONST0_A_MASK << Self::CONST0_A_OFFSET))
            | ((val & Self::CONST0_A_MASK) << Self::CONST0_A_OFFSET);
    }

    pub const CONST1_R_OFFSET: usize = 32;
    pub const CONST1_R_WIDTH: usize = 8;
    pub const CONST1_R_MASK: u64 = 0xFF;

    /// CONST1_R
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn const1_r(&self) -> u8 {
        let val = (self.0 >> Self::CONST1_R_OFFSET) & Self::CONST1_R_MASK;
        val as u8
    }

    /// CONST1_R
    #[inline(always)]
    pub fn set_const1_r(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::CONST1_R_MASK << Self::CONST1_R_OFFSET))
            | ((val & Self::CONST1_R_MASK) << Self::CONST1_R_OFFSET);
    }

    pub const CONST1_G_OFFSET: usize = 40;
    pub const CONST1_G_WIDTH: usize = 8;
    pub const CONST1_G_MASK: u64 = 0xFF;

    /// CONST1_G
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn const1_g(&self) -> u8 {
        let val = (self.0 >> Self::CONST1_G_OFFSET) & Self::CONST1_G_MASK;
        val as u8
    }

    /// CONST1_G
    #[inline(always)]
    pub fn set_const1_g(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::CONST1_G_MASK << Self::CONST1_G_OFFSET))
            | ((val & Self::CONST1_G_MASK) << Self::CONST1_G_OFFSET);
    }

    pub const CONST1_B_OFFSET: usize = 48;
    pub const CONST1_B_WIDTH: usize = 8;
    pub const CONST1_B_MASK: u64 = 0xFF;

    /// CONST1_B
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn const1_b(&self) -> u8 {
        let val = (self.0 >> Self::CONST1_B_OFFSET) & Self::CONST1_B_MASK;
        val as u8
    }

    /// CONST1_B
    #[inline(always)]
    pub fn set_const1_b(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::CONST1_B_MASK << Self::CONST1_B_OFFSET))
            | ((val & Self::CONST1_B_MASK) << Self::CONST1_B_OFFSET);
    }

    pub const CONST1_A_OFFSET: usize = 56;
    pub const CONST1_A_WIDTH: usize = 8;
    pub const CONST1_A_MASK: u64 = 0xFF;

    /// CONST1_A
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn const1_a(&self) -> u8 {
        let val = (self.0 >> Self::CONST1_A_OFFSET) & Self::CONST1_A_MASK;
        val as u8
    }

    /// CONST1_A
    #[inline(always)]
    pub fn set_const1_a(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::CONST1_A_MASK << Self::CONST1_A_OFFSET))
            | ((val & Self::CONST1_A_MASK) << Self::CONST1_A_OFFSET);
    }
}

impl core::fmt::Debug for ConstColorReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("ConstColorReg")
            .field("const0_r", &self.const0_r())
            .field("const0_g", &self.const0_g())
            .field("const0_b", &self.const0_b())
            .field("const0_a", &self.const0_a())
            .field("const1_r", &self.const1_r())
            .field("const1_g", &self.const1_g())
            .field("const1_b", &self.const1_b())
            .field("const1_a", &self.const1_a())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = ConstColorReg::default();
        assert_eq!(reg.const0_r(), 0);
        assert_eq!(reg.const0_g(), 0);
        assert_eq!(reg.const0_b(), 0);
        assert_eq!(reg.const0_a(), 0);
        assert_eq!(reg.const1_r(), 0);
        assert_eq!(reg.const1_g(), 0);
        assert_eq!(reg.const1_b(), 0);
        assert_eq!(reg.const1_a(), 0);
    }
}
