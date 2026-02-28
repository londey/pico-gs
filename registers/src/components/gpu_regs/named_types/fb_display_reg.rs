//! Register: FB_DISPLAY

/// FB_DISPLAY
///
/// Display scanout configuration (write-blocks-until-vsync).
/// Writing this register blocks the GPU pipeline until the next
/// vertical blanking interval, then atomically switches the
/// display scanout address and latches all display mode fields.
/// The DVI output is always 640×480 at 60 Hz.  The display
/// controller reads from a 4×4 block-tiled framebuffer and
/// stretches the source image to 640×480 using nearest-neighbor
/// horizontal scaling (Bresenham accumulator, no multiply HW).
/// FB_WIDTH_LOG2 specifies the tiled surface width for scanout
/// address calculation — latched independently from FB_CONFIG
/// so that render-to-texture passes can reprogram FB_CONFIG
/// mid-frame without affecting display scanout.
/// When LINE_DOUBLE is set, only 240 source rows are read and
/// each is output twice to fill 480 display lines; the line
/// buffer is reused without re-reading SDRAM.
/// Horizontal interpolation operates on UNORM8 values post
/// color-grade LUT, ensuring tone mapping precedes any pixel
/// blending.
/// If COLOR_GRADE_ENABLE is set, the color grading LUT is
/// loaded from LUT_ADDR during the blanking interval before
/// the new frame begins scanout.
/// FB_ADDR and LUT_ADDR are 16-bit values multiplied by 512
/// to form the byte address (512-byte granularity, 32 MiB
/// addressable), matching the texture BASE_ADDR encoding.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct FbDisplayReg(u64);

unsafe impl Send for FbDisplayReg {}
unsafe impl Sync for FbDisplayReg {}

impl core::default::Default for FbDisplayReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for FbDisplayReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl FbDisplayReg {
    pub const COLOR_GRADE_ENABLE_OFFSET: usize = 0;
    pub const COLOR_GRADE_ENABLE_WIDTH: usize = 1;
    pub const COLOR_GRADE_ENABLE_MASK: u64 = 0x1;

    /// COLOR_GRADE_ENABLE
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn color_grade_enable(&self) -> bool {
        let val = (self.0 >> Self::COLOR_GRADE_ENABLE_OFFSET) & Self::COLOR_GRADE_ENABLE_MASK;
        val != 0
    }

    /// COLOR_GRADE_ENABLE
    #[inline(always)]
    pub fn set_color_grade_enable(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::COLOR_GRADE_ENABLE_MASK << Self::COLOR_GRADE_ENABLE_OFFSET))
            | ((val & Self::COLOR_GRADE_ENABLE_MASK) << Self::COLOR_GRADE_ENABLE_OFFSET);
    }

    pub const LINE_DOUBLE_OFFSET: usize = 1;
    pub const LINE_DOUBLE_WIDTH: usize = 1;
    pub const LINE_DOUBLE_MASK: u64 = 0x1;

    /// LINE_DOUBLE
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn line_double(&self) -> bool {
        let val = (self.0 >> Self::LINE_DOUBLE_OFFSET) & Self::LINE_DOUBLE_MASK;
        val != 0
    }

    /// LINE_DOUBLE
    #[inline(always)]
    pub fn set_line_double(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::LINE_DOUBLE_MASK << Self::LINE_DOUBLE_OFFSET))
            | ((val & Self::LINE_DOUBLE_MASK) << Self::LINE_DOUBLE_OFFSET);
    }

    pub const RSVD_LO_OFFSET: usize = 2;
    pub const RSVD_LO_WIDTH: usize = 14;
    pub const RSVD_LO_MASK: u64 = 0x3FFF;

    /// RSVD_LO
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn rsvd_lo(&self) -> u16 {
        let val = (self.0 >> Self::RSVD_LO_OFFSET) & Self::RSVD_LO_MASK;
        val as u16
    }

    /// RSVD_LO
    #[inline(always)]
    pub fn set_rsvd_lo(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::RSVD_LO_MASK << Self::RSVD_LO_OFFSET))
            | ((val & Self::RSVD_LO_MASK) << Self::RSVD_LO_OFFSET);
    }

    pub const LUT_ADDR_OFFSET: usize = 16;
    pub const LUT_ADDR_WIDTH: usize = 16;
    pub const LUT_ADDR_MASK: u64 = 0xFFFF;

    /// LUT_ADDR
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn lut_addr(&self) -> u16 {
        let val = (self.0 >> Self::LUT_ADDR_OFFSET) & Self::LUT_ADDR_MASK;
        val as u16
    }

    /// LUT_ADDR
    #[inline(always)]
    pub fn set_lut_addr(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::LUT_ADDR_MASK << Self::LUT_ADDR_OFFSET))
            | ((val & Self::LUT_ADDR_MASK) << Self::LUT_ADDR_OFFSET);
    }

    pub const FB_ADDR_OFFSET: usize = 32;
    pub const FB_ADDR_WIDTH: usize = 16;
    pub const FB_ADDR_MASK: u64 = 0xFFFF;

    /// FB_ADDR
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn fb_addr(&self) -> u16 {
        let val = (self.0 >> Self::FB_ADDR_OFFSET) & Self::FB_ADDR_MASK;
        val as u16
    }

    /// FB_ADDR
    #[inline(always)]
    pub fn set_fb_addr(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::FB_ADDR_MASK << Self::FB_ADDR_OFFSET))
            | ((val & Self::FB_ADDR_MASK) << Self::FB_ADDR_OFFSET);
    }

    pub const FB_WIDTH_LOG2_OFFSET: usize = 48;
    pub const FB_WIDTH_LOG2_WIDTH: usize = 4;
    pub const FB_WIDTH_LOG2_MASK: u64 = 0xF;

    /// FB_WIDTH_LOG2
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn fb_width_log2(&self) -> u8 {
        let val = (self.0 >> Self::FB_WIDTH_LOG2_OFFSET) & Self::FB_WIDTH_LOG2_MASK;
        val as u8
    }

    /// FB_WIDTH_LOG2
    #[inline(always)]
    pub fn set_fb_width_log2(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::FB_WIDTH_LOG2_MASK << Self::FB_WIDTH_LOG2_OFFSET))
            | ((val & Self::FB_WIDTH_LOG2_MASK) << Self::FB_WIDTH_LOG2_OFFSET);
    }

    pub const RSVD_HI_OFFSET: usize = 52;
    pub const RSVD_HI_WIDTH: usize = 12;
    pub const RSVD_HI_MASK: u64 = 0xFFF;

    /// RSVD_HI
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn rsvd_hi(&self) -> u16 {
        let val = (self.0 >> Self::RSVD_HI_OFFSET) & Self::RSVD_HI_MASK;
        val as u16
    }

    /// RSVD_HI
    #[inline(always)]
    pub fn set_rsvd_hi(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::RSVD_HI_MASK << Self::RSVD_HI_OFFSET))
            | ((val & Self::RSVD_HI_MASK) << Self::RSVD_HI_OFFSET);
    }
}

impl core::fmt::Debug for FbDisplayReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("FbDisplayReg")
            .field("color_grade_enable", &self.color_grade_enable())
            .field("line_double", &self.line_double())
            .field("rsvd_lo", &self.rsvd_lo())
            .field("lut_addr", &self.lut_addr())
            .field("fb_addr", &self.fb_addr())
            .field("fb_width_log2", &self.fb_width_log2())
            .field("rsvd_hi", &self.rsvd_hi())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = FbDisplayReg::default();
        assert_eq!(reg.color_grade_enable(), false);
        assert_eq!(reg.line_double(), false);
        assert_eq!(reg.rsvd_lo(), 0);
        assert_eq!(reg.lut_addr(), 0);
        assert_eq!(reg.fb_addr(), 0);
        assert_eq!(reg.fb_width_log2(), 0);
        assert_eq!(reg.rsvd_hi(), 0);
    }
}
