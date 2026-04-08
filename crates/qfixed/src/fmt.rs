//! `Display` and `Debug` formatting for `Q` and `UQ`.

use core::fmt;

use crate::q::Q;
use crate::uq::UQ;

impl<const I: u32, const F: u32> fmt::Display for Q<I, F> {
    /// Displays the decimal value with 4 fractional digits.
    ///
    /// # Arguments
    ///
    /// * `f` - The formatter to write to.
    ///
    /// # Returns
    ///
    /// A `fmt::Result` indicating success or formatting error.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let val = self.to_f64();
        write!(f, "{val:.4}")
    }
}

impl<const I: u32, const F: u32> fmt::Debug for Q<I, F> {
    /// Formats as `Q12.4(0x0108 = 16.5000)`.
    ///
    /// # Arguments
    ///
    /// * `f` - The formatter to write to.
    ///
    /// # Returns
    ///
    /// A `fmt::Result` indicating success or formatting error.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let bits = self.to_bits();
        let val = self.to_f64();
        write!(
            f,
            "Q{I}.{F}(0x{bits:0>w$x} = {val:.4})",
            w = (I + F).div_ceil(4) as usize
        )
    }
}

impl<const I: u32, const F: u32> fmt::Display for UQ<I, F> {
    /// Displays the decimal value with 4 fractional digits.
    ///
    /// # Arguments
    ///
    /// * `f` - The formatter to write to.
    ///
    /// # Returns
    ///
    /// A `fmt::Result` indicating success or formatting error.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let val = self.to_f64();
        write!(f, "{val:.4}")
    }
}

impl<const I: u32, const F: u32> fmt::Debug for UQ<I, F> {
    /// Formats as `UQ1.7(0x40 = 0.5000)`.
    ///
    /// # Arguments
    ///
    /// * `f` - The formatter to write to.
    ///
    /// # Returns
    ///
    /// A `fmt::Result` indicating success or formatting error.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let bits = self.to_bits();
        let val = self.to_f64();
        write!(
            f,
            "UQ{I}.{F}(0x{bits:0>w$x} = {val:.4})",
            w = (I + F).div_ceil(4) as usize
        )
    }
}
