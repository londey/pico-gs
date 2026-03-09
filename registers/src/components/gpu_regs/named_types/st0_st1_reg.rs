//! Register: ST0_ST1

/// ST0_ST1
///
/// Texture units 0+1 pre-divided coordinates S=U/W, T=V/W (Q4.12 fixed-point, range +/-8.0).
/// GPU interpolates S, T, Q linearly, then computes true U=S/Q, V=T/Q per pixel.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct St0St1Reg(u64);

unsafe impl Send for St0St1Reg {}
unsafe impl Sync for St0St1Reg {}

impl core::default::Default for St0St1Reg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for St0St1Reg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl St0St1Reg {
    pub const S0_OFFSET: usize = 0;
    pub const S0_WIDTH: usize = 16;
    pub const S0_MASK: u64 = 0xFFFF;

    /// S0
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn s0(&self) -> u16 {
        let val = (self.0 >> Self::S0_OFFSET) & Self::S0_MASK;
        val as u16
    }

    /// S0
    #[inline(always)]
    pub fn set_s0(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::S0_MASK << Self::S0_OFFSET))
            | ((val & Self::S0_MASK) << Self::S0_OFFSET);
    }

    pub const T0_OFFSET: usize = 16;
    pub const T0_WIDTH: usize = 16;
    pub const T0_MASK: u64 = 0xFFFF;

    /// T0
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn t0(&self) -> u16 {
        let val = (self.0 >> Self::T0_OFFSET) & Self::T0_MASK;
        val as u16
    }

    /// T0
    #[inline(always)]
    pub fn set_t0(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::T0_MASK << Self::T0_OFFSET))
            | ((val & Self::T0_MASK) << Self::T0_OFFSET);
    }

    pub const S1_OFFSET: usize = 32;
    pub const S1_WIDTH: usize = 16;
    pub const S1_MASK: u64 = 0xFFFF;

    /// S1
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn s1(&self) -> u16 {
        let val = (self.0 >> Self::S1_OFFSET) & Self::S1_MASK;
        val as u16
    }

    /// S1
    #[inline(always)]
    pub fn set_s1(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::S1_MASK << Self::S1_OFFSET))
            | ((val & Self::S1_MASK) << Self::S1_OFFSET);
    }

    pub const T1_OFFSET: usize = 48;
    pub const T1_WIDTH: usize = 16;
    pub const T1_MASK: u64 = 0xFFFF;

    /// T1
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn t1(&self) -> u16 {
        let val = (self.0 >> Self::T1_OFFSET) & Self::T1_MASK;
        val as u16
    }

    /// T1
    #[inline(always)]
    pub fn set_t1(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::T1_MASK << Self::T1_OFFSET))
            | ((val & Self::T1_MASK) << Self::T1_OFFSET);
    }
}

impl core::fmt::Debug for St0St1Reg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("St0St1Reg")
            .field("s0", &self.s0())
            .field("t0", &self.t0())
            .field("s1", &self.s1())
            .field("t1", &self.t1())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = St0St1Reg::default();
        assert_eq!(reg.s0(), 0);
        assert_eq!(reg.t0(), 0);
        assert_eq!(reg.s1(), 0);
        assert_eq!(reg.t1(), 0);
    }
}
