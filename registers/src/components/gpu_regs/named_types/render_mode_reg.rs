//! Register: RENDER_MODE

// Instances of named component types
pub use crate::components::alpha_blend_e as alpha_blend;
pub use crate::components::alpha_test_e as alpha_test_func;
pub use crate::components::cull_mode_e as cull_mode;
pub use crate::components::dither_pattern_e as dither_pattern;
pub use crate::components::z_compare_e as z_compare;

/// RENDER_MODE
///
/// Unified rendering state (Gouraud, Z, alpha, culling, dithering, stipple)
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct RenderModeReg(u64);

unsafe impl Send for RenderModeReg {}
unsafe impl Sync for RenderModeReg {}

impl core::default::Default for RenderModeReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for RenderModeReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl RenderModeReg {
    pub const GOURAUD_OFFSET: usize = 0;
    pub const GOURAUD_WIDTH: usize = 1;
    pub const GOURAUD_MASK: u64 = 0x1;

    /// GOURAUD
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn gouraud(&self) -> bool {
        let val = (self.0 >> Self::GOURAUD_OFFSET) & Self::GOURAUD_MASK;
        val != 0
    }

    /// GOURAUD
    #[inline(always)]
    pub fn set_gouraud(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::GOURAUD_MASK << Self::GOURAUD_OFFSET))
            | ((val & Self::GOURAUD_MASK) << Self::GOURAUD_OFFSET);
    }

    pub const RSVD_1_OFFSET: usize = 1;
    pub const RSVD_1_WIDTH: usize = 1;
    pub const RSVD_1_MASK: u64 = 0x1;

    /// RSVD_1
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn rsvd_1(&self) -> bool {
        let val = (self.0 >> Self::RSVD_1_OFFSET) & Self::RSVD_1_MASK;
        val != 0
    }

    /// RSVD_1
    #[inline(always)]
    pub fn set_rsvd_1(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::RSVD_1_MASK << Self::RSVD_1_OFFSET))
            | ((val & Self::RSVD_1_MASK) << Self::RSVD_1_OFFSET);
    }

    pub const Z_TEST_EN_OFFSET: usize = 2;
    pub const Z_TEST_EN_WIDTH: usize = 1;
    pub const Z_TEST_EN_MASK: u64 = 0x1;

    /// Z_TEST_EN
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn z_test_en(&self) -> bool {
        let val = (self.0 >> Self::Z_TEST_EN_OFFSET) & Self::Z_TEST_EN_MASK;
        val != 0
    }

    /// Z_TEST_EN
    #[inline(always)]
    pub fn set_z_test_en(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::Z_TEST_EN_MASK << Self::Z_TEST_EN_OFFSET))
            | ((val & Self::Z_TEST_EN_MASK) << Self::Z_TEST_EN_OFFSET);
    }

    pub const Z_WRITE_EN_OFFSET: usize = 3;
    pub const Z_WRITE_EN_WIDTH: usize = 1;
    pub const Z_WRITE_EN_MASK: u64 = 0x1;

    /// Z_WRITE_EN
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn z_write_en(&self) -> bool {
        let val = (self.0 >> Self::Z_WRITE_EN_OFFSET) & Self::Z_WRITE_EN_MASK;
        val != 0
    }

    /// Z_WRITE_EN
    #[inline(always)]
    pub fn set_z_write_en(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::Z_WRITE_EN_MASK << Self::Z_WRITE_EN_OFFSET))
            | ((val & Self::Z_WRITE_EN_MASK) << Self::Z_WRITE_EN_OFFSET);
    }

    pub const COLOR_WRITE_EN_OFFSET: usize = 4;
    pub const COLOR_WRITE_EN_WIDTH: usize = 1;
    pub const COLOR_WRITE_EN_MASK: u64 = 0x1;

    /// COLOR_WRITE_EN
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn color_write_en(&self) -> bool {
        let val = (self.0 >> Self::COLOR_WRITE_EN_OFFSET) & Self::COLOR_WRITE_EN_MASK;
        val != 0
    }

    /// COLOR_WRITE_EN
    #[inline(always)]
    pub fn set_color_write_en(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::COLOR_WRITE_EN_MASK << Self::COLOR_WRITE_EN_OFFSET))
            | ((val & Self::COLOR_WRITE_EN_MASK) << Self::COLOR_WRITE_EN_OFFSET);
    }

    pub const CULL_MODE_OFFSET: usize = 5;
    pub const CULL_MODE_WIDTH: usize = 2;
    pub const CULL_MODE_MASK: u64 = 0x3;

    /// CULL_MODE
    #[inline(always)]
    #[allow(clippy::missing_errors_doc)]
    pub fn cull_mode(&self) -> Result<cull_mode::CullModeE, crate::encode::UnknownVariant<u8>> {
        let val = (self.0 >> Self::CULL_MODE_OFFSET) & Self::CULL_MODE_MASK;
        cull_mode::CullModeE::from_bits(val as u8)
    }

    /// CULL_MODE
    #[inline(always)]
    pub fn set_cull_mode(&mut self, val: cull_mode::CullModeE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::CULL_MODE_MASK << Self::CULL_MODE_OFFSET))
            | ((val & Self::CULL_MODE_MASK) << Self::CULL_MODE_OFFSET);
    }

    pub const ALPHA_BLEND_OFFSET: usize = 7;
    pub const ALPHA_BLEND_WIDTH: usize = 3;
    pub const ALPHA_BLEND_MASK: u64 = 0x7;

    /// ALPHA_BLEND
    #[inline(always)]
    #[allow(clippy::missing_errors_doc)]
    pub fn alpha_blend(
        &self,
    ) -> Result<alpha_blend::AlphaBlendE, crate::encode::UnknownVariant<u8>> {
        let val = (self.0 >> Self::ALPHA_BLEND_OFFSET) & Self::ALPHA_BLEND_MASK;
        alpha_blend::AlphaBlendE::from_bits(val as u8)
    }

    /// ALPHA_BLEND
    #[inline(always)]
    pub fn set_alpha_blend(&mut self, val: alpha_blend::AlphaBlendE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::ALPHA_BLEND_MASK << Self::ALPHA_BLEND_OFFSET))
            | ((val & Self::ALPHA_BLEND_MASK) << Self::ALPHA_BLEND_OFFSET);
    }

    pub const DITHER_EN_OFFSET: usize = 10;
    pub const DITHER_EN_WIDTH: usize = 1;
    pub const DITHER_EN_MASK: u64 = 0x1;

    /// DITHER_EN
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn dither_en(&self) -> bool {
        let val = (self.0 >> Self::DITHER_EN_OFFSET) & Self::DITHER_EN_MASK;
        val != 0
    }

    /// DITHER_EN
    #[inline(always)]
    pub fn set_dither_en(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::DITHER_EN_MASK << Self::DITHER_EN_OFFSET))
            | ((val & Self::DITHER_EN_MASK) << Self::DITHER_EN_OFFSET);
    }

    pub const DITHER_PATTERN_OFFSET: usize = 11;
    pub const DITHER_PATTERN_WIDTH: usize = 2;
    pub const DITHER_PATTERN_MASK: u64 = 0x3;

    /// DITHER_PATTERN
    #[inline(always)]
    #[allow(clippy::missing_errors_doc)]
    pub fn dither_pattern(
        &self,
    ) -> Result<dither_pattern::DitherPatternE, crate::encode::UnknownVariant<u8>> {
        let val = (self.0 >> Self::DITHER_PATTERN_OFFSET) & Self::DITHER_PATTERN_MASK;
        dither_pattern::DitherPatternE::from_bits(val as u8)
    }

    /// DITHER_PATTERN
    #[inline(always)]
    pub fn set_dither_pattern(&mut self, val: dither_pattern::DitherPatternE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::DITHER_PATTERN_MASK << Self::DITHER_PATTERN_OFFSET))
            | ((val & Self::DITHER_PATTERN_MASK) << Self::DITHER_PATTERN_OFFSET);
    }

    pub const Z_COMPARE_OFFSET: usize = 13;
    pub const Z_COMPARE_WIDTH: usize = 3;
    pub const Z_COMPARE_MASK: u64 = 0x7;

    /// Z_COMPARE
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn z_compare(&self) -> z_compare::ZCompareE {
        let val = (self.0 >> Self::Z_COMPARE_OFFSET) & Self::Z_COMPARE_MASK;
        z_compare::ZCompareE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// Z_COMPARE
    #[inline(always)]
    pub fn set_z_compare(&mut self, val: z_compare::ZCompareE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::Z_COMPARE_MASK << Self::Z_COMPARE_OFFSET))
            | ((val & Self::Z_COMPARE_MASK) << Self::Z_COMPARE_OFFSET);
    }

    pub const STIPPLE_EN_OFFSET: usize = 16;
    pub const STIPPLE_EN_WIDTH: usize = 1;
    pub const STIPPLE_EN_MASK: u64 = 0x1;

    /// STIPPLE_EN
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn stipple_en(&self) -> bool {
        let val = (self.0 >> Self::STIPPLE_EN_OFFSET) & Self::STIPPLE_EN_MASK;
        val != 0
    }

    /// STIPPLE_EN
    #[inline(always)]
    pub fn set_stipple_en(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::STIPPLE_EN_MASK << Self::STIPPLE_EN_OFFSET))
            | ((val & Self::STIPPLE_EN_MASK) << Self::STIPPLE_EN_OFFSET);
    }

    pub const ALPHA_TEST_FUNC_OFFSET: usize = 17;
    pub const ALPHA_TEST_FUNC_WIDTH: usize = 2;
    pub const ALPHA_TEST_FUNC_MASK: u64 = 0x3;

    /// ALPHA_TEST_FUNC
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn alpha_test_func(&self) -> alpha_test_func::AlphaTestE {
        let val = (self.0 >> Self::ALPHA_TEST_FUNC_OFFSET) & Self::ALPHA_TEST_FUNC_MASK;
        alpha_test_func::AlphaTestE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// ALPHA_TEST_FUNC
    #[inline(always)]
    pub fn set_alpha_test_func(&mut self, val: alpha_test_func::AlphaTestE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::ALPHA_TEST_FUNC_MASK << Self::ALPHA_TEST_FUNC_OFFSET))
            | ((val & Self::ALPHA_TEST_FUNC_MASK) << Self::ALPHA_TEST_FUNC_OFFSET);
    }

    pub const ALPHA_REF_OFFSET: usize = 19;
    pub const ALPHA_REF_WIDTH: usize = 8;
    pub const ALPHA_REF_MASK: u64 = 0xFF;

    /// ALPHA_REF
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn alpha_ref(&self) -> u8 {
        let val = (self.0 >> Self::ALPHA_REF_OFFSET) & Self::ALPHA_REF_MASK;
        val as u8
    }

    /// ALPHA_REF
    #[inline(always)]
    pub fn set_alpha_ref(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::ALPHA_REF_MASK << Self::ALPHA_REF_OFFSET))
            | ((val & Self::ALPHA_REF_MASK) << Self::ALPHA_REF_OFFSET);
    }

    pub const RSVD_HI_OFFSET: usize = 27;
    pub const RSVD_HI_WIDTH: usize = 37;
    pub const RSVD_HI_MASK: u64 = 0x1F_FFFF_FFFF;

    /// RSVD_HI
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn rsvd_hi(&self) -> u64 {
        let val = (self.0 >> Self::RSVD_HI_OFFSET) & Self::RSVD_HI_MASK;
        val
    }

    /// RSVD_HI
    #[inline(always)]
    pub fn set_rsvd_hi(&mut self, val: u64) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::RSVD_HI_MASK << Self::RSVD_HI_OFFSET))
            | ((val & Self::RSVD_HI_MASK) << Self::RSVD_HI_OFFSET);
    }
}

impl core::fmt::Debug for RenderModeReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("RenderModeReg")
            .field("gouraud", &self.gouraud())
            .field("rsvd_1", &self.rsvd_1())
            .field("z_test_en", &self.z_test_en())
            .field("z_write_en", &self.z_write_en())
            .field("color_write_en", &self.color_write_en())
            .field("cull_mode", &self.cull_mode())
            .field("alpha_blend", &self.alpha_blend())
            .field("dither_en", &self.dither_en())
            .field("dither_pattern", &self.dither_pattern())
            .field("z_compare", &self.z_compare())
            .field("stipple_en", &self.stipple_en())
            .field("alpha_test_func", &self.alpha_test_func())
            .field("alpha_ref", &self.alpha_ref())
            .field("rsvd_hi", &self.rsvd_hi())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = RenderModeReg::default();
        assert_eq!(reg.gouraud(), false);
        assert_eq!(reg.rsvd_1(), false);
        assert_eq!(reg.z_test_en(), false);
        assert_eq!(reg.z_write_en(), false);
        assert_eq!(reg.color_write_en(), false);
        assert_eq!(reg.cull_mode(), Ok(cull_mode::CullModeE::CullNone));
        assert_eq!(reg.alpha_blend(), Ok(alpha_blend::AlphaBlendE::Disabled));
        assert_eq!(reg.dither_en(), false);
        assert_eq!(
            reg.dither_pattern(),
            Ok(dither_pattern::DitherPatternE::BlueNoise16x16)
        );
        assert_eq!(reg.z_compare(), z_compare::ZCompareE::Less);
        assert_eq!(reg.stipple_en(), false);
        assert_eq!(reg.alpha_test_func(), alpha_test_func::AlphaTestE::AtAlways);
        assert_eq!(reg.alpha_ref(), 0);
        assert_eq!(reg.rsvd_hi(), 0);
    }
}
