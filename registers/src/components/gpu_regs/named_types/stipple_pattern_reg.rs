//! Register: STIPPLE_PATTERN

/// STIPPLE_PATTERN
///
/// 8x8 stipple bitmask (row-major, bit 0 = pixel (0,0)).
/// Bit index = y[2:0] * 8 + x[2:0].  Fragment passes if the
/// corresponding bit is 1; discarded if 0.  Only active when
/// RENDER_MODE.STIPPLE_EN = 1.  Screen coordinates are masked
/// to 3 bits (x & 7, y & 7) to index into the pattern.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct StipplePatternReg(u64);

unsafe impl Send for StipplePatternReg {}
unsafe impl Sync for StipplePatternReg {}

impl core::default::Default for StipplePatternReg {
    fn default() -> Self {
        Self(0xFFFF_FFFF_FFFF_FFFF)
    }
}

impl crate::reg::Register for StipplePatternReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl StipplePatternReg {
    pub const PATTERN_OFFSET: usize = 0;
    pub const PATTERN_WIDTH: usize = 64;
    pub const PATTERN_MASK: u64 = 0xFFFF_FFFF_FFFF_FFFF;

    /// PATTERN
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn pattern(&self) -> u64 {
        let val = (self.0 >> Self::PATTERN_OFFSET) & Self::PATTERN_MASK;
        val
    }

    /// PATTERN
    #[inline(always)]
    pub fn set_pattern(&mut self, val: u64) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::PATTERN_MASK << Self::PATTERN_OFFSET))
            | ((val & Self::PATTERN_MASK) << Self::PATTERN_OFFSET);
    }
}

impl core::fmt::Debug for StipplePatternReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("StipplePatternReg")
            .field("pattern", &self.pattern())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = StipplePatternReg::default();
        assert_eq!(reg.pattern(), 18446744073709551615);
    }
}
