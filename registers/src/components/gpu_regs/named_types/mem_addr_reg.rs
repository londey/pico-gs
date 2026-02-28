//! Register: MEM_ADDR

/// MEM_ADDR
///
/// Memory access dword address pointer (22-bit, addresses 8-byte dwords
/// in 32 MiB SDRAM).  Writing this register sets the SDRAM target
/// address and triggers a read prefetch so that the next SPI read of
/// MEM_DATA can return data immediately.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct MemAddrReg(u64);

unsafe impl Send for MemAddrReg {}
unsafe impl Sync for MemAddrReg {}

impl core::default::Default for MemAddrReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for MemAddrReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl MemAddrReg {
    pub const ADDR_OFFSET: usize = 0;
    pub const ADDR_WIDTH: usize = 22;
    pub const ADDR_MASK: u64 = 0x3F_FFFF;

    /// ADDR
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn addr(&self) -> u32 {
        let val = (self.0 >> Self::ADDR_OFFSET) & Self::ADDR_MASK;
        val as u32
    }

    /// ADDR
    #[inline(always)]
    pub fn set_addr(&mut self, val: u32) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::ADDR_MASK << Self::ADDR_OFFSET))
            | ((val & Self::ADDR_MASK) << Self::ADDR_OFFSET);
    }

    pub const RSVD_OFFSET: usize = 22;
    pub const RSVD_WIDTH: usize = 42;
    pub const RSVD_MASK: u64 = 0x3FF_FFFF_FFFF;

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

impl core::fmt::Debug for MemAddrReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("MemAddrReg")
            .field("addr", &self.addr())
            .field("rsvd", &self.rsvd())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = MemAddrReg::default();
        assert_eq!(reg.addr(), 0);
        assert_eq!(reg.rsvd(), 0);
    }
}
