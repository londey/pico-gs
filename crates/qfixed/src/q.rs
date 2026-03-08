//! Signed fixed-point type `Q<I, F>`.

/// Signed fixed-point number with `I` integer bits (including sign) and `F`
/// fractional bits.
///
/// Total bit width = `I + F`, must satisfy `1 <= I + F <= 64`.
/// Internally backed by `i64`, sign-extended from bit `I + F - 1`.
///
/// # Notation
///
/// Follows TI-style Q notation: `Q<1, 8>` is a 9-bit signed value with
/// 1 integer bit (the sign) and 8 fractional bits, representing values
/// in increments of 1/256.
#[derive(Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Q<const I: u32, const F: u32>(pub(crate) i64);

impl<const I: u32, const F: u32> Q<I, F> {
    /// Total number of bits in this fixed-point type.
    pub const TOTAL_BITS: u32 = I + F;

    /// Bitmask covering the valid bits.
    const MASK: u64 = if I + F >= 64 {
        u64::MAX
    } else {
        (1u64 << (I + F)) - 1
    };

    /// Number of bits to shift for sign extension from `TOTAL_BITS` to 64.
    const SIGN_EXT_SHIFT: u32 = 64 - (I + F);

    /// The value zero (0.0).
    pub const ZERO: Self = Self(0);

    /// The value one (1.0).
    ///
    /// Only available when `I > 1` (at least one non-sign integer bit).
    ///
    /// # Panics
    ///
    /// Panics at compile time if `I <= 1`.
    pub const ONE: Self = {
        assert!(I + F > 0, "Q type must have at least 1 bit");
        assert!(I + F <= 64, "Q type cannot exceed 64 bits");
        assert!(I > 1, "Q<I,F> with I<=1 cannot represent +1.0");
        Self(1i64 << F)
    };

    /// Maximum representable value.
    ///
    /// For `Q<I, F>`, this is `2^(I-1) - 2^(-F)`.
    pub const MAX: Self = {
        assert!(I + F > 0, "Q type must have at least 1 bit");
        assert!(I + F <= 64, "Q type cannot exceed 64 bits");
        if I + F >= 64 {
            Self(i64::MAX)
        } else {
            Self((1i64 << (I + F - 1)) - 1)
        }
    };

    /// Minimum representable value (most negative).
    ///
    /// For `Q<I, F>`, this is `-2^(I-1)`.
    pub const MIN: Self = {
        assert!(I + F > 0, "Q type must have at least 1 bit");
        assert!(I + F <= 64, "Q type cannot exceed 64 bits");
        if I + F >= 64 {
            Self(i64::MIN)
        } else {
            Self(-(1i64 << (I + F - 1)))
        }
    };

    /// Forces compile-time validation of the type parameters.
    ///
    /// # Panics
    ///
    /// Panics at compile time if `I + F` is 0 or exceeds 64.
    #[inline(always)]
    pub(crate) const fn check() {
        assert!(I + F > 0, "Q type must have at least 1 bit");
        assert!(I + F <= 64, "Q type cannot exceed 64 bits");
    }

    /// Sign-extends a value from `TOTAL_BITS` to 64 bits.
    ///
    /// # Arguments
    ///
    /// * `raw` - The value to sign-extend, with valid data in the low
    ///   `I + F` bits.
    ///
    /// # Returns
    ///
    /// The sign-extended 64-bit value.
    #[inline]
    const fn sign_extend(raw: i64) -> i64 {
        if I + F >= 64 {
            raw
        } else {
            (raw << Self::SIGN_EXT_SHIFT) >> Self::SIGN_EXT_SHIFT
        }
    }

    /// Constructs from a raw bit representation.
    ///
    /// The value is masked to `I + F` bits and sign-extended.
    ///
    /// # Arguments
    ///
    /// * `raw` - The raw fixed-point value, sign-extended to i64.
    ///
    /// # Returns
    ///
    /// A new `Q<I, F>` holding the masked, sign-extended value.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if `raw` does not already fit in
    /// `I + F` bits (i.e., truncation would change the value).
    #[inline]
    pub const fn from_bits(raw: i64) -> Self {
        Self::check();
        let masked = if I + F >= 64 {
            raw
        } else {
            let m = (raw as u64) & Self::MASK;
            Self::sign_extend(m as i64)
        };
        debug_assert!(
            raw == masked,
            "from_bits: value out of range for this Q type"
        );
        Self(masked)
    }

    /// Extracts the raw bit representation, masked to `I + F` bits.
    ///
    /// # Returns
    ///
    /// The raw fixed-point value as a non-sign-extended `i64`.
    /// Only the low `I + F` bits are meaningful.
    #[inline]
    pub const fn to_bits(self) -> i64 {
        if I + F >= 64 {
            self.0
        } else {
            ((self.0 as u64) & Self::MASK) as i64
        }
    }

    /// Returns the internally stored sign-extended value.
    ///
    /// # Returns
    ///
    /// The raw i64 with sign extension to 64 bits.
    #[inline]
    pub(crate) const fn raw(self) -> i64 {
        self.0
    }

    /// Constructs from a sign-extended i64 without the `from_bits`
    /// debug range check.
    ///
    /// Masks and re-sign-extends to ensure internal consistency.
    ///
    /// # Arguments
    ///
    /// * `raw` - The value to store, which will be masked to `I + F` bits.
    ///
    /// # Returns
    ///
    /// A new `Q<I, F>` with the masked, sign-extended value.
    #[inline]
    pub(crate) const fn from_raw(raw: i64) -> Self {
        Self::check();
        if I + F >= 64 {
            Self(raw)
        } else {
            Self(Self::sign_extend((raw as u64 & Self::MASK) as i64))
        }
    }

    /// Constructs from an integer value by shifting left by `F`.
    ///
    /// # Arguments
    ///
    /// * `val` - The integer to convert.
    ///
    /// # Returns
    ///
    /// A new `Q<I, F>` representing `val` as a fixed-point value.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if `val` does not fit in `I` integer bits.
    #[inline]
    pub const fn from_int(val: i64) -> Self {
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
    pub const fn to_int(self) -> i64 {
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
    /// A new `Q<I, F>` representing the quantized value.
    #[inline]
    pub fn from_f64(val: f64) -> Self {
        Self::check();
        let scale = (1u64 << F) as f64;
        let raw = (val * scale) as i64;
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

    /// Wrapping negation (always wraps, never traps).
    ///
    /// # Returns
    ///
    /// The negated value, wrapped to `I + F` bits.
    #[inline]
    pub const fn wrapping_neg(self) -> Self {
        Self::from_raw(self.0.wrapping_neg())
    }

    /// Wrapping same-type multiply: `(self * rhs) >> F`, truncated to
    /// `I + F` bits.
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
    /// The truncated product in the same `Q<I, F>` format.
    #[inline]
    pub const fn wrapping_mul(self, rhs: Self) -> Self {
        let product = self.0 as i128 * rhs.0 as i128;
        let shifted = (product >> F) as i64;
        Self::from_raw(shifted)
    }

    /// Wrapping same-type divide: `(self << F) / rhs`, truncated to
    /// `I + F` bits.
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
    /// The truncated quotient in the same `Q<I, F>` format.
    #[inline]
    pub const fn wrapping_div(self, rhs: Self) -> Self {
        let numer = (self.0 as i128) << F;
        let result = (numer / rhs.0 as i128) as i64;
        Self::from_raw(result)
    }

    /// Widening multiply: `self * rhs` with full-precision output.
    ///
    /// The output type `Q<IO, FO>` must be wide enough to hold the
    /// product without loss.
    /// The output type is typically inferred from the assignment target.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand operand.
    ///
    /// # Returns
    ///
    /// The full-precision product in `Q<IO, FO>` format.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if `IO + FO < I + F + I2 + F2 - 1`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use qfixed::Q;
    /// let a = Q::<12, 4>::from_int(3);
    /// let b = Q::<12, 4>::from_int(4);
    /// let c: Q<24, 8> = a.widening_mul(b);
    /// assert_eq!(c.to_int(), 12);
    /// ```
    #[inline]
    pub fn widening_mul<const I2: u32, const F2: u32, const IO: u32, const FO: u32>(
        self,
        rhs: Q<I2, F2>,
    ) -> Q<IO, FO> {
        Q::<I2, F2>::check();
        Q::<IO, FO>::check();
        debug_assert!(
            IO + FO >= I + F + I2 + F2 - 1,
            "widening_mul: output Q<{}, {}> ({} bits) too narrow for Q<{}, {}> * Q<{}, {}> ({} bits needed)",
            IO, FO, IO + FO,
            I, F, I2, F2, I + F + I2 + F2 - 1
        );
        let product = self.0 as i128 * rhs.0 as i128;
        let frac_in = F + F2;
        let shift = frac_in as i32 - FO as i32;
        let result = if shift > 0 {
            product >> shift
        } else {
            product << (-shift)
        };
        Q::<IO, FO>::from_raw(result as i64)
    }

    /// Absolute value.
    ///
    /// # Returns
    ///
    /// The magnitude of `self`.
    ///
    /// # Panics
    ///
    /// In debug mode, panics on `MIN` (which has no positive counterpart).
    #[inline]
    pub const fn abs(self) -> Self {
        if self.0 < 0 {
            Self::from_raw(self.0.wrapping_neg())
        } else {
            self
        }
    }
}
