//! Register: FB_CACHE_CTRL

#[allow(unused_imports)]
use super::_root; // alias to root module of generated code

/// FB_CACHE_CTRL
///
/// Color-buffer tile cache control (write-triggers-blocking).
/// Software-controlled flush and invalidate triggers for the
/// color-buffer tile cache (UNIT-013).  Writes block the SPI
/// command stream until the requested operation completes,
/// matching the MEM_FILL (0x44) and FB_DISPLAY_SYNC (0x47)
/// blocking semantics.
/// FLUSH_TRIGGER (bit 0): Self-clearing flush trigger.  When
/// written as 1, writes back all dirty 4x4 tiles to SDRAM via
/// 16-word burst writes on UNIT-007 port 1.  Lines remain
/// valid after flush; dirty bits are cleared.  Hardware
/// clears this bit and asserts flush_done when complete.
/// INVALIDATE_TRIGGER (bit 1): Self-clearing invalidate
/// trigger.  When written as 1, drops all valid and dirty
/// bits in the cache and resets the per-tile uninitialized
/// flag array (16,384 cycles sweep).  Lines that were dirty
/// are discarded without writeback.  After the sweep,
/// subsequent first-touch writes lazy-fill with zeros rather
/// than reading SDRAM (REQ-005.08).  Hardware clears this
/// bit and asserts invalidate_done when complete.
/// Writing both bits simultaneously is undefined; driver
/// software must issue them as separate writes.  See INT-010
/// section 0x45.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct FbCacheCtrlReg(u64);

unsafe impl Send for FbCacheCtrlReg {}
unsafe impl Sync for FbCacheCtrlReg {}

impl core::default::Default for FbCacheCtrlReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl peakrdl_rust::reg::Register for FbCacheCtrlReg {
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

impl FbCacheCtrlReg {
    pub const FLUSH_TRIGGER_OFFSET: usize = 0;
    pub const FLUSH_TRIGGER_WIDTH: usize = 1;
    pub const FLUSH_TRIGGER_MASK: u64 = 0x1;

    /// FLUSH_TRIGGER
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn flush_trigger(&self) -> bool {
        let val = (self.0 >> Self::FLUSH_TRIGGER_OFFSET) & Self::FLUSH_TRIGGER_MASK;
        val != 0
    }

    /// FLUSH_TRIGGER
    #[inline(always)]
    pub fn set_flush_trigger(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::FLUSH_TRIGGER_MASK << Self::FLUSH_TRIGGER_OFFSET))
            | ((val & Self::FLUSH_TRIGGER_MASK) << Self::FLUSH_TRIGGER_OFFSET);
    }

    pub const INVALIDATE_TRIGGER_OFFSET: usize = 1;
    pub const INVALIDATE_TRIGGER_WIDTH: usize = 1;
    pub const INVALIDATE_TRIGGER_MASK: u64 = 0x1;

    /// INVALIDATE_TRIGGER
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn invalidate_trigger(&self) -> bool {
        let val = (self.0 >> Self::INVALIDATE_TRIGGER_OFFSET) & Self::INVALIDATE_TRIGGER_MASK;
        val != 0
    }

    /// INVALIDATE_TRIGGER
    #[inline(always)]
    pub fn set_invalidate_trigger(&mut self, val: bool) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::INVALIDATE_TRIGGER_MASK << Self::INVALIDATE_TRIGGER_OFFSET))
            | ((val & Self::INVALIDATE_TRIGGER_MASK) << Self::INVALIDATE_TRIGGER_OFFSET);
    }

    pub const RSVD_OFFSET: usize = 2;
    pub const RSVD_WIDTH: usize = 62;
    pub const RSVD_MASK: u64 = 0x3FFF_FFFF_FFFF_FFFF;

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

impl core::fmt::Debug for FbCacheCtrlReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("FbCacheCtrlReg")
            .field("flush_trigger", &self.flush_trigger())
            .field("invalidate_trigger", &self.invalidate_trigger())
            .field("rsvd", &self.rsvd())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = FbCacheCtrlReg::default();
        assert_eq!(reg.flush_trigger(), false);
        assert_eq!(reg.invalidate_trigger(), false);
        assert_eq!(reg.rsvd(), 0);
    }
}
