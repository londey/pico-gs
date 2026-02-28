//! Register: UV0_UV1

/// UV0_UV1
///
/// Texture units 0+1 UV coordinates (Q4.12 fixed-point, range +/-8.0)
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct Uv0Uv1Reg(u64);

unsafe impl Send for Uv0Uv1Reg {}
unsafe impl Sync for Uv0Uv1Reg {}

impl core::default::Default for Uv0Uv1Reg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for Uv0Uv1Reg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl Uv0Uv1Reg {
    pub const UV0_UQ_OFFSET: usize = 0;
    pub const UV0_UQ_WIDTH: usize = 16;
    pub const UV0_UQ_MASK: u64 = 0xFFFF;

    /// UV0_UQ
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn uv0_uq(&self) -> u16 {
        let val = (self.0 >> Self::UV0_UQ_OFFSET) & Self::UV0_UQ_MASK;
        val as u16
    }

    /// UV0_UQ
    #[inline(always)]
    pub fn set_uv0_uq(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::UV0_UQ_MASK << Self::UV0_UQ_OFFSET))
            | ((val & Self::UV0_UQ_MASK) << Self::UV0_UQ_OFFSET);
    }

    pub const UV0_VQ_OFFSET: usize = 16;
    pub const UV0_VQ_WIDTH: usize = 16;
    pub const UV0_VQ_MASK: u64 = 0xFFFF;

    /// UV0_VQ
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn uv0_vq(&self) -> u16 {
        let val = (self.0 >> Self::UV0_VQ_OFFSET) & Self::UV0_VQ_MASK;
        val as u16
    }

    /// UV0_VQ
    #[inline(always)]
    pub fn set_uv0_vq(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::UV0_VQ_MASK << Self::UV0_VQ_OFFSET))
            | ((val & Self::UV0_VQ_MASK) << Self::UV0_VQ_OFFSET);
    }

    pub const UV1_UQ_OFFSET: usize = 32;
    pub const UV1_UQ_WIDTH: usize = 16;
    pub const UV1_UQ_MASK: u64 = 0xFFFF;

    /// UV1_UQ
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn uv1_uq(&self) -> u16 {
        let val = (self.0 >> Self::UV1_UQ_OFFSET) & Self::UV1_UQ_MASK;
        val as u16
    }

    /// UV1_UQ
    #[inline(always)]
    pub fn set_uv1_uq(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::UV1_UQ_MASK << Self::UV1_UQ_OFFSET))
            | ((val & Self::UV1_UQ_MASK) << Self::UV1_UQ_OFFSET);
    }

    pub const UV1_VQ_OFFSET: usize = 48;
    pub const UV1_VQ_WIDTH: usize = 16;
    pub const UV1_VQ_MASK: u64 = 0xFFFF;

    /// UV1_VQ
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn uv1_vq(&self) -> u16 {
        let val = (self.0 >> Self::UV1_VQ_OFFSET) & Self::UV1_VQ_MASK;
        val as u16
    }

    /// UV1_VQ
    #[inline(always)]
    pub fn set_uv1_vq(&mut self, val: u16) {
        let val = val as u64;
        self.0 = (self.0 & !(Self::UV1_VQ_MASK << Self::UV1_VQ_OFFSET))
            | ((val & Self::UV1_VQ_MASK) << Self::UV1_VQ_OFFSET);
    }
}

impl core::fmt::Debug for Uv0Uv1Reg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("Uv0Uv1Reg")
            .field("uv0_uq", &self.uv0_uq())
            .field("uv0_vq", &self.uv0_vq())
            .field("uv1_uq", &self.uv1_uq())
            .field("uv1_vq", &self.uv1_vq())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = Uv0Uv1Reg::default();
        assert_eq!(reg.uv0_uq(), 0);
        assert_eq!(reg.uv0_vq(), 0);
        assert_eq!(reg.uv1_uq(), 0);
        assert_eq!(reg.uv1_vq(), 0);
    }
}
