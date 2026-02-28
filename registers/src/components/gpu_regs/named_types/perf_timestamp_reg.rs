//! Register: PERF_TIMESTAMP

/// PERF_TIMESTAMP
///
/// Command-stream timestamp marker.
/// Write: DATA[22:0] = 23-bit SDRAM word address (32-bit word
/// granularity, 32 MiB addressable).  When this command reaches
/// the front of the command FIFO, the GPU captures the current
/// frame-relative cycle counter (32-bit unsigned saturating,
/// clk_core, resets to 0 on vsync rising edge) and writes it
/// as a 32-bit word to the specified SDRAM address via the
/// memory arbiter.
/// Read: returns the live (instantaneous) cycle counter in
/// bits [31:0], zero-extended to 64 bits.  Not FIFO-ordered.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct PerfTimestampReg(u64);

unsafe impl Send for PerfTimestampReg {}
unsafe impl Sync for PerfTimestampReg {}

impl core::default::Default for PerfTimestampReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for PerfTimestampReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl PerfTimestampReg {
    pub const SDRAM_ADDR_OFFSET: usize = 0;
    pub const SDRAM_ADDR_WIDTH: usize = 23;
    pub const SDRAM_ADDR_MASK: u64 = 0x7F_FFFF;

    /// SDRAM_ADDR
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn sdram_addr(&self) -> u32 {
        let val = (self.0 >> Self::SDRAM_ADDR_OFFSET) & Self::SDRAM_ADDR_MASK;
        val as u32
    }

    /// SDRAM_ADDR
    #[inline(always)]
    pub fn set_sdram_addr(&mut self, val: u32) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::SDRAM_ADDR_MASK << Self::SDRAM_ADDR_OFFSET))
            | ((val & Self::SDRAM_ADDR_MASK) << Self::SDRAM_ADDR_OFFSET);
    }

    pub const RSVD_OFFSET: usize = 23;
    pub const RSVD_WIDTH: usize = 41;
    pub const RSVD_MASK: u64 = 0x1FF_FFFF_FFFF;

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

impl core::fmt::Debug for PerfTimestampReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("PerfTimestampReg")
            .field("sdram_addr", &self.sdram_addr())
            .field("rsvd", &self.rsvd())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = PerfTimestampReg::default();
        assert_eq!(reg.sdram_addr(), 0);
        assert_eq!(reg.rsvd(), 0);
    }
}
