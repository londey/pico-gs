//! Register: VERTEX

/// VERTEX
///
/// Vertex position + 1/W (write-only trigger).
/// Origin (0,0) is the center of the top-left pixel,
/// X+ right, Y+ down (S12.4). Integer coordinates
/// address pixel centers directly. Coordinates extend
/// beyond the framebuffer for guard-band clipping — the
/// scissor rectangle (FB_CONTROL) defines the visible
/// region; pixels outside are discarded per-fragment.
/// KICK_RECT uses this vertex and the previous NOKICK
/// vertex as opposite corners of an axis-aligned rectangle.
#[repr(transparent)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct VertexReg(u64);

unsafe impl Send for VertexReg {}
unsafe impl Sync for VertexReg {}

impl core::default::Default for VertexReg {
    fn default() -> Self {
        Self(0x0)
    }
}

impl crate::reg::Register for VertexReg {
    type Regwidth = u64;
    type Accesswidth = u64;

    unsafe fn from_raw(val: Self::Regwidth) -> Self {
        Self(val)
    }

    fn to_raw(self) -> Self::Regwidth {
        self.0
    }
}

impl VertexReg {
    pub const X_OFFSET: usize = 0;
    pub const X_WIDTH: usize = 16;
    pub const X_MASK: u64 = 0xFFFF;

    /// X
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn x(&self) -> u16 {
        let val = (self.0 >> Self::X_OFFSET) & Self::X_MASK;
        val as u16
    }

    /// X
    #[inline(always)]
    pub fn set_x(&mut self, val: u16) {
        let val = val as u64;
        self.0 =
            (self.0 & !(Self::X_MASK << Self::X_OFFSET)) | ((val & Self::X_MASK) << Self::X_OFFSET);
    }

    pub const Y_OFFSET: usize = 16;
    pub const Y_WIDTH: usize = 16;
    pub const Y_MASK: u64 = 0xFFFF;

    /// Y
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn y(&self) -> u16 {
        let val = (self.0 >> Self::Y_OFFSET) & Self::Y_MASK;
        val as u16
    }

    /// Y
    #[inline(always)]
    pub fn set_y(&mut self, val: u16) {
        let val = val as u64;
        self.0 =
            (self.0 & !(Self::Y_MASK << Self::Y_OFFSET)) | ((val & Self::Y_MASK) << Self::Y_OFFSET);
    }

    pub const Z_OFFSET: usize = 32;
    pub const Z_WIDTH: usize = 16;
    pub const Z_MASK: u64 = 0xFFFF;

    /// Z
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn z(&self) -> u16 {
        let val = (self.0 >> Self::Z_OFFSET) & Self::Z_MASK;
        val as u16
    }

    /// Z
    #[inline(always)]
    pub fn set_z(&mut self, val: u16) {
        let val = val as u64;
        self.0 =
            (self.0 & !(Self::Z_MASK << Self::Z_OFFSET)) | ((val & Self::Z_MASK) << Self::Z_OFFSET);
    }

    pub const Q_OFFSET: usize = 48;
    pub const Q_WIDTH: usize = 16;
    pub const Q_MASK: u64 = 0xFFFF;

    /// Q
    #[inline(always)]
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn q(&self) -> u16 {
        let val = (self.0 >> Self::Q_OFFSET) & Self::Q_MASK;
        val as u16
    }

    /// Q
    #[inline(always)]
    pub fn set_q(&mut self, val: u16) {
        let val = val as u64;
        self.0 =
            (self.0 & !(Self::Q_MASK << Self::Q_OFFSET)) | ((val & Self::Q_MASK) << Self::Q_OFFSET);
    }
}

impl core::fmt::Debug for VertexReg {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("VertexReg")
            .field("x", &self.x())
            .field("y", &self.y())
            .field("z", &self.z())
            .field("q", &self.q())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default() {
        let reg = VertexReg::default();
        assert_eq!(reg.x(), 0);
        assert_eq!(reg.y(), 0);
        assert_eq!(reg.z(), 0);
        assert_eq!(reg.q(), 0);
    }
}
