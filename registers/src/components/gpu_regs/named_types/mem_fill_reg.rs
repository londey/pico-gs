//! Register: MEM_FILL

/// MEM_FILL
///
/// Hardware memory fill (write-triggers-fill).
/// Writes a 16-bit constant value to a contiguous region of SDRAM.
/// FILL_BASE uses the same 512-byte-granularity encoding as
/// COLOR_BASE, Z_BASE, and texture BASE_ADDR.
/// The fill unit generates sequential SDRAM burst writes for
/// maximum throughput.  Blocks the GPU pipeline until complete;
/// the SPI command FIFO continues accepting commands.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct MemFillReg(u64);

unsafe impl Send for MemFillReg {}
unsafe impl Sync for MemFillReg {}

impl core::default::Default for MemFillReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for MemFillReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl MemFillReg {
    pub const FILL_BASE_OFFSET: usize = 0;
    pub const FILL_BASE_WIDTH: usize = 16;
    pub const FILL_BASE_MASK: u64 = 0xFFFF;

    /// FILL_BASE
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn fill_base(&self) -> u16 {
        let val = (self.0 >> Self::FILL_BASE_OFFSET) & Self::FILL_BASE_MASK;
        val as u16
    }

    /// FILL_BASE
    #[inline(always)]
    pub fn set_fill_base(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::FILL_BASE_MASK << Self::FILL_BASE_OFFSET))
            | ((val & Self::FILL_BASE_MASK) << Self::FILL_BASE_OFFSET);
    }

    pub const FILL_VALUE_OFFSET: usize = 16;
    pub const FILL_VALUE_WIDTH: usize = 16;
    pub const FILL_VALUE_MASK: u64 = 0xFFFF;

    /// FILL_VALUE
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn fill_value(&self) -> u16 {
        let val = (self.0 >> Self::FILL_VALUE_OFFSET) & Self::FILL_VALUE_MASK;
        val as u16
    }

    /// FILL_VALUE
    #[inline(always)]
    pub fn set_fill_value(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::FILL_VALUE_MASK << Self::FILL_VALUE_OFFSET))
            | ((val & Self::FILL_VALUE_MASK) << Self::FILL_VALUE_OFFSET);
    }

    pub const FILL_COUNT_OFFSET: usize = 32;
    pub const FILL_COUNT_WIDTH: usize = 20;
    pub const FILL_COUNT_MASK: u64 = 0xF_FFFF;

    /// FILL_COUNT
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn fill_count(&self) -> u32 {
        let val = (self.0 >> Self::FILL_COUNT_OFFSET) & Self::FILL_COUNT_MASK;
        val as u32
    }

    /// FILL_COUNT
    #[inline(always)]
    pub fn set_fill_count(&mut self, val: u32) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::FILL_COUNT_MASK << Self::FILL_COUNT_OFFSET))
            | ((val & Self::FILL_COUNT_MASK) << Self::FILL_COUNT_OFFSET);
    }

    pub const RSVD_OFFSET: usize = 52;
    pub const RSVD_WIDTH: usize = 12;
    pub const RSVD_MASK: u64 = 0xFFF;

    /// RSVD
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn rsvd(&self) -> u16 {
        let val = (self.0 >> Self::RSVD_OFFSET) & Self::RSVD_MASK;
        val as u16
    }

    /// RSVD
    #[inline(always)]
    pub fn set_rsvd(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::RSVD_MASK << Self::RSVD_OFFSET))
            | ((val & Self::RSVD_MASK) << Self::RSVD_OFFSET);
    }
}

impl core::fmt::Debug for MemFillReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("MemFillReg")
            .field("fill_base", &self.fill_base())
            .field("fill_value", &self.fill_value())
            .field("fill_count", &self.fill_count())
            .field("rsvd", &self.rsvd())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = MemFillReg::default();
        assert_eq!(reg.fill_base(), 0);
        assert_eq!(reg.fill_value(), 0);
        assert_eq!(reg.fill_count(), 0);
        assert_eq!(reg.rsvd(), 0);
    }
}
