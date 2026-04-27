//! Register: CC_MODE_2

#[allow(unused_imports)]
use super::_root; // alias to root module of generated code

// Instances of named component types
pub use _root::components::cc_rgb_c_source_e as c2_rgb_c;
pub use _root::components::cc_source_e as c2_rgb_a;
pub use _root::components::cc_source_e as c2_rgb_b;
pub use _root::components::cc_source_e as c2_rgb_d;
pub use _root::components::cc_source_e as c2_alpha_a;
pub use _root::components::cc_source_e as c2_alpha_b;
pub use _root::components::cc_source_e as c2_alpha_c;
pub use _root::components::cc_source_e as c2_alpha_d;

/// CC_MODE_2
///
/// Color combiner pass 2 (blend) mode: equation (A-B)*C+D for the third
/// combiner pass.  Pass 2's COMBINED input is the output of pass 1.
/// The DST_COLOR source (cc_source_e value 9) selects the promoted
/// destination pixel from the color tile buffer.
/// When blending is disabled, configure pass 2 as pass-through:
/// A=COMBINED, B=ZERO, C=ONE, D=ZERO.
/// This register is written separately from CC_MODE because the SPI
/// transport uses 64-bit data width.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct CcMode2Reg(u64);

unsafe impl Send for CcMode2Reg {}
unsafe impl Sync for CcMode2Reg {}

impl core::default::Default for CcMode2Reg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl peakrdl_rust::reg::Register for CcMode2Reg {
    type Regwidth = u64;
    type Accesswidth = u64;
    type Access = peakrdl_rust::access::RW;
    type ByteEndian = peakrdl_rust::endian::LittleEndian;
    type WordEndian = peakrdl_rust::endian::LittleEndian;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl CcMode2Reg {
    pub const C2_RGB_A_OFFSET: usize = 0;
    pub const C2_RGB_A_WIDTH: usize = 4;
    pub const C2_RGB_A_MASK: u64 = 0xF;

    /// C2_RGB_A
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c2_rgb_a(&self) -> c2_rgb_a::CcSourceE {
        let val = (self.0 >> Self::C2_RGB_A_OFFSET) & Self::C2_RGB_A_MASK;
        c2_rgb_a::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C2_RGB_A
    #[inline(always)]
    pub fn set_c2_rgb_a(&mut self, val: c2_rgb_a::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C2_RGB_A_MASK << Self::C2_RGB_A_OFFSET))
            | ((val & Self::C2_RGB_A_MASK) << Self::C2_RGB_A_OFFSET);
    }

    pub const C2_RGB_B_OFFSET: usize = 4;
    pub const C2_RGB_B_WIDTH: usize = 4;
    pub const C2_RGB_B_MASK: u64 = 0xF;

    /// C2_RGB_B
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c2_rgb_b(&self) -> c2_rgb_b::CcSourceE {
        let val = (self.0 >> Self::C2_RGB_B_OFFSET) & Self::C2_RGB_B_MASK;
        c2_rgb_b::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C2_RGB_B
    #[inline(always)]
    pub fn set_c2_rgb_b(&mut self, val: c2_rgb_b::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C2_RGB_B_MASK << Self::C2_RGB_B_OFFSET))
            | ((val & Self::C2_RGB_B_MASK) << Self::C2_RGB_B_OFFSET);
    }

    pub const C2_RGB_C_OFFSET: usize = 8;
    pub const C2_RGB_C_WIDTH: usize = 4;
    pub const C2_RGB_C_MASK: u64 = 0xF;

    /// C2_RGB_C
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c2_rgb_c(&self) -> c2_rgb_c::CcRgbCSourceE {
        let val = (self.0 >> Self::C2_RGB_C_OFFSET) & Self::C2_RGB_C_MASK;
        c2_rgb_c::CcRgbCSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C2_RGB_C
    #[inline(always)]
    pub fn set_c2_rgb_c(&mut self, val: c2_rgb_c::CcRgbCSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C2_RGB_C_MASK << Self::C2_RGB_C_OFFSET))
            | ((val & Self::C2_RGB_C_MASK) << Self::C2_RGB_C_OFFSET);
    }

    pub const C2_RGB_D_OFFSET: usize = 12;
    pub const C2_RGB_D_WIDTH: usize = 4;
    pub const C2_RGB_D_MASK: u64 = 0xF;

    /// C2_RGB_D
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c2_rgb_d(&self) -> c2_rgb_d::CcSourceE {
        let val = (self.0 >> Self::C2_RGB_D_OFFSET) & Self::C2_RGB_D_MASK;
        c2_rgb_d::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C2_RGB_D
    #[inline(always)]
    pub fn set_c2_rgb_d(&mut self, val: c2_rgb_d::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C2_RGB_D_MASK << Self::C2_RGB_D_OFFSET))
            | ((val & Self::C2_RGB_D_MASK) << Self::C2_RGB_D_OFFSET);
    }

    pub const C2_ALPHA_A_OFFSET: usize = 16;
    pub const C2_ALPHA_A_WIDTH: usize = 4;
    pub const C2_ALPHA_A_MASK: u64 = 0xF;

    /// C2_ALPHA_A
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c2_alpha_a(&self) -> c2_alpha_a::CcSourceE {
        let val = (self.0 >> Self::C2_ALPHA_A_OFFSET) & Self::C2_ALPHA_A_MASK;
        c2_alpha_a::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C2_ALPHA_A
    #[inline(always)]
    pub fn set_c2_alpha_a(&mut self, val: c2_alpha_a::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C2_ALPHA_A_MASK << Self::C2_ALPHA_A_OFFSET))
            | ((val & Self::C2_ALPHA_A_MASK) << Self::C2_ALPHA_A_OFFSET);
    }

    pub const C2_ALPHA_B_OFFSET: usize = 20;
    pub const C2_ALPHA_B_WIDTH: usize = 4;
    pub const C2_ALPHA_B_MASK: u64 = 0xF;

    /// C2_ALPHA_B
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c2_alpha_b(&self) -> c2_alpha_b::CcSourceE {
        let val = (self.0 >> Self::C2_ALPHA_B_OFFSET) & Self::C2_ALPHA_B_MASK;
        c2_alpha_b::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C2_ALPHA_B
    #[inline(always)]
    pub fn set_c2_alpha_b(&mut self, val: c2_alpha_b::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C2_ALPHA_B_MASK << Self::C2_ALPHA_B_OFFSET))
            | ((val & Self::C2_ALPHA_B_MASK) << Self::C2_ALPHA_B_OFFSET);
    }

    pub const C2_ALPHA_C_OFFSET: usize = 24;
    pub const C2_ALPHA_C_WIDTH: usize = 4;
    pub const C2_ALPHA_C_MASK: u64 = 0xF;

    /// C2_ALPHA_C
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c2_alpha_c(&self) -> c2_alpha_c::CcSourceE {
        let val = (self.0 >> Self::C2_ALPHA_C_OFFSET) & Self::C2_ALPHA_C_MASK;
        c2_alpha_c::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C2_ALPHA_C
    #[inline(always)]
    pub fn set_c2_alpha_c(&mut self, val: c2_alpha_c::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C2_ALPHA_C_MASK << Self::C2_ALPHA_C_OFFSET))
            | ((val & Self::C2_ALPHA_C_MASK) << Self::C2_ALPHA_C_OFFSET);
    }

    pub const C2_ALPHA_D_OFFSET: usize = 28;
    pub const C2_ALPHA_D_WIDTH: usize = 4;
    pub const C2_ALPHA_D_MASK: u64 = 0xF;

    /// C2_ALPHA_D
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn c2_alpha_d(&self) -> c2_alpha_d::CcSourceE {
        let val = (self.0 >> Self::C2_ALPHA_D_OFFSET) & Self::C2_ALPHA_D_MASK;
        c2_alpha_d::CcSourceE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// C2_ALPHA_D
    #[inline(always)]
    pub fn set_c2_alpha_d(&mut self, val: c2_alpha_d::CcSourceE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::C2_ALPHA_D_MASK << Self::C2_ALPHA_D_OFFSET))
            | ((val & Self::C2_ALPHA_D_MASK) << Self::C2_ALPHA_D_OFFSET);
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

impl core::fmt::Debug for CcMode2Reg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("CcMode2Reg")
            .field("c2_rgb_a", &self.c2_rgb_a())
            .field("c2_rgb_b", &self.c2_rgb_b())
            .field("c2_rgb_c", &self.c2_rgb_c())
            .field("c2_rgb_d", &self.c2_rgb_d())
            .field("c2_alpha_a", &self.c2_alpha_a())
            .field("c2_alpha_b", &self.c2_alpha_b())
            .field("c2_alpha_c", &self.c2_alpha_c())
            .field("c2_alpha_d", &self.c2_alpha_d())
            .field("rsvd", &self.rsvd())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = CcMode2Reg::default();
        assert_eq!(reg.c2_rgb_a(), c2_rgb_a::CcSourceE::CcCombined);
        assert_eq!(reg.c2_rgb_b(), c2_rgb_b::CcSourceE::CcCombined);
        assert_eq!(reg.c2_rgb_c(), c2_rgb_c::CcRgbCSourceE::CcCCombined);
        assert_eq!(reg.c2_rgb_d(), c2_rgb_d::CcSourceE::CcCombined);
        assert_eq!(reg.c2_alpha_a(), c2_alpha_a::CcSourceE::CcCombined);
        assert_eq!(reg.c2_alpha_b(), c2_alpha_b::CcSourceE::CcCombined);
        assert_eq!(reg.c2_alpha_c(), c2_alpha_c::CcSourceE::CcCombined);
        assert_eq!(reg.c2_alpha_d(), c2_alpha_d::CcSourceE::CcCombined);
        assert_eq!(reg.rsvd(), 0);
    }
}
