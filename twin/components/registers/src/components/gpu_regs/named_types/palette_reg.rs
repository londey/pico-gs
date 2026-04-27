//! Register: PALETTEn

#[allow(unused_imports)]
use super::_root; // alias to root module of generated code

/// PALETTEn
///
/// Palette slot N load control.
/// Writing this register with LOAD_TRIGGER=1 starts an SDRAM
/// burst load of 4096 bytes (256 entries x 4 RGBA8888 quadrant
/// colors) from byte address BASE_ADDR x 512 into the selected
/// on-chip palette slot.  Each UNORM8 channel is promoted to
/// UQ1.8 inline (UQ1.8 = UNORM8 << 1).
/// LOAD_TRIGGER is a self-clearing pulse — hardware clears it
/// when the load completes; reads return 0 when idle.  There
/// is no hardware status flag indicating completion; firmware
/// must serialize palette loads before dependent triangle
/// submissions or otherwise account for the load latency.
/// Palette slots are isolated: writing PALETTE0 does not
/// disturb slot 1 and vice versa.  Index-cache fills preempt
/// pending palette loads on the shared SDRAM Port 3 arbiter.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct PaletteReg(u64);

unsafe impl Send for PaletteReg {}
unsafe impl Sync for PaletteReg {}

impl core::default::Default for PaletteReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl peakrdl_rust::reg::Register for PaletteReg {
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

impl PaletteReg {
    pub const BASE_ADDR_OFFSET: usize = 0;
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

    pub const LOAD_TRIGGER_OFFSET: usize = 16;
    pub const LOAD_TRIGGER_WIDTH: usize = 1;
    pub const LOAD_TRIGGER_MASK: u64 = 0x1;

    /// LOAD_TRIGGER
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn load_trigger(&self) -> bool {
        let val = (self.0 >> Self::LOAD_TRIGGER_OFFSET) & Self::LOAD_TRIGGER_MASK;
        val != 0
    }

    /// LOAD_TRIGGER
    #[inline(always)]
    pub fn set_load_trigger(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::LOAD_TRIGGER_MASK << Self::LOAD_TRIGGER_OFFSET))
            | ((val & Self::LOAD_TRIGGER_MASK) << Self::LOAD_TRIGGER_OFFSET);
    }

    pub const RSVD_OFFSET: usize = 17;
    pub const RSVD_WIDTH: usize = 47;
    pub const RSVD_MASK: u64 = 0x7FFF_FFFF_FFFF;

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

impl core::fmt::Debug for PaletteReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("PaletteReg")
            .field("base_addr", &self.base_addr())
            .field("load_trigger", &self.load_trigger())
            .field("rsvd", &self.rsvd())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = PaletteReg::default();
        assert_eq!(reg.base_addr(), 0);
        assert_eq!(reg.load_trigger(), false);
        assert_eq!(reg.rsvd(), 0);
    }
}
