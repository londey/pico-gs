//! Unsigned fixed-point type `UQ<I, F>`.

/// Unsigned fixed-point number with `I` integer bits and `F` fractional bits.
///
/// Total bit width = `I + F`, must satisfy `1 <= I + F <= 64`.
/// Internally backed by `u64`, masked to `I + F` bits.
///
/// # Notation
///
/// Follows TI-style UQ notation: `UQ<1, 7>` is an 8-bit unsigned value with
/// 1 integer bit and 7 fractional bits, representing values in increments of
/// 1/128.
#[derive(Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct UQ<const I: u32, const F: u32>(pub(crate) u64);

impl<const I: u32, const F: u32> UQ<I, F> {
    /// Total number of bits in this fixed-point type.
    pub const TOTAL_BITS: u32 = I + F;

    /// Bitmask covering the valid bits.
    const MASK: u64 = if I + F >= 64 {
        u64::MAX
    } else {
        (1u64 << (I + F)) - 1
    };

    /// The value zero (0.0).
    pub const ZERO: Self = Self(0);

    /// The value one (1.0).
    ///
    /// Only available when `I >= 1` (at least one integer bit).
    ///
    /// # Panics
    ///
    /// Panics at compile time if `I == 0`.
    pub const ONE: Self = {
        assert!(I + F > 0, "UQ type must have at least 1 bit");
        assert!(I + F <= 64, "UQ type cannot exceed 64 bits");
        assert!(I >= 1, "UQ<I,F> with I==0 cannot represent 1.0");
        Self(1u64 << F)
    };

    /// Maximum representable value.
    ///
    /// For `UQ<I, F>`, this is `2^I - 2^(-F)`.
    pub const MAX: Self = {
        assert!(I + F > 0, "UQ type must have at least 1 bit");
        assert!(I + F <= 64, "UQ type cannot exceed 64 bits");
        Self(Self::MASK)
    };

    /// Minimum representable value (always zero for unsigned).
    pub const MIN: Self = Self(0);

    /// Forces compile-time validation of the type parameters.
    ///
    /// # Panics
    ///
    /// Panics at compile time if `I + F` is 0 or exceeds 64.
    #[inline(always)]
    pub(crate) const fn check() {
        assert!(I + F > 0, "UQ type must have at least 1 bit");
        assert!(I + F <= 64, "UQ type cannot exceed 64 bits");
    }

    /// Constructs from a raw bit representation.
    ///
    /// Masked to `I + F` bits.
    ///
    /// # Arguments
    ///
    /// * `raw` - The raw fixed-point value.
    ///
    /// # Returns
    ///
    /// A new `UQ<I, F>` holding the masked value.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if `raw` does not already fit in `I + F`
    /// bits.
    #[inline]
    pub const fn from_bits(raw: u64) -> Self {
        Self::check();
        let masked = raw & Self::MASK;
        debug_assert!(
            raw == masked,
            "from_bits: value out of range for this UQ type"
        );
        Self(masked)
    }

    /// Extracts the raw bit representation.
    ///
    /// # Returns
    ///
    /// The raw fixed-point value as a `u64`.
    #[inline]
    pub const fn to_bits(self) -> u64 {
        self.0
    }

    /// Returns the internal raw value.
    ///
    /// # Returns
    ///
    /// The stored u64 (already masked to `I + F` bits).
    #[inline]
    pub(crate) const fn raw(self) -> u64 {
        self.0
    }

    /// Constructs from a masked u64 without the `from_bits` debug range
    /// check.
    ///
    /// # Arguments
    ///
    /// * `raw` - The value to store, which will be masked to `I + F` bits.
    ///
    /// # Returns
    ///
    /// A new `UQ<I, F>` with the masked value.
    #[inline]
    pub(crate) const fn from_raw(raw: u64) -> Self {
        Self::check();
        Self(raw & Self::MASK)
    }

    /// Constructs from an integer value by shifting left by `F`.
    ///
    /// # Arguments
    ///
    /// * `val` - The integer to convert.
    ///
    /// # Returns
    ///
    /// A new `UQ<I, F>` representing `val` as a fixed-point value.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if `val` does not fit in `I` integer bits.
    #[inline]
    pub const fn from_int(val: u64) -> Self {
        Self::check();
        let shifted = val << F;
        Self::from_bits(shifted)
    }

    /// Extracts the integer part, truncating toward zero.
    ///
    /// # Returns
    ///
    /// The integer portion of the fixed-point value.
    #[inline]
    pub const fn to_int(self) -> u64 {
        self.0 >> F
    }

    /// Constructs from `f64` by quantizing to the nearest representable
    /// value.
    ///
    /// # Arguments
    ///
    /// * `val` - The floating-point value to quantize.
    ///
    /// # Returns
    ///
    /// A new `UQ<I, F>` representing the quantized value.
    #[inline]
    pub fn from_f64(val: f64) -> Self {
        Self::check();
        let scale = (1u64 << F) as f64;
        let raw = (val * scale) as u64;
        Self::from_raw(raw)
    }

    /// Converts to `f64`.
    ///
    /// # Returns
    ///
    /// The fixed-point value as a floating-point approximation.
    #[inline]
    pub fn to_f64(self) -> f64 {
        let scale = (1u64 << F) as f64;
        self.0 as f64 / scale
    }

    /// Returns the minimum of `self` and `other`.
    ///
    /// # Arguments
    ///
    /// * `other` - The value to compare against.
    ///
    /// # Returns
    ///
    /// The smaller of the two values.
    #[inline]
    pub const fn min(self, other: Self) -> Self {
        if self.0 < other.0 {
            self
        } else {
            other
        }
    }

    /// Returns the maximum of `self` and `other`.
    ///
    /// # Arguments
    ///
    /// * `other` - The value to compare against.
    ///
    /// # Returns
    ///
    /// The larger of the two values.
    #[inline]
    pub const fn max(self, other: Self) -> Self {
        if self.0 > other.0 {
            self
        } else {
            other
        }
    }

    /// Clamps `self` to the range `[lo, hi]`.
    ///
    /// # Arguments
    ///
    /// * `lo` - The lower bound.
    /// * `hi` - The upper bound.
    ///
    /// # Returns
    ///
    /// `self` clamped to `[lo, hi]`.
    #[inline]
    pub const fn clamp(self, lo: Self, hi: Self) -> Self {
        self.max(lo).min(hi)
    }

    /// Wrapping addition (always wraps, never traps).
    ///
    /// # Arguments
    ///
    /// * `rhs` - The value to add.
    ///
    /// # Returns
    ///
    /// The sum, wrapped to `I + F` bits.
    #[inline]
    pub const fn wrapping_add(self, rhs: Self) -> Self {
        Self::from_raw(self.0.wrapping_add(rhs.0))
    }

    /// Wrapping subtraction (always wraps, never traps).
    ///
    /// # Arguments
    ///
    /// * `rhs` - The value to subtract.
    ///
    /// # Returns
    ///
    /// The difference, wrapped to `I + F` bits.
    #[inline]
    pub const fn wrapping_sub(self, rhs: Self) -> Self {
        Self::from_raw(self.0.wrapping_sub(rhs.0))
    }

    /// Wrapping same-type multiply: `(self * rhs) >> F`, truncated.
    ///
    /// The full product is computed in 128 bits, then the fractional
    /// point is realigned by shifting right by `F`.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The value to multiply by.
    ///
    /// # Returns
    ///
    /// The truncated product in the same `UQ<I, F>` format.
    #[inline]
    pub const fn wrapping_mul(self, rhs: Self) -> Self {
        let product = self.0 as u128 * rhs.0 as u128;
        let shifted = (product >> F) as u64;
        Self::from_raw(shifted)
    }

    /// Wrapping same-type divide: `(self << F) / rhs`, truncated.
    ///
    /// The numerator is widened in 128 bits before division to preserve
    /// fractional precision.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The divisor (must not be zero).
    ///
    /// # Returns
    ///
    /// The truncated quotient in the same `UQ<I, F>` format.
    #[inline]
    pub const fn wrapping_div(self, rhs: Self) -> Self {
        let numer = (self.0 as u128) << F;
        let result = (numer / rhs.0 as u128) as u64;
        Self::from_raw(result)
    }

    /// Widening multiply with full-precision output.
    ///
    /// The output type `UQ<IO, FO>` must be wide enough to hold the
    /// product without loss.
    /// The output type is typically inferred from the assignment target.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand operand.
    ///
    /// # Returns
    ///
    /// The full-precision product in `UQ<IO, FO>` format.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if `IO + FO < I + F + I2 + F2`.
    #[inline]
    pub fn widening_mul<const I2: u32, const F2: u32, const IO: u32, const FO: u32>(
        self,
        rhs: UQ<I2, F2>,
    ) -> UQ<IO, FO> {
        UQ::<I2, F2>::check();
        UQ::<IO, FO>::check();
        debug_assert!(
            IO + FO >= I + F + I2 + F2,
            "widening_mul: output UQ<{}, {}> ({} bits) too narrow for UQ<{}, {}> * UQ<{}, {}> ({} bits needed)",
            IO, FO, IO + FO,
            I, F, I2, F2, I + F + I2 + F2
        );
        let product = self.0 as u128 * rhs.0 as u128;
        let frac_in = F + F2;
        let shift = frac_in as i32 - FO as i32;
        let result = if shift > 0 {
            product >> shift
        } else {
            product << (-shift)
        };
        UQ::<IO, FO>::from_raw(result as u64)
    }
}
