//! `std::ops` trait implementations for `Q` and `UQ`.
//!
//! Implements `Add`, `Sub`, `Neg` (Q only), `Shl`, `Shr`, `BitAnd`, `BitOr`
//! — all same-type only.
//!
//! Overflow behavior matches Rust integers: traps in debug, wraps in release.

use core::ops;

use crate::q::Q;
use crate::uq::UQ;

// ---------------------------------------------------------------------------
// Q<I, F>: Add, AddAssign
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Add for Q<I, F> {
    type Output = Self;

    /// Adds two `Q<I, F>` values.
    ///
    /// In debug mode, panics on overflow.
    #[inline]
    fn add(self, rhs: Self) -> Self {
        let result = self.raw().wrapping_add(rhs.raw());
        let out = Self::from_raw(result);
        debug_assert!(
            (self.raw() ^ rhs.raw()) < 0 || (self.raw() ^ result) >= 0 || Self::TOTAL_BITS >= 64,
            "Q::add overflow"
        );
        if Self::TOTAL_BITS < 64 {
            debug_assert!(result == out.raw(), "Q::add overflow: result out of range");
        }
        out
    }
}

impl<const I: u32, const F: u32> ops::AddAssign for Q<I, F> {
    /// Adds `rhs` in place.
    #[inline]
    fn add_assign(&mut self, rhs: Self) {
        *self = *self + rhs;
    }
}

// ---------------------------------------------------------------------------
// Q<I, F>: Sub, SubAssign
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Sub for Q<I, F> {
    type Output = Self;

    /// Subtracts two `Q<I, F>` values.
    ///
    /// In debug mode, panics on overflow.
    #[inline]
    fn sub(self, rhs: Self) -> Self {
        let result = self.raw().wrapping_sub(rhs.raw());
        let out = Self::from_raw(result);
        if Self::TOTAL_BITS < 64 {
            debug_assert!(result == out.raw(), "Q::sub overflow: result out of range");
        }
        out
    }
}

impl<const I: u32, const F: u32> ops::SubAssign for Q<I, F> {
    /// Subtracts `rhs` in place.
    #[inline]
    fn sub_assign(&mut self, rhs: Self) {
        *self = *self - rhs;
    }
}

// ---------------------------------------------------------------------------
// Q<I, F>: Neg
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Neg for Q<I, F> {
    type Output = Self;

    /// Negates a `Q<I, F>` value.
    ///
    /// In debug mode, panics when negating `MIN`.
    #[inline]
    fn neg(self) -> Self {
        let result = self.raw().wrapping_neg();
        let out = Self::from_raw(result);
        if Self::TOTAL_BITS < 64 {
            debug_assert!(result == out.raw(), "Q::neg overflow (negating MIN)");
        }
        out
    }
}

// ---------------------------------------------------------------------------
// Q<I, F>: Shl, Shr
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Shl<u32> for Q<I, F> {
    type Output = Self;

    /// Shifts left by `shift` bits, masking the result to `I + F` bits.
    #[inline]
    fn shl(self, shift: u32) -> Self {
        Self::from_raw(self.raw() << shift)
    }
}

impl<const I: u32, const F: u32> ops::ShlAssign<u32> for Q<I, F> {
    /// Shifts left in place.
    #[inline]
    fn shl_assign(&mut self, shift: u32) {
        *self = *self << shift;
    }
}

impl<const I: u32, const F: u32> ops::Shr<u32> for Q<I, F> {
    type Output = Self;

    /// Arithmetic right shift (sign-preserving) by `shift` bits.
    #[inline]
    fn shr(self, shift: u32) -> Self {
        Self::from_raw(self.raw() >> shift)
    }
}

impl<const I: u32, const F: u32> ops::ShrAssign<u32> for Q<I, F> {
    /// Shifts right in place.
    #[inline]
    fn shr_assign(&mut self, shift: u32) {
        *self = *self >> shift;
    }
}

// ---------------------------------------------------------------------------
// Q<I, F>: BitAnd, BitOr
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::BitAnd for Q<I, F> {
    type Output = Self;

    /// Bitwise AND of two `Q<I, F>` values.
    #[inline]
    fn bitand(self, rhs: Self) -> Self {
        Self::from_raw(self.raw() & rhs.raw())
    }
}

impl<const I: u32, const F: u32> ops::BitOr for Q<I, F> {
    type Output = Self;

    /// Bitwise OR of two `Q<I, F>` values.
    #[inline]
    fn bitor(self, rhs: Self) -> Self {
        Self::from_raw(self.raw() | rhs.raw())
    }
}

// ===========================================================================
// UQ<I, F>
// ===========================================================================

// ---------------------------------------------------------------------------
// UQ<I, F>: Add, AddAssign
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Add for UQ<I, F> {
    type Output = Self;

    /// Adds two `UQ<I, F>` values.
    ///
    /// In debug mode, panics on overflow.
    #[inline]
    fn add(self, rhs: Self) -> Self {
        let result = self.raw().wrapping_add(rhs.raw());
        let out = Self::from_raw(result);
        if Self::TOTAL_BITS < 64 {
            debug_assert!(result == out.raw(), "UQ::add overflow: result out of range");
        } else {
            debug_assert!(result >= self.raw(), "UQ::add overflow");
        }
        out
    }
}

impl<const I: u32, const F: u32> ops::AddAssign for UQ<I, F> {
    /// Adds `rhs` in place.
    #[inline]
    fn add_assign(&mut self, rhs: Self) {
        *self = *self + rhs;
    }
}

// ---------------------------------------------------------------------------
// UQ<I, F>: Sub, SubAssign
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Sub for UQ<I, F> {
    type Output = Self;

    /// Subtracts two `UQ<I, F>` values.
    ///
    /// In debug mode, panics on underflow.
    #[inline]
    fn sub(self, rhs: Self) -> Self {
        debug_assert!(self.raw() >= rhs.raw(), "UQ::sub underflow");
        let result = self.raw().wrapping_sub(rhs.raw());
        Self::from_raw(result)
    }
}

impl<const I: u32, const F: u32> ops::SubAssign for UQ<I, F> {
    /// Subtracts `rhs` in place.
    #[inline]
    fn sub_assign(&mut self, rhs: Self) {
        *self = *self - rhs;
    }
}

// ---------------------------------------------------------------------------
// UQ<I, F>: Shl, Shr
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Shl<u32> for UQ<I, F> {
    type Output = Self;

    /// Shifts left by `shift` bits, masking the result to `I + F` bits.
    #[inline]
    fn shl(self, shift: u32) -> Self {
        Self::from_raw(self.raw() << shift)
    }
}

impl<const I: u32, const F: u32> ops::ShlAssign<u32> for UQ<I, F> {
    /// Shifts left in place.
    #[inline]
    fn shl_assign(&mut self, shift: u32) {
        *self = *self << shift;
    }
}

impl<const I: u32, const F: u32> ops::Shr<u32> for UQ<I, F> {
    type Output = Self;

    /// Logical right shift (zero-fill) by `shift` bits.
    #[inline]
    fn shr(self, shift: u32) -> Self {
        Self::from_raw(self.raw() >> shift)
    }
}

impl<const I: u32, const F: u32> ops::ShrAssign<u32> for UQ<I, F> {
    /// Shifts right in place.
    #[inline]
    fn shr_assign(&mut self, shift: u32) {
        *self = *self >> shift;
    }
}

// ---------------------------------------------------------------------------
// UQ<I, F>: BitAnd, BitOr
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::BitAnd for UQ<I, F> {
    type Output = Self;

    /// Bitwise AND of two `UQ<I, F>` values.
    #[inline]
    fn bitand(self, rhs: Self) -> Self {
        Self::from_raw(self.raw() & rhs.raw())
    }
}

impl<const I: u32, const F: u32> ops::BitOr for UQ<I, F> {
    type Output = Self;

    /// Bitwise OR of two `UQ<I, F>` values.
    #[inline]
    fn bitor(self, rhs: Self) -> Self {
        Self::from_raw(self.raw() | rhs.raw())
    }
}
