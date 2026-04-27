//! Register: TEXn_CFG

#[allow(unused_imports)]
use super::_root; // alias to root module of generated code

// Instances of named component types
pub use _root::components::tex_filter_e as filter;
pub use _root::components::tex_format_e as format;
pub use _root::components::wrap_mode_e as u_wrap;
pub use _root::components::wrap_mode_e as v_wrap;

/// TEXn_CFG
///
/// Texture sampler configuration (single 64-bit register per unit).
/// FORMAT is fixed at INDEXED8_2X2: each apparent texel is an
/// 8-bit palette index resolved through the active palette slot
/// (selected by PALETTE_IDX) into a UQ1.8 RGBA quadrant color.
/// BASE_ADDR is a 16-bit value multiplied by 512 to form the
/// SDRAM byte address of the index array (512-byte granularity,
/// 32 MiB addressable).  Palette slot contents are loaded
/// independently via PALETTE0/PALETTE1 (0x12/0x13).
/// Octahedral wrap mode implements coupled diagonal mirroring:
/// crossing one axis edge flips the other axis coordinate.
/// Any write to this register invalidates the index cache for
/// the corresponding texture unit; palette slot contents are
/// not affected.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct TexCfgReg(u64);

unsafe impl Send for TexCfgReg {}
unsafe impl Sync for TexCfgReg {}

impl core::default::Default for TexCfgReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl peakrdl_rust::reg::Register for TexCfgReg {
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

impl TexCfgReg {
    pub const ENABLE_OFFSET: usize = 0;
    pub const ENABLE_WIDTH: usize = 1;
    pub const ENABLE_MASK: u64 = 0x1;

    /// ENABLE
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn enable(&self) -> bool {
        let val = (self.0 >> Self::ENABLE_OFFSET) & Self::ENABLE_MASK;
        val != 0
    }

    /// ENABLE
    #[inline(always)]
    pub fn set_enable(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::ENABLE_MASK << Self::ENABLE_OFFSET))
            | ((val & Self::ENABLE_MASK) << Self::ENABLE_OFFSET);
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

    pub const FILTER_OFFSET: usize = 2;
    pub const FILTER_WIDTH: usize = 2;
    pub const FILTER_MASK: u64 = 0x3;

    /// FILTER
    #[inline(always)]
    #[allow(clippy::missing_errors_doc)]
    pub fn filter(&self) -> Result<filter::TexFilterE, peakrdl_rust::encode::UnknownVariant<u8>> {
        let val = (self.0 >> Self::FILTER_OFFSET) & Self::FILTER_MASK;
        filter::TexFilterE::from_bits(val as u8)
    }

    /// FILTER
    #[inline(always)]
    pub fn set_filter(&mut self, val: filter::TexFilterE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::FILTER_MASK << Self::FILTER_OFFSET))
            | ((val & Self::FILTER_MASK) << Self::FILTER_OFFSET);
    }

    pub const FORMAT_OFFSET: usize = 4;
    pub const FORMAT_WIDTH: usize = 4;
    pub const FORMAT_MASK: u64 = 0xF;

    /// FORMAT
    #[inline(always)]
    #[allow(clippy::missing_errors_doc)]
    pub fn format(&self) -> Result<format::TexFormatE, peakrdl_rust::encode::UnknownVariant<u8>> {
        let val = (self.0 >> Self::FORMAT_OFFSET) & Self::FORMAT_MASK;
        format::TexFormatE::from_bits(val as u8)
    }

    /// FORMAT
    #[inline(always)]
    pub fn set_format(&mut self, val: format::TexFormatE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::FORMAT_MASK << Self::FORMAT_OFFSET))
            | ((val & Self::FORMAT_MASK) << Self::FORMAT_OFFSET);
    }

    pub const WIDTH_LOG2_OFFSET: usize = 8;
    pub const WIDTH_LOG2_WIDTH: usize = 4;
    pub const WIDTH_LOG2_MASK: u64 = 0xF;

    /// WIDTH_LOG2
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn width_log2(&self) -> u8 {
        let val = (self.0 >> Self::WIDTH_LOG2_OFFSET) & Self::WIDTH_LOG2_MASK;
        val as u8
    }

    /// WIDTH_LOG2
    #[inline(always)]
    pub fn set_width_log2(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::WIDTH_LOG2_MASK << Self::WIDTH_LOG2_OFFSET))
            | ((val & Self::WIDTH_LOG2_MASK) << Self::WIDTH_LOG2_OFFSET);
    }

    pub const HEIGHT_LOG2_OFFSET: usize = 12;
    pub const HEIGHT_LOG2_WIDTH: usize = 4;
    pub const HEIGHT_LOG2_MASK: u64 = 0xF;

    /// HEIGHT_LOG2
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn height_log2(&self) -> u8 {
        let val = (self.0 >> Self::HEIGHT_LOG2_OFFSET) & Self::HEIGHT_LOG2_MASK;
        val as u8
    }

    /// HEIGHT_LOG2
    #[inline(always)]
    pub fn set_height_log2(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::HEIGHT_LOG2_MASK << Self::HEIGHT_LOG2_OFFSET))
            | ((val & Self::HEIGHT_LOG2_MASK) << Self::HEIGHT_LOG2_OFFSET);
    }

    pub const U_WRAP_OFFSET: usize = 16;
    pub const U_WRAP_WIDTH: usize = 2;
    pub const U_WRAP_MASK: u64 = 0x3;

    /// U_WRAP
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn u_wrap(&self) -> u_wrap::WrapModeE {
        let val = (self.0 >> Self::U_WRAP_OFFSET) & Self::U_WRAP_MASK;
        u_wrap::WrapModeE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// U_WRAP
    #[inline(always)]
    pub fn set_u_wrap(&mut self, val: u_wrap::WrapModeE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::U_WRAP_MASK << Self::U_WRAP_OFFSET))
            | ((val & Self::U_WRAP_MASK) << Self::U_WRAP_OFFSET);
    }

    pub const V_WRAP_OFFSET: usize = 18;
    pub const V_WRAP_WIDTH: usize = 2;
    pub const V_WRAP_MASK: u64 = 0x3;

    /// V_WRAP
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn v_wrap(&self) -> v_wrap::WrapModeE {
        let val = (self.0 >> Self::V_WRAP_OFFSET) & Self::V_WRAP_MASK;
        v_wrap::WrapModeE::from_bits(val as u8)
            .expect("All possible field values represented by enum")
    }

    /// V_WRAP
    #[inline(always)]
    pub fn set_v_wrap(&mut self, val: v_wrap::WrapModeE) {
        let val = val.bits() as u64;
        self.0 = (self.0 & !(Self::V_WRAP_MASK << Self::V_WRAP_OFFSET))
            | ((val & Self::V_WRAP_MASK) << Self::V_WRAP_OFFSET);
    }

    pub const PALETTE_IDX_OFFSET: usize = 24;
    pub const PALETTE_IDX_WIDTH: usize = 1;
    pub const PALETTE_IDX_MASK: u64 = 0x1;

    /// PALETTE_IDX
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn palette_idx(&self) -> bool {
        let val = (self.0 >> Self::PALETTE_IDX_OFFSET) & Self::PALETTE_IDX_MASK;
        val != 0
    }

    /// PALETTE_IDX
    #[inline(always)]
    pub fn set_palette_idx(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::PALETTE_IDX_MASK << Self::PALETTE_IDX_OFFSET))
            | ((val & Self::PALETTE_IDX_MASK) << Self::PALETTE_IDX_OFFSET);
    }

    pub const RSVD_MID_OFFSET: usize = 25;
    pub const RSVD_MID_WIDTH: usize = 7;
    pub const RSVD_MID_MASK: u64 = 0x7F;

    /// RSVD_MID
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn rsvd_mid(&self) -> u8 {
        let val = (self.0 >> Self::RSVD_MID_OFFSET) & Self::RSVD_MID_MASK;
        val as u8
    }

    /// RSVD_MID
    #[inline(always)]
    pub fn set_rsvd_mid(&mut self, val: u8) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::RSVD_MID_MASK << Self::RSVD_MID_OFFSET))
            | ((val & Self::RSVD_MID_MASK) << Self::RSVD_MID_OFFSET);
    }

    pub const BASE_ADDR_OFFSET: usize = 32;
    pub const BASE_ADDR_WIDTH: usize = 16;
    pub const BASE_ADDR_MASK: u64 = 0xFFFF;

    /// BASE_ADDR
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn base_addr(&self) -> u16 {
        let val = (self.0 >> Self::BASE_ADDR_OFFSET) & Self::BASE_ADDR_MASK;
        val as u16
    }

    /// BASE_ADDR
    #[inline(always)]
    pub fn set_base_addr(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::BASE_ADDR_MASK << Self::BASE_ADDR_OFFSET))
            | ((val & Self::BASE_ADDR_MASK) << Self::BASE_ADDR_OFFSET);
    }

    pub const RSVD_HI_OFFSET: usize = 48;
    pub const RSVD_HI_WIDTH: usize = 16;
    pub const RSVD_HI_MASK: u64 = 0xFFFF;

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

impl core::fmt::Debug for TexCfgReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("TexCfgReg")
            .field("enable", &self.enable())
            .field("rsvd_1", &self.rsvd_1())
            .field("filter", &self.filter())
            .field("format", &self.format())
            .field("width_log2", &self.width_log2())
            .field("height_log2", &self.height_log2())
            .field("u_wrap", &self.u_wrap())
            .field("v_wrap", &self.v_wrap())
            .field("palette_idx", &self.palette_idx())
            .field("rsvd_mid", &self.rsvd_mid())
            .field("base_addr", &self.base_addr())
            .field("rsvd_hi", &self.rsvd_hi())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = TexCfgReg::default();
        assert_eq!(reg.enable(), false);
        assert_eq!(reg.rsvd_1(), false);
        assert_eq!(reg.filter(), Ok(filter::TexFilterE::Nearest));
        assert_eq!(reg.format(), Ok(format::TexFormatE::Indexed82x2));
        assert_eq!(reg.width_log2(), 0);
        assert_eq!(reg.height_log2(), 0);
        assert_eq!(reg.u_wrap(), u_wrap::WrapModeE::Repeat);
        assert_eq!(reg.v_wrap(), v_wrap::WrapModeE::Repeat);
        assert_eq!(reg.palette_idx(), false);
        assert_eq!(reg.rsvd_mid(), 0);
        assert_eq!(reg.base_addr(), 0);
        assert_eq!(reg.rsvd_hi(), 0);
    }
}
