//! `std::ops` trait implementations for `Q` and `UQ`.
//!
//! Implements `Add`, `Sub`, `Neg` (Q only), `Mul`, `Shl`, `Shr`, `BitAnd`,
//! `BitOr`.
//!
//! Arithmetic operators produce widened outputs that cannot overflow:
//! - `Q<I,F> + Q<I,F>` → `Q<{I+1}, F>` (one extra integer bit)
//! - `Q<I,F> - Q<I,F>` → `Q<{I+1}, F>` (one extra integer bit)
//! - `Q<I,F> * Q<I,F>` → `Q<{I+I}, {F+F}>` (full-width product)
//! - `-Q<I,F>` → `Q<{I+1}, F>` (handles MIN)
//!
//! Use `.truncate()` or `.saturate()` to narrow the result back down.
//! Use `wrapping_add`/`wrapping_sub`/`wrapping_mul` for same-type RTL
//! truncation semantics.

// Widening operators use arithmetic in const generic params (e.g., `Q<{I+1}, F>`
// inside an Add impl), which clippy misinterprets as wrong-operation bugs.
#![allow(clippy::suspicious_arithmetic_impl)]

use core::ops;

use crate::q::Q;
use crate::uq::UQ;

// ===========================================================================
// Q<I, F>
// ===========================================================================

// ---------------------------------------------------------------------------
// Q<I, F>: Add
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Add for Q<I, F>
where
    [(); (I + 1 + F) as usize]:,
{
    type Output = Q<{ I + 1 }, F>;

    /// Adds two `Q<I, F>` values, producing `Q<{I+1}, F>`.
    ///
    /// The extra integer bit guarantees no overflow.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand operand.
    ///
    /// # Returns
    ///
    /// The exact sum as `Q<{I+1}, F>`.
    #[inline]
    fn add(self, rhs: Self) -> Self::Output {
        Q::<{ I + 1 }, F>::from_raw(self.raw() + rhs.raw())
    }
}

// ---------------------------------------------------------------------------
// Q<I, F>: Sub
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Sub for Q<I, F>
where
    [(); (I + 1 + F) as usize]:,
{
    type Output = Q<{ I + 1 }, F>;

    /// Subtracts two `Q<I, F>` values, producing `Q<{I+1}, F>`.
    ///
    /// The extra integer bit guarantees no overflow.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand operand.
    ///
    /// # Returns
    ///
    /// The exact difference as `Q<{I+1}, F>`.
    #[inline]
    fn sub(self, rhs: Self) -> Self::Output {
        Q::<{ I + 1 }, F>::from_raw(self.raw() - rhs.raw())
    }
}

// ---------------------------------------------------------------------------
// Q<I, F>: Neg
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Neg for Q<I, F>
where
    [(); (I + 1 + F) as usize]:,
{
    type Output = Q<{ I + 1 }, F>;

    /// Negates a `Q<I, F>` value, producing `Q<{I+1}, F>`.
    ///
    /// The extra integer bit handles the MIN case without wrapping.
    ///
    /// # Returns
    ///
    /// The exact negation as `Q<{I+1}, F>`.
    #[inline]
    fn neg(self) -> Self::Output {
        Q::<{ I + 1 }, F>::from_raw(-self.raw())
    }
}

// ---------------------------------------------------------------------------
// Q<I, F>: Mul
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Mul for Q<I, F>
where
    [(); (I + I + F + F) as usize]:,
    [(); { F + F } as usize]:,
{
    type Output = Q<{ I + I }, { F + F }>;

    /// Multiplies two `Q<I, F>` values, producing `Q<{I+I}, {F+F}>`.
    ///
    /// The full-width product cannot overflow.
    /// Use `.truncate()` or `.saturate()` to narrow the result.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand operand.
    ///
    /// # Returns
    ///
    /// The exact product as `Q<{I+I}, {F+F}>`.
    #[inline]
    fn mul(self, rhs: Self) -> Self::Output {
        let product = self.raw() as i128 * rhs.raw() as i128;
        Q::<{ I + I }, { F + F }>::from_raw(product as i64)
    }
}

// ---------------------------------------------------------------------------
// Q<I, F>: Shl, Shr
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Shl<u32> for Q<I, F> {
    type Output = Self;

    /// Shifts left by `shift` bits, masking the result to `I + F` bits.
    ///
    /// # Arguments
    ///
    /// * `shift` - Number of bits to shift left.
    ///
    /// # Returns
    ///
    /// The shifted value, masked to the bit width.
    #[inline]
    fn shl(self, shift: u32) -> Self {
        Self::from_raw(self.raw() << shift)
    }
}

impl<const I: u32, const F: u32> ops::ShlAssign<u32> for Q<I, F> {
    /// Shifts left in place.
    ///
    /// # Arguments
    ///
    /// * `shift` - Number of bits to shift left.
    #[inline]
    fn shl_assign(&mut self, shift: u32) {
        *self = *self << shift;
    }
}

impl<const I: u32, const F: u32> ops::Shr<u32> for Q<I, F> {
    type Output = Self;

    /// Arithmetic right shift (sign-preserving) by `shift` bits.
    ///
    /// # Arguments
    ///
    /// * `shift` - Number of bits to shift right.
    ///
    /// # Returns
    ///
    /// The shifted value with sign extension.
    #[inline]
    fn shr(self, shift: u32) -> Self {
        Self::from_raw(self.raw() >> shift)
    }
}

impl<const I: u32, const F: u32> ops::ShrAssign<u32> for Q<I, F> {
    /// Shifts right in place (arithmetic / sign-preserving).
    ///
    /// # Arguments
    ///
    /// * `shift` - Number of bits to shift right.
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
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand operand.
    ///
    /// # Returns
    ///
    /// The bitwise AND result.
    #[inline]
    fn bitand(self, rhs: Self) -> Self {
        Self::from_raw(self.raw() & rhs.raw())
    }
}

impl<const I: u32, const F: u32> ops::BitOr for Q<I, F> {
    type Output = Self;

    /// Bitwise OR of two `Q<I, F>` values.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand operand.
    ///
    /// # Returns
    ///
    /// The bitwise OR result.
    #[inline]
    fn bitor(self, rhs: Self) -> Self {
        Self::from_raw(self.raw() | rhs.raw())
    }
}

// ===========================================================================
// UQ<I, F>
// ===========================================================================

// ---------------------------------------------------------------------------
// UQ<I, F>: Add
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Add for UQ<I, F>
where
    [(); (I + 1 + F) as usize]:,
{
    type Output = UQ<{ I + 1 }, F>;

    /// Adds two `UQ<I, F>` values, producing `UQ<{I+1}, F>`.
    ///
    /// The extra integer bit guarantees no overflow.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand operand.
    ///
    /// # Returns
    ///
    /// The exact sum as `UQ<{I+1}, F>`.
    #[inline]
    fn add(self, rhs: Self) -> Self::Output {
        UQ::<{ I + 1 }, F>::from_raw(self.raw() + rhs.raw())
    }
}

// ---------------------------------------------------------------------------
// UQ<I, F>: Sub → signed Q output
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Sub for UQ<I, F>
where
    [(); (I + 1 + F) as usize]:,
{
    type Output = Q<{ I + 1 }, F>;

    /// Subtracts two `UQ<I, F>` values, producing signed `Q<{I+1}, F>`.
    ///
    /// The result is signed because `UQ - UQ` can be negative.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand operand.
    ///
    /// # Returns
    ///
    /// The exact difference as signed `Q<{I+1}, F>`.
    #[inline]
    fn sub(self, rhs: Self) -> Self::Output {
        Q::<{ I + 1 }, F>::from_raw(self.raw() as i64 - rhs.raw() as i64)
    }
}

// ---------------------------------------------------------------------------
// UQ<I, F>: Mul
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Mul for UQ<I, F>
where
    [(); (I + I + F + F) as usize]:,
    [(); { F + F } as usize]:,
{
    type Output = UQ<{ I + I }, { F + F }>;

    /// Multiplies two `UQ<I, F>` values, producing `UQ<{I+I}, {F+F}>`.
    ///
    /// The full-width product cannot overflow.
    /// Use `.truncate()` or `.saturate()` to narrow the result.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand operand.
    ///
    /// # Returns
    ///
    /// The exact product as `UQ<{I+I}, {F+F}>`.
    #[inline]
    fn mul(self, rhs: Self) -> Self::Output {
        let product = self.raw() as u128 * rhs.raw() as u128;
        UQ::<{ I + I }, { F + F }>::from_raw(product as u64)
    }
}

// ---------------------------------------------------------------------------
// UQ<I, F>: Shl, Shr
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> ops::Shl<u32> for UQ<I, F> {
    type Output = Self;

    /// Shifts left by `shift` bits, masking the result to `I + F` bits.
    ///
    /// # Arguments
    ///
    /// * `shift` - Number of bits to shift left.
    ///
    /// # Returns
    ///
    /// The shifted value, masked to the bit width.
    #[inline]
    fn shl(self, shift: u32) -> Self {
        Self::from_raw(self.raw() << shift)
    }
}

impl<const I: u32, const F: u32> ops::ShlAssign<u32> for UQ<I, F> {
    /// Shifts left in place.
    ///
    /// # Arguments
    ///
    /// * `shift` - Number of bits to shift left.
    #[inline]
    fn shl_assign(&mut self, shift: u32) {
        *self = *self << shift;
    }
}

impl<const I: u32, const F: u32> ops::Shr<u32> for UQ<I, F> {
    type Output = Self;

    /// Logical right shift (zero-fill) by `shift` bits.
    ///
    /// # Arguments
    ///
    /// * `shift` - Number of bits to shift right.
    ///
    /// # Returns
    ///
    /// The shifted value with zero-fill.
    #[inline]
    fn shr(self, shift: u32) -> Self {
        Self::from_raw(self.raw() >> shift)
    }
}

impl<const I: u32, const F: u32> ops::ShrAssign<u32> for UQ<I, F> {
    /// Shifts right in place (logical / zero-fill).
    ///
    /// # Arguments
    ///
    /// * `shift` - Number of bits to shift right.
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
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand operand.
    ///
    /// # Returns
    ///
    /// The bitwise AND result.
    #[inline]
    fn bitand(self, rhs: Self) -> Self {
        Self::from_raw(self.raw() & rhs.raw())
    }
}

impl<const I: u32, const F: u32> ops::BitOr for UQ<I, F> {
    type Output = Self;

    /// Bitwise OR of two `UQ<I, F>` values.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand operand.
    ///
    /// # Returns
    ///
    /// The bitwise OR result.
    #[inline]
    fn bitor(self, rhs: Self) -> Self {
        Self::from_raw(self.raw() | rhs.raw())
    }
}
