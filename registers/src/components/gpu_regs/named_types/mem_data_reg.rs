//! Register: MEM_DATA

/// MEM_DATA
///
/// Memory data register (bidirectional 64-bit, auto-increments MEM_ADDR by 1).
/// Write: stores DATA[63:0] to SDRAM at MEM_ADDR, then increments.
/// Read: returns prefetched 64-bit SDRAM dword and triggers next prefetch.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct MemDataReg(u64);

unsafe impl Send for MemDataReg {}
unsafe impl Sync for MemDataReg {}

impl core::default::Default for MemDataReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for MemDataReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl MemDataReg {
    pub const DATA_OFFSET: usize = 0;
    pub const DATA_WIDTH: usize = 64;
    pub const DATA_MASK: u64 = 0xFFFF_FFFF_FFFF_FFFF;

    /// DATA
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn data(&self) -> u64 {
        let val = (self.0 >> Self::DATA_OFFSET) & Self::DATA_MASK;
        val
    }

    /// DATA
    #[inline(always)]
    pub fn set_data(&mut self, val: u64) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::DATA_MASK << Self::DATA_OFFSET))
            | ((val & Self::DATA_MASK) << Self::DATA_OFFSET);
    }
}

impl core::fmt::Debug for MemDataReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("MemDataReg")
            .field("data", &self.data())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = MemDataReg::default();
        assert_eq!(reg.data(), 0);
    }
}
