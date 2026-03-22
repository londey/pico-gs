//! Register: COLOR

/// COLOR
///
/// COLOR0[31:0] + COLOR1[63:32] vertex colors (RGBA8888 UNORM8 each)
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct ColorReg(u64);

unsafe impl Send for ColorReg {}
unsafe impl Sync for ColorReg {}

impl core::default::Default for ColorReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for ColorReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl ColorReg {
    pub const COLOR0_R_OFFSET: usize = 0;
    pub const COLOR0_R_WIDTH: usize = 8;
    pub const COLOR0_R_MASK: u64 = 0xFF;

    /// COLOR0_R
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn color0_r(&self) -> u8 {
        let val = (self.0 >> Self::COLOR0_R_OFFSET) & Self::COLOR0_R_MASK;
        val as u8
    }

    /// COLOR0_R
    #[inline(always)]
    pub fn set_color0_r(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::COLOR0_R_MASK << Self::COLOR0_R_OFFSET))
            | ((val & Self::COLOR0_R_MASK) << Self::COLOR0_R_OFFSET);
    }

    pub const COLOR0_G_OFFSET: usize = 8;
    pub const COLOR0_G_WIDTH: usize = 8;
    pub const COLOR0_G_MASK: u64 = 0xFF;

    /// COLOR0_G
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn color0_g(&self) -> u8 {
        let val = (self.0 >> Self::COLOR0_G_OFFSET) & Self::COLOR0_G_MASK;
        val as u8
    }

    /// COLOR0_G
    #[inline(always)]
    pub fn set_color0_g(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::COLOR0_G_MASK << Self::COLOR0_G_OFFSET))
            | ((val & Self::COLOR0_G_MASK) << Self::COLOR0_G_OFFSET);
    }

    pub const COLOR0_B_OFFSET: usize = 16;
    pub const COLOR0_B_WIDTH: usize = 8;
    pub const COLOR0_B_MASK: u64 = 0xFF;

    /// COLOR0_B
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn color0_b(&self) -> u8 {
        let val = (self.0 >> Self::COLOR0_B_OFFSET) & Self::COLOR0_B_MASK;
        val as u8
    }

    /// COLOR0_B
    #[inline(always)]
    pub fn set_color0_b(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::COLOR0_B_MASK << Self::COLOR0_B_OFFSET))
            | ((val & Self::COLOR0_B_MASK) << Self::COLOR0_B_OFFSET);
    }

    pub const COLOR0_A_OFFSET: usize = 24;
    pub const COLOR0_A_WIDTH: usize = 8;
    pub const COLOR0_A_MASK: u64 = 0xFF;

    /// COLOR0_A
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn color0_a(&self) -> u8 {
        let val = (self.0 >> Self::COLOR0_A_OFFSET) & Self::COLOR0_A_MASK;
        val as u8
    }

    /// COLOR0_A
    #[inline(always)]
    pub fn set_color0_a(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::COLOR0_A_MASK << Self::COLOR0_A_OFFSET))
            | ((val & Self::COLOR0_A_MASK) << Self::COLOR0_A_OFFSET);
    }

    pub const COLOR1_R_OFFSET: usize = 32;
    pub const COLOR1_R_WIDTH: usize = 8;
    pub const COLOR1_R_MASK: u64 = 0xFF;

    /// COLOR1_R
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn color1_r(&self) -> u8 {
        let val = (self.0 >> Self::COLOR1_R_OFFSET) & Self::COLOR1_R_MASK;
        val as u8
    }

    /// COLOR1_R
    #[inline(always)]
    pub fn set_color1_r(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::COLOR1_R_MASK << Self::COLOR1_R_OFFSET))
            | ((val & Self::COLOR1_R_MASK) << Self::COLOR1_R_OFFSET);
    }

    pub const COLOR1_G_OFFSET: usize = 40;
    pub const COLOR1_G_WIDTH: usize = 8;
    pub const COLOR1_G_MASK: u64 = 0xFF;

    /// COLOR1_G
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn color1_g(&self) -> u8 {
        let val = (self.0 >> Self::COLOR1_G_OFFSET) & Self::COLOR1_G_MASK;
        val as u8
    }

    /// COLOR1_G
    #[inline(always)]
    pub fn set_color1_g(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::COLOR1_G_MASK << Self::COLOR1_G_OFFSET))
            | ((val & Self::COLOR1_G_MASK) << Self::COLOR1_G_OFFSET);
    }

    pub const COLOR1_B_OFFSET: usize = 48;
    pub const COLOR1_B_WIDTH: usize = 8;
    pub const COLOR1_B_MASK: u64 = 0xFF;

    /// COLOR1_B
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn color1_b(&self) -> u8 {
        let val = (self.0 >> Self::COLOR1_B_OFFSET) & Self::COLOR1_B_MASK;
        val as u8
    }

    /// COLOR1_B
    #[inline(always)]
    pub fn set_color1_b(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::COLOR1_B_MASK << Self::COLOR1_B_OFFSET))
            | ((val & Self::COLOR1_B_MASK) << Self::COLOR1_B_OFFSET);
    }

    pub const COLOR1_A_OFFSET: usize = 56;
    pub const COLOR1_A_WIDTH: usize = 8;
    pub const COLOR1_A_MASK: u64 = 0xFF;

    /// COLOR1_A
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn color1_a(&self) -> u8 {
        let val = (self.0 >> Self::COLOR1_A_OFFSET) & Self::COLOR1_A_MASK;
        val as u8
    }

    /// COLOR1_A
    #[inline(always)]
    pub fn set_color1_a(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::COLOR1_A_MASK << Self::COLOR1_A_OFFSET))
            | ((val & Self::COLOR1_A_MASK) << Self::COLOR1_A_OFFSET);
    }
}

impl core::fmt::Debug for ColorReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("ColorReg")
            .field("color0_r", &self.color0_r())
            .field("color0_g", &self.color0_g())
            .field("color0_b", &self.color0_b())
            .field("color0_a", &self.color0_a())
            .field("color1_r", &self.color1_r())
            .field("color1_g", &self.color1_g())
            .field("color1_b", &self.color1_b())
            .field("color1_a", &self.color1_a())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = ColorReg::default();
        assert_eq!(reg.color0_r(), 0);
        assert_eq!(reg.color0_g(), 0);
        assert_eq!(reg.color0_b(), 0);
        assert_eq!(reg.color0_a(), 0);
        assert_eq!(reg.color1_r(), 0);
        assert_eq!(reg.color1_g(), 0);
        assert_eq!(reg.color1_b(), 0);
        assert_eq!(reg.color1_a(), 0);
    }
}
