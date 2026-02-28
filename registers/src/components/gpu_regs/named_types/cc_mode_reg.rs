//! Register: CC_MODE

// Instances of named component types
pub use crate::components::cc_rgb_c_source_e as c0_rgb_c;
pub use crate::components::cc_rgb_c_source_e as c1_rgb_c;
pub use crate::components::cc_source_e as c0_rgb_a;
pub use crate::components::cc_source_e as c0_rgb_b;
pub use crate::components::cc_source_e as c0_rgb_d;
pub use crate::components::cc_source_e as c0_alpha_a;
pub use crate::components::cc_source_e as c0_alpha_b;
pub use crate::components::cc_source_e as c0_alpha_c;
pub use crate::components::cc_source_e as c0_alpha_d;
pub use crate::components::cc_source_e as c1_rgb_a;
pub use crate::components::cc_source_e as c1_rgb_b;
pub use crate::components::cc_source_e as c1_rgb_d;
pub use crate::components::cc_source_e as c1_alpha_a;
pub use crate::components::cc_source_e as c1_alpha_b;
pub use crate::components::cc_source_e as c1_alpha_c;
pub use crate::components::cc_source_e as c1_alpha_d;

/// CC_MODE
///
/// Color combiner mode: equation (A-B)*C+D, independent RGB and Alpha.
/// The hardware always pipelines two combiner stages at one pixel
/// per clock.  Cycle 0 output feeds cycle 1 via the COMBINED source.
/// For single-equation behavior, configure cycle 1 as a pass-through:
/// A=COMBINED, B=ZERO, C=ONE, D=ZERO.
/// The RGB C slot uses an extended source set (cc_rgb_c_source_e)
/// that includes alpha-to-RGB broadcast sources for blend factors.
/// All other slots use cc_source_e.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct CcModeReg(u64);

unsafe impl Send for CcModeReg {}
unsafe impl Sync for CcModeReg {}

impl core::default::Default for CcModeReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for CcModeReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl CcModeReg {
    pub const C0_RGB_A_OFFSET: usize = 0;
    pub const C0_RGB_A_WIDTH: usize = 4;
    pub const C0_RGB_A_MASK: u64 = 0xF;

    /// C0_RGB_A
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c0_rgb_a(&self) -> c0_rgb_a::CcSourceE {
        let val = (self.0 >> Self::C0_RGB_A_OFFSET) & Self::C0_RGB_A_MASK;
        c0_rgb_a::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C0_RGB_A
    #[inline(always)]
    pub fn set_c0_rgb_a(&mut self, val: c0_rgb_a::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C0_RGB_A_MASK << Self::C0_RGB_A_OFFSET))
            | ((val & Self::C0_RGB_A_MASK) << Self::C0_RGB_A_OFFSET);
    }

    pub const C0_RGB_B_OFFSET: usize = 4;
    pub const C0_RGB_B_WIDTH: usize = 4;
    pub const C0_RGB_B_MASK: u64 = 0xF;

    /// C0_RGB_B
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c0_rgb_b(&self) -> c0_rgb_b::CcSourceE {
        let val = (self.0 >> Self::C0_RGB_B_OFFSET) & Self::C0_RGB_B_MASK;
        c0_rgb_b::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C0_RGB_B
    #[inline(always)]
    pub fn set_c0_rgb_b(&mut self, val: c0_rgb_b::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C0_RGB_B_MASK << Self::C0_RGB_B_OFFSET))
            | ((val & Self::C0_RGB_B_MASK) << Self::C0_RGB_B_OFFSET);
    }

    pub const C0_RGB_C_OFFSET: usize = 8;
    pub const C0_RGB_C_WIDTH: usize = 4;
    pub const C0_RGB_C_MASK: u64 = 0xF;

    /// C0_RGB_C
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c0_rgb_c(&self) -> c0_rgb_c::CcRgbCSourceE {
        let val = (self.0 >> Self::C0_RGB_C_OFFSET) & Self::C0_RGB_C_MASK;
        c0_rgb_c::CcRgbCSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C0_RGB_C
    #[inline(always)]
    pub fn set_c0_rgb_c(&mut self, val: c0_rgb_c::CcRgbCSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C0_RGB_C_MASK << Self::C0_RGB_C_OFFSET))
            | ((val & Self::C0_RGB_C_MASK) << Self::C0_RGB_C_OFFSET);
    }

    pub const C0_RGB_D_OFFSET: usize = 12;
    pub const C0_RGB_D_WIDTH: usize = 4;
    pub const C0_RGB_D_MASK: u64 = 0xF;

    /// C0_RGB_D
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c0_rgb_d(&self) -> c0_rgb_d::CcSourceE {
        let val = (self.0 >> Self::C0_RGB_D_OFFSET) & Self::C0_RGB_D_MASK;
        c0_rgb_d::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C0_RGB_D
    #[inline(always)]
    pub fn set_c0_rgb_d(&mut self, val: c0_rgb_d::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C0_RGB_D_MASK << Self::C0_RGB_D_OFFSET))
            | ((val & Self::C0_RGB_D_MASK) << Self::C0_RGB_D_OFFSET);
    }

    pub const C0_ALPHA_A_OFFSET: usize = 16;
    pub const C0_ALPHA_A_WIDTH: usize = 4;
    pub const C0_ALPHA_A_MASK: u64 = 0xF;

    /// C0_ALPHA_A
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c0_alpha_a(&self) -> c0_alpha_a::CcSourceE {
        let val = (self.0 >> Self::C0_ALPHA_A_OFFSET) & Self::C0_ALPHA_A_MASK;
        c0_alpha_a::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C0_ALPHA_A
    #[inline(always)]
    pub fn set_c0_alpha_a(&mut self, val: c0_alpha_a::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C0_ALPHA_A_MASK << Self::C0_ALPHA_A_OFFSET))
            | ((val & Self::C0_ALPHA_A_MASK) << Self::C0_ALPHA_A_OFFSET);
    }

    pub const C0_ALPHA_B_OFFSET: usize = 20;
    pub const C0_ALPHA_B_WIDTH: usize = 4;
    pub const C0_ALPHA_B_MASK: u64 = 0xF;

    /// C0_ALPHA_B
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c0_alpha_b(&self) -> c0_alpha_b::CcSourceE {
        let val = (self.0 >> Self::C0_ALPHA_B_OFFSET) & Self::C0_ALPHA_B_MASK;
        c0_alpha_b::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C0_ALPHA_B
    #[inline(always)]
    pub fn set_c0_alpha_b(&mut self, val: c0_alpha_b::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C0_ALPHA_B_MASK << Self::C0_ALPHA_B_OFFSET))
            | ((val & Self::C0_ALPHA_B_MASK) << Self::C0_ALPHA_B_OFFSET);
    }

    pub const C0_ALPHA_C_OFFSET: usize = 24;
    pub const C0_ALPHA_C_WIDTH: usize = 4;
    pub const C0_ALPHA_C_MASK: u64 = 0xF;

    /// C0_ALPHA_C
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c0_alpha_c(&self) -> c0_alpha_c::CcSourceE {
        let val = (self.0 >> Self::C0_ALPHA_C_OFFSET) & Self::C0_ALPHA_C_MASK;
        c0_alpha_c::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C0_ALPHA_C
    #[inline(always)]
    pub fn set_c0_alpha_c(&mut self, val: c0_alpha_c::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C0_ALPHA_C_MASK << Self::C0_ALPHA_C_OFFSET))
            | ((val & Self::C0_ALPHA_C_MASK) << Self::C0_ALPHA_C_OFFSET);
    }

    pub const C0_ALPHA_D_OFFSET: usize = 28;
    pub const C0_ALPHA_D_WIDTH: usize = 4;
    pub const C0_ALPHA_D_MASK: u64 = 0xF;

    /// C0_ALPHA_D
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c0_alpha_d(&self) -> c0_alpha_d::CcSourceE {
        let val = (self.0 >> Self::C0_ALPHA_D_OFFSET) & Self::C0_ALPHA_D_MASK;
        c0_alpha_d::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C0_ALPHA_D
    #[inline(always)]
    pub fn set_c0_alpha_d(&mut self, val: c0_alpha_d::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C0_ALPHA_D_MASK << Self::C0_ALPHA_D_OFFSET))
            | ((val & Self::C0_ALPHA_D_MASK) << Self::C0_ALPHA_D_OFFSET);
    }

    pub const C1_RGB_A_OFFSET: usize = 32;
    pub const C1_RGB_A_WIDTH: usize = 4;
    pub const C1_RGB_A_MASK: u64 = 0xF;

    /// C1_RGB_A
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c1_rgb_a(&self) -> c1_rgb_a::CcSourceE {
        let val = (self.0 >> Self::C1_RGB_A_OFFSET) & Self::C1_RGB_A_MASK;
        c1_rgb_a::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C1_RGB_A
    #[inline(always)]
    pub fn set_c1_rgb_a(&mut self, val: c1_rgb_a::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C1_RGB_A_MASK << Self::C1_RGB_A_OFFSET))
            | ((val & Self::C1_RGB_A_MASK) << Self::C1_RGB_A_OFFSET);
    }

    pub const C1_RGB_B_OFFSET: usize = 36;
    pub const C1_RGB_B_WIDTH: usize = 4;
    pub const C1_RGB_B_MASK: u64 = 0xF;

    /// C1_RGB_B
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c1_rgb_b(&self) -> c1_rgb_b::CcSourceE {
        let val = (self.0 >> Self::C1_RGB_B_OFFSET) & Self::C1_RGB_B_MASK;
        c1_rgb_b::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C1_RGB_B
    #[inline(always)]
    pub fn set_c1_rgb_b(&mut self, val: c1_rgb_b::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C1_RGB_B_MASK << Self::C1_RGB_B_OFFSET))
            | ((val & Self::C1_RGB_B_MASK) << Self::C1_RGB_B_OFFSET);
    }

    pub const C1_RGB_C_OFFSET: usize = 40;
    pub const C1_RGB_C_WIDTH: usize = 4;
    pub const C1_RGB_C_MASK: u64 = 0xF;

    /// C1_RGB_C
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c1_rgb_c(&self) -> c1_rgb_c::CcRgbCSourceE {
        let val = (self.0 >> Self::C1_RGB_C_OFFSET) & Self::C1_RGB_C_MASK;
        c1_rgb_c::CcRgbCSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C1_RGB_C
    #[inline(always)]
    pub fn set_c1_rgb_c(&mut self, val: c1_rgb_c::CcRgbCSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C1_RGB_C_MASK << Self::C1_RGB_C_OFFSET))
            | ((val & Self::C1_RGB_C_MASK) << Self::C1_RGB_C_OFFSET);
    }

    pub const C1_RGB_D_OFFSET: usize = 44;
    pub const C1_RGB_D_WIDTH: usize = 4;
    pub const C1_RGB_D_MASK: u64 = 0xF;

    /// C1_RGB_D
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c1_rgb_d(&self) -> c1_rgb_d::CcSourceE {
        let val = (self.0 >> Self::C1_RGB_D_OFFSET) & Self::C1_RGB_D_MASK;
        c1_rgb_d::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C1_RGB_D
    #[inline(always)]
    pub fn set_c1_rgb_d(&mut self, val: c1_rgb_d::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C1_RGB_D_MASK << Self::C1_RGB_D_OFFSET))
            | ((val & Self::C1_RGB_D_MASK) << Self::C1_RGB_D_OFFSET);
    }

    pub const C1_ALPHA_A_OFFSET: usize = 48;
    pub const C1_ALPHA_A_WIDTH: usize = 4;
    pub const C1_ALPHA_A_MASK: u64 = 0xF;

    /// C1_ALPHA_A
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c1_alpha_a(&self) -> c1_alpha_a::CcSourceE {
        let val = (self.0 >> Self::C1_ALPHA_A_OFFSET) & Self::C1_ALPHA_A_MASK;
        c1_alpha_a::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C1_ALPHA_A
    #[inline(always)]
    pub fn set_c1_alpha_a(&mut self, val: c1_alpha_a::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C1_ALPHA_A_MASK << Self::C1_ALPHA_A_OFFSET))
            | ((val & Self::C1_ALPHA_A_MASK) << Self::C1_ALPHA_A_OFFSET);
    }

    pub const C1_ALPHA_B_OFFSET: usize = 52;
    pub const C1_ALPHA_B_WIDTH: usize = 4;
    pub const C1_ALPHA_B_MASK: u64 = 0xF;

    /// C1_ALPHA_B
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c1_alpha_b(&self) -> c1_alpha_b::CcSourceE {
        let val = (self.0 >> Self::C1_ALPHA_B_OFFSET) & Self::C1_ALPHA_B_MASK;
        c1_alpha_b::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C1_ALPHA_B
    #[inline(always)]
    pub fn set_c1_alpha_b(&mut self, val: c1_alpha_b::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C1_ALPHA_B_MASK << Self::C1_ALPHA_B_OFFSET))
            | ((val & Self::C1_ALPHA_B_MASK) << Self::C1_ALPHA_B_OFFSET);
    }

    pub const C1_ALPHA_C_OFFSET: usize = 56;
    pub const C1_ALPHA_C_WIDTH: usize = 4;
    pub const C1_ALPHA_C_MASK: u64 = 0xF;

    /// C1_ALPHA_C
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c1_alpha_c(&self) -> c1_alpha_c::CcSourceE {
        let val = (self.0 >> Self::C1_ALPHA_C_OFFSET) & Self::C1_ALPHA_C_MASK;
        c1_alpha_c::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C1_ALPHA_C
    #[inline(always)]
    pub fn set_c1_alpha_c(&mut self, val: c1_alpha_c::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C1_ALPHA_C_MASK << Self::C1_ALPHA_C_OFFSET))
            | ((val & Self::C1_ALPHA_C_MASK) << Self::C1_ALPHA_C_OFFSET);
    }

    pub const C1_ALPHA_D_OFFSET: usize = 60;
    pub const C1_ALPHA_D_WIDTH: usize = 4;
    pub const C1_ALPHA_D_MASK: u64 = 0xF;

    /// C1_ALPHA_D
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c1_alpha_d(&self) -> c1_alpha_d::CcSourceE {
        let val = (self.0 >> Self::C1_ALPHA_D_OFFSET) & Self::C1_ALPHA_D_MASK;
        c1_alpha_d::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C1_ALPHA_D
    #[inline(always)]
    pub fn set_c1_alpha_d(&mut self, val: c1_alpha_d::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C1_ALPHA_D_MASK << Self::C1_ALPHA_D_OFFSET))
            | ((val & Self::C1_ALPHA_D_MASK) << Self::C1_ALPHA_D_OFFSET);
    }
}

impl core::fmt::Debug for CcModeReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("CcModeReg")
            .field("c0_rgb_a", &self.c0_rgb_a())
            .field("c0_rgb_b", &self.c0_rgb_b())
            .field("c0_rgb_c", &self.c0_rgb_c())
            .field("c0_rgb_d", &self.c0_rgb_d())
            .field("c0_alpha_a", &self.c0_alpha_a())
            .field("c0_alpha_b", &self.c0_alpha_b())
            .field("c0_alpha_c", &self.c0_alpha_c())
            .field("c0_alpha_d", &self.c0_alpha_d())
            .field("c1_rgb_a", &self.c1_rgb_a())
            .field("c1_rgb_b", &self.c1_rgb_b())
            .field("c1_rgb_c", &self.c1_rgb_c())
            .field("c1_rgb_d", &self.c1_rgb_d())
            .field("c1_alpha_a", &self.c1_alpha_a())
            .field("c1_alpha_b", &self.c1_alpha_b())
            .field("c1_alpha_c", &self.c1_alpha_c())
            .field("c1_alpha_d", &self.c1_alpha_d())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = CcModeReg::default();
        assert_eq!(reg.c0_rgb_a(), c0_rgb_a::CcSourceE::CcCombined);
        assert_eq!(reg.c0_rgb_b(), c0_rgb_b::CcSourceE::CcCombined);
        assert_eq!(reg.c0_rgb_c(), c0_rgb_c::CcRgbCSourceE::CcCCombined);
        assert_eq!(reg.c0_rgb_d(), c0_rgb_d::CcSourceE::CcCombined);
        assert_eq!(reg.c0_alpha_a(), c0_alpha_a::CcSourceE::CcCombined);
        assert_eq!(reg.c0_alpha_b(), c0_alpha_b::CcSourceE::CcCombined);
        assert_eq!(reg.c0_alpha_c(), c0_alpha_c::CcSourceE::CcCombined);
        assert_eq!(reg.c0_alpha_d(), c0_alpha_d::CcSourceE::CcCombined);
        assert_eq!(reg.c1_rgb_a(), c1_rgb_a::CcSourceE::CcCombined);
        assert_eq!(reg.c1_rgb_b(), c1_rgb_b::CcSourceE::CcCombined);
        assert_eq!(reg.c1_rgb_c(), c1_rgb_c::CcRgbCSourceE::CcCCombined);
        assert_eq!(reg.c1_rgb_d(), c1_rgb_d::CcSourceE::CcCombined);
        assert_eq!(reg.c1_alpha_a(), c1_alpha_a::CcSourceE::CcCombined);
        assert_eq!(reg.c1_alpha_b(), c1_alpha_b::CcSourceE::CcCombined);
        assert_eq!(reg.c1_alpha_c(), c1_alpha_c::CcSourceE::CcCombined);
        assert_eq!(reg.c1_alpha_d(), c1_alpha_d::CcSourceE::CcCombined);
    }
}
