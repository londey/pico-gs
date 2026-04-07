//! Compile-time width-checked unsigned bit vector type for hardware modeling.
//!
//! Provides [`Bits<N>`], an unsigned integer type that is exactly `N` bits
//! wide, where `N` is a compile-time constant in the range `1..=64`.
//! Values are automatically masked to `N` bits on construction, and
//! arithmetic operations preserve the width invariant.
//!
//! This is the hardware modeler's counterpart to `Q<I, F>` and `UQ<I, F>`
//! from the `qfixed` crate: where those carry fixed-point semantics,
//! `Bits<N>` carries only width — it represents a raw N-bit register,
//! bus, or memory word with no arithmetic interpretation.
//!
//! # Examples
//!
//! ```
//! use bits::Bits;
//!
//! // An 18-bit EBR entry
//! let entry = Bits::<18>::new(0x3_ABCD);
//! assert_eq!(entry.val(), 0x3_ABCD);
//!
//! // Values are masked to width
//! let masked = Bits::<8>::new(0x1FF);
//! assert_eq!(masked.val(), 0xFF);
//!
//! // Compile-time type safety: can't mix widths
//! // let sum: Bits<8> = Bits::<8>::ZERO + Bits::<16>::ZERO; // won't compile
//! ```

#![no_std]
#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::must_use_candidate)]
#![allow(clippy::missing_errors_doc)]
#![allow(clippy::missing_panics_doc)]
#![allow(clippy::enum_variant_names)]
#![allow(dead_code)]
#![allow(unused_crate_dependencies)]

#[cfg(test)]
extern crate alloc;

use core::fmt;
use core::ops::{BitAnd, BitOr, BitXor, Not, Shl, Shr};

/// An unsigned bit vector of exactly `N` bits, where `1 <= N <= 64`.
///
/// Internally backed by `u64`, masked to the low `N` bits.
/// All constructors and arithmetic operations enforce the width invariant:
/// the upper `64 - N` bits are always zero.
///
/// # Type Parameter
///
/// * `N` - The bit width (must be 1..=64, enforced at compile time).
#[derive(Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Bits<const N: u32>(u64);

impl<const N: u32> Bits<N> {
    /// Total number of bits in this type.
    pub const WIDTH: u32 = N;

    /// Bitmask covering the valid bits.
    const MASK: u64 = if N >= 64 { u64::MAX } else { (1u64 << N) - 1 };

    /// The value zero.
    pub const ZERO: Self = Self(0);

    /// The maximum representable value (all N bits set).
    pub const MAX: Self = Self(Self::MASK);

    /// Forces compile-time validation of the type parameter.
    ///
    /// # Panics
    ///
    /// Panics at compile time if `N` is 0 or exceeds 64.
    #[inline(always)]
    const fn check() {
        assert!(N > 0, "Bits<N> must have at least 1 bit");
        assert!(N <= 64, "Bits<N> cannot exceed 64 bits");
    }

    /// Construct from a `u64`, masking to `N` bits.
    ///
    /// # Arguments
    ///
    /// * `val` - The value to store (upper bits beyond `N` are discarded).
    ///
    /// # Returns
    ///
    /// A new `Bits<N>` containing the low `N` bits of `val`.
    #[inline]
    pub const fn new(val: u64) -> Self {
        Self::check();
        Self(val & Self::MASK)
    }

    /// Construct from a `u64`, panicking in debug mode if the value
    /// does not fit in `N` bits.
    ///
    /// In release mode this is equivalent to [`Self::new`] (masks silently).
    ///
    /// # Arguments
    ///
    /// * `val` - The value to store.
    ///
    /// # Returns
    ///
    /// A new `Bits<N>` containing `val`.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if `val` has any bits set above position `N-1`.
    #[inline]
    pub const fn from_checked(val: u64) -> Self {
        Self::check();
        debug_assert!(
            val & !Self::MASK == 0,
            "from_checked: value does not fit in N bits"
        );
        Self(val & Self::MASK)
    }

    /// Extract the raw `u64` value (guaranteed to have only the low `N`
    /// bits set).
    ///
    /// # Returns
    ///
    /// The stored value as a `u64`.
    #[inline]
    pub const fn val(self) -> u64 {
        self.0
    }

    /// Extract a single bit by position.
    ///
    /// # Arguments
    ///
    /// * `bit` - The bit index (0 = LSB).
    ///
    /// # Returns
    ///
    /// `true` if the bit is set, `false` otherwise.
    /// Returns `false` if `bit >= N`.
    #[inline]
    pub const fn bit(self, bit: u32) -> bool {
        if bit >= N {
            false
        } else {
            (self.0 >> bit) & 1 != 0
        }
    }

    /// Extract a contiguous bit range `[lo..=hi]`.
    ///
    /// The result is right-justified (shifted to start at bit 0).
    ///
    /// # Arguments
    ///
    /// * `hi` - The highest bit index (inclusive).
    /// * `lo` - The lowest bit index (inclusive).
    ///
    /// # Returns
    ///
    /// The extracted bits as a `u64`, right-justified.
    ///
    /// # Panics
    ///
    /// Panics if `hi < lo` or `hi >= N`.
    #[inline]
    pub const fn range(self, hi: u32, lo: u32) -> u64 {
        assert!(hi >= lo, "range: hi must be >= lo");
        assert!(hi < N, "range: hi must be < N");
        let width = hi - lo + 1;
        let mask = if width >= 64 {
            u64::MAX
        } else {
            (1u64 << width) - 1
        };
        (self.0 >> lo) & mask
    }

    /// Extract a contiguous bit range at compile time, returning a
    /// width-checked `Bits<M>`.
    ///
    /// Equivalent to Verilog `val[HI:LO]`.  The output width `M` must
    /// equal `HI - LO + 1`.
    ///
    /// # Type Parameters
    ///
    /// * `HI` - The highest bit index (inclusive).
    /// * `LO` - The lowest bit index (inclusive).
    /// * `M` - The output width (must equal `HI - LO + 1`).
    ///
    /// # Returns
    ///
    /// The extracted bits as a `Bits<M>`.
    ///
    /// # Panics
    ///
    /// Panics at compile time if `HI < LO`, `HI >= N`, or `M != HI - LO + 1`.
    #[inline]
    pub const fn slice<const HI: u32, const LO: u32, const M: u32>(self) -> Bits<M> {
        assert!(HI >= LO, "slice: HI must be >= LO");
        assert!(HI < N, "slice: HI must be < N");
        assert!(M == HI - LO + 1, "slice: M must equal HI - LO + 1");
        Bits::<M>::check();
        let mask = if M >= 64 { u64::MAX } else { (1u64 << M) - 1 };
        Bits::<M>::new((self.0 >> LO) & mask)
    }

    /// Wrapping addition.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The value to add.
    ///
    /// # Returns
    ///
    /// The sum, masked to `N` bits.
    #[inline]
    pub const fn wrapping_add(self, rhs: Self) -> Self {
        Self(self.0.wrapping_add(rhs.0) & Self::MASK)
    }

    /// Wrapping subtraction.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The value to subtract.
    ///
    /// # Returns
    ///
    /// The difference, masked to `N` bits.
    #[inline]
    pub const fn wrapping_sub(self, rhs: Self) -> Self {
        Self(self.0.wrapping_sub(rhs.0) & Self::MASK)
    }

    /// Concatenate two bit vectors: `self` in the high bits, `lo` in the
    /// low bits.
    ///
    /// The output width `M` must equal `N + N2`.
    ///
    /// # Arguments
    ///
    /// * `lo` - The value to place in the low bits.
    ///
    /// # Returns
    ///
    /// A `Bits<M>` with `self` shifted left by `N2` bits, OR'd with `lo`.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if `M != N + N2`.
    #[inline]
    pub const fn concat<const N2: u32, const M: u32>(self, lo: Bits<N2>) -> Bits<M> {
        Bits::<N2>::check();
        Bits::<M>::check();
        debug_assert!(M == N + N2, "concat: output width must equal N + N2");
        Bits::<M>::new((self.0 << N2) | lo.0)
    }

    /// Zero-extend to a wider type.
    ///
    /// # Returns
    ///
    /// The same value in a `Bits<M>` where `M >= N`.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if `M < N`.
    #[inline]
    pub const fn zext<const M: u32>(self) -> Bits<M> {
        Bits::<M>::check();
        debug_assert!(M >= N, "zext: target width must be >= source width");
        Bits::<M>::new(self.0)
    }

    /// Truncate to a narrower type (keeps the low `M` bits).
    ///
    /// # Returns
    ///
    /// The low `M` bits of `self` as a `Bits<M>`.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if `M > N`.
    #[inline]
    pub const fn trunc<const M: u32>(self) -> Bits<M> {
        Bits::<M>::check();
        debug_assert!(M <= N, "trunc: target width must be <= source width");
        Bits::<M>::new(self.0)
    }
}

// ---------------------------------------------------------------------------
// Operator impls
// ---------------------------------------------------------------------------

impl<const N: u32> BitAnd for Bits<N> {
    type Output = Self;

    #[inline]
    fn bitand(self, rhs: Self) -> Self {
        Self(self.0 & rhs.0)
    }
}

impl<const N: u32> BitOr for Bits<N> {
    type Output = Self;

    #[inline]
    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

impl<const N: u32> BitXor for Bits<N> {
    type Output = Self;

    #[inline]
    fn bitxor(self, rhs: Self) -> Self {
        Self(self.0 ^ rhs.0)
    }
}

impl<const N: u32> Not for Bits<N> {
    type Output = Self;

    #[inline]
    fn not(self) -> Self {
        Self(!self.0 & Self::MASK)
    }
}

impl<const N: u32> Shl<u32> for Bits<N> {
    type Output = Self;

    #[inline]
    fn shl(self, rhs: u32) -> Self {
        Self((self.0 << rhs) & Self::MASK)
    }
}

impl<const N: u32> Shr<u32> for Bits<N> {
    type Output = Self;

    #[inline]
    fn shr(self, rhs: u32) -> Self {
        Self(self.0 >> rhs)
    }
}

// ---------------------------------------------------------------------------
// Display / Debug
// ---------------------------------------------------------------------------

impl<const N: u32> fmt::Debug for Bits<N> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Bits<{}>({:#X})", N, self.0)
    }
}

impl<const N: u32> fmt::Display for Bits<N> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:#X}", self.0)
    }
}

impl<const N: u32> fmt::Binary for Bits<N> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:0>width$b}", self.0, width = N as usize)
    }
}

// ---------------------------------------------------------------------------
// From conversions
// ---------------------------------------------------------------------------

impl<const N: u32> From<Bits<N>> for u64 {
    #[inline]
    fn from(b: Bits<N>) -> u64 {
        b.0
    }
}

impl<const N: u32> From<Bits<N>> for u32 {
    #[inline]
    fn from(b: Bits<N>) -> u32 {
        b.0 as u32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verify values are masked to N bits on construction.
    #[test]
    fn masking_on_new() {
        let b = Bits::<8>::new(0x1FF);
        assert_eq!(b.val(), 0xFF);

        let b = Bits::<1>::new(3);
        assert_eq!(b.val(), 1);
    }

    /// Verify MAX has all N bits set.
    #[test]
    fn max_value() {
        assert_eq!(Bits::<18>::MAX.val(), 0x3_FFFF);
        assert_eq!(Bits::<1>::MAX.val(), 1);
        assert_eq!(Bits::<64>::MAX.val(), u64::MAX);
    }

    /// Verify single-bit extraction.
    #[test]
    fn bit_extraction() {
        let b = Bits::<8>::new(0b1010_0101);
        assert!(b.bit(0));
        assert!(!b.bit(1));
        assert!(b.bit(2));
        assert!(b.bit(5));
        assert!(b.bit(7));
        assert!(!b.bit(8)); // out of range
    }

    /// Verify contiguous bit range extraction.
    #[test]
    fn range_extraction() {
        let b = Bits::<16>::new(0xABCD);
        assert_eq!(b.range(3, 0), 0xD);
        assert_eq!(b.range(7, 4), 0xC);
        assert_eq!(b.range(15, 8), 0xAB);
        assert_eq!(b.range(15, 0), 0xABCD);
    }

    /// Verify compile-time slice extracts correct bits with typed output.
    #[test]
    fn compile_time_slice() {
        let b = Bits::<16>::new(0xABCD);
        let low_nibble: Bits<4> = b.slice::<3, 0, 4>();
        assert_eq!(low_nibble.val(), 0xD);
        let high_byte: Bits<8> = b.slice::<15, 8, 8>();
        assert_eq!(high_byte.val(), 0xAB);
        let middle: Bits<8> = b.slice::<11, 4, 8>();
        assert_eq!(middle.val(), 0xBC);
    }

    /// Verify wrapping addition masks to N bits.
    #[test]
    fn wrapping_add_masks() {
        let a = Bits::<8>::new(0xFF);
        let b = Bits::<8>::new(1);
        assert_eq!(a.wrapping_add(b).val(), 0);
    }

    /// Verify bitwise NOT inverts only the low N bits.
    #[test]
    fn not_masks() {
        let b = Bits::<8>::new(0);
        assert_eq!((!b).val(), 0xFF);

        let b = Bits::<18>::new(0);
        assert_eq!((!b).val(), 0x3_FFFF);
    }

    /// Verify concatenation of two bit vectors.
    #[test]
    fn concat_values() {
        let hi = Bits::<4>::new(0xA);
        let lo = Bits::<8>::new(0xBC);
        let result: Bits<12> = hi.concat(lo);
        assert_eq!(result.val(), 0xABC);
    }

    /// Verify zero-extension preserves value.
    #[test]
    fn zero_extend() {
        let b = Bits::<8>::new(0xAB);
        let wide: Bits<16> = b.zext();
        assert_eq!(wide.val(), 0xAB);
    }

    /// Verify truncation keeps low bits.
    #[test]
    fn truncate() {
        let b = Bits::<16>::new(0xABCD);
        let narrow: Bits<8> = b.trunc();
        assert_eq!(narrow.val(), 0xCD);
    }

    /// Verify debug formatting includes width and hex value.
    #[test]
    fn debug_format() {
        use alloc::format;
        let b = Bits::<18>::new(42);
        let s = format!("{b:?}");
        assert!(s.contains("Bits<18>"));
        assert!(s.contains("0x2A"));
    }

    /// Verify binary formatting pads to N bits.
    #[test]
    fn binary_format() {
        use alloc::format;
        let b = Bits::<8>::new(5);
        let s = format!("{b:b}");
        assert_eq!(s, "00000101");
    }
}
