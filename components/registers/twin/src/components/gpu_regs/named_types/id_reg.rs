//! Register: ID

/// ID
///
/// GPU identification (read-only)
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct IdReg(u64);

unsafe impl Send for IdReg {}
unsafe impl Sync for IdReg {}

impl core::default::Default for IdReg {
    fn default() -> Self {
        Self(0xA00_6702)
    }
}

impl crate::reg::Register for IdReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl IdReg {
    pub const DEVICE_ID_OFFSET: usize = 0;
    pub const DEVICE_ID_WIDTH: usize = 16;
    pub const DEVICE_ID_MASK: u64 = 0xFFFF;

    /// DEVICE_ID
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn device_id(&self) -> u16 {
        let val = (self.0 >> Self::DEVICE_ID_OFFSET) & Self::DEVICE_ID_MASK;
        val as u16
    }

    pub const VERSION_OFFSET: usize = 16;
    pub const VERSION_WIDTH: usize = 16;
    pub const VERSION_MASK: u64 = 0xFFFF;

    /// VERSION
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn version(&self) -> u16 {
        let val = (self.0 >> Self::VERSION_OFFSET) & Self::VERSION_MASK;
        val as u16
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
}

impl core::fmt::Debug for IdReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("IdReg")
            .field("device_id", &self.device_id())
            .field("version", &self.version())
            .field("rsvd", &self.rsvd())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = IdReg::default();
        assert_eq!(reg.device_id(), 26370);
        assert_eq!(reg.version(), 2560);
        assert_eq!(reg.rsvd(), 0);
    }
}
