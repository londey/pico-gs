//! Conversion operations between `Q` and `UQ` types and integer primitives.

use crate::q::Q;
use crate::uq::UQ;

// ---------------------------------------------------------------------------
// Q<I, F>: widen, truncate, saturate, reformat, to_unsigned
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> Q<I, F> {
    /// Lossless widening to a larger `Q` type.
    ///
    /// The output must have at least as many integer and fractional bits
    /// as the input.
    ///
    /// # Returns
    ///
    /// The same value in `Q<IO, FO>` format.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if `IO < I` or `FO < F`.
    #[inline]
    pub fn widen<const IO: u32, const FO: u32>(self) -> Q<IO, FO> {
        Q::<IO, FO>::check();
        debug_assert!(IO >= I, "widen: output integer bits must be >= input");
        debug_assert!(FO >= F, "widen: output fractional bits must be >= input");
        let shift = FO as i32 - F as i32;
        let widened = if shift >= 0 {
            self.raw() << shift
        } else {
            self.raw() >> (-shift)
        };
        Q::<IO, FO>::from_raw(widened)
    }

    /// Narrowing conversion with truncation toward zero.
    ///
    /// Models Verilog's sized assignment: excess bits are dropped.
    ///
    /// # Returns
    ///
    /// The truncated value in `Q<IO, FO>` format.
    #[inline]
    pub fn truncate<const IO: u32, const FO: u32>(self) -> Q<IO, FO> {
        Q::<IO, FO>::check();
        let shift = F as i32 - FO as i32;
        let shifted = if shift >= 0 {
            self.raw() >> shift
        } else {
            self.raw() << (-shift)
        };
        Q::<IO, FO>::from_raw(shifted)
    }

    /// Narrowing conversion with saturation (clamp to destination range).
    ///
    /// # Returns
    ///
    /// The value clamped to fit in `Q<IO, FO>`.
    #[inline]
    pub fn saturate<const IO: u32, const FO: u32>(self) -> Q<IO, FO> {
        Q::<IO, FO>::check();
        let shift = F as i32 - FO as i32;
        let shifted = if shift >= 0 {
            self.raw() >> shift
        } else {
            self.raw() << (-shift)
        };
        let clamped = shifted.clamp(Q::<IO, FO>::MIN.raw(), Q::<IO, FO>::MAX.raw());
        Q::<IO, FO>::from_raw(clamped)
    }

    /// General-purpose format conversion that adjusts the fractional point.
    ///
    /// Use `widen` when you know the conversion is lossless, or
    /// `truncate`/`saturate` when narrowing.
    ///
    /// # Returns
    ///
    /// The value in `Q<IO, FO>` format, with fractional bits shifted
    /// accordingly.
    #[inline]
    pub fn reformat<const IO: u32, const FO: u32>(self) -> Q<IO, FO> {
        Q::<IO, FO>::check();
        let shift = FO as i32 - F as i32;
        let shifted = if shift >= 0 {
            self.raw() << shift
        } else {
            self.raw() >> (-shift)
        };
        Q::<IO, FO>::from_raw(shifted)
    }

    /// Converts signed `Q` to unsigned `UQ`, clamping negative values to
    /// zero.
    ///
    /// # Returns
    ///
    /// The value as `UQ<IO, FO>`, or `UQ::ZERO` if `self` is negative.
    #[inline]
    pub fn to_unsigned<const IO: u32, const FO: u32>(self) -> UQ<IO, FO> {
        UQ::<IO, FO>::check();
        if self.raw() < 0 {
            return UQ::<IO, FO>::ZERO;
        }
        let shift = FO as i32 - F as i32;
        let shifted = if shift >= 0 {
            (self.raw() as u64) << shift
        } else {
            (self.raw() as u64) >> (-shift)
        };
        UQ::<IO, FO>::from_raw(shifted)
    }
}

// ---------------------------------------------------------------------------
// UQ<I, F>: widen, truncate, saturate, reformat, to_signed
// ---------------------------------------------------------------------------

impl<const I: u32, const F: u32> UQ<I, F> {
    /// Lossless widening to a larger `UQ` type.
    ///
    /// # Returns
    ///
    /// The same value in `UQ<IO, FO>` format.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if `IO < I` or `FO < F`.
    #[inline]
    pub fn widen<const IO: u32, const FO: u32>(self) -> UQ<IO, FO> {
        UQ::<IO, FO>::check();
        debug_assert!(IO >= I, "widen: output integer bits must be >= input");
        debug_assert!(FO >= F, "widen: output fractional bits must be >= input");
        let shift = FO as i32 - F as i32;
        let widened = if shift >= 0 {
            self.raw() << shift
        } else {
            self.raw() >> (-shift)
        };
        UQ::<IO, FO>::from_raw(widened)
    }

    /// Narrowing conversion with truncation.
    ///
    /// # Returns
    ///
    /// The truncated value in `UQ<IO, FO>` format.
    #[inline]
    pub fn truncate<const IO: u32, const FO: u32>(self) -> UQ<IO, FO> {
        UQ::<IO, FO>::check();
        let shift = F as i32 - FO as i32;
        let shifted = if shift >= 0 {
            self.raw() >> shift
        } else {
            self.raw() << (-shift)
        };
        UQ::<IO, FO>::from_raw(shifted)
    }

    /// Narrowing conversion with saturation.
    ///
    /// # Returns
    ///
    /// The value clamped to fit in `UQ<IO, FO>`.
    #[inline]
    pub fn saturate<const IO: u32, const FO: u32>(self) -> UQ<IO, FO> {
        UQ::<IO, FO>::check();
        let shift = F as i32 - FO as i32;
        let shifted = if shift >= 0 {
            self.raw() >> shift
        } else {
            self.raw() << (-shift)
        };
        let clamped = shifted.min(UQ::<IO, FO>::MAX.raw());
        UQ::<IO, FO>::from_raw(clamped)
    }

    /// General-purpose format conversion.
    ///
    /// # Returns
    ///
    /// The value in `UQ<IO, FO>` format, with fractional bits shifted
    /// accordingly.
    #[inline]
    pub fn reformat<const IO: u32, const FO: u32>(self) -> UQ<IO, FO> {
        UQ::<IO, FO>::check();
        let shift = FO as i32 - F as i32;
        let shifted = if shift >= 0 {
            self.raw() << shift
        } else {
            self.raw() >> (-shift)
        };
        UQ::<IO, FO>::from_raw(shifted)
    }

    /// Converts unsigned `UQ` to signed `Q`.
    ///
    /// # Returns
    ///
    /// The value as `Q<IO, FO>`.
    ///
    /// # Panics
    ///
    /// In debug mode, panics if the value does not fit in the signed
    /// range.
    #[inline]
    pub fn to_signed<const IO: u32, const FO: u32>(self) -> Q<IO, FO> {
        Q::<IO, FO>::check();
        let shift = FO as i32 - F as i32;
        let shifted = if shift >= 0 {
            (self.raw() as i64) << shift
        } else {
            (self.raw() as i64) >> (-shift)
        };
        debug_assert!(
            shifted >= Q::<IO, FO>::MIN.raw() && shifted <= Q::<IO, FO>::MAX.raw(),
            "to_signed: value does not fit in Q<{}, {}>",
            IO,
            FO
        );
        Q::<IO, FO>::from_raw(shifted)
    }
}

// ---------------------------------------------------------------------------
// From<integer> for Q<I, F>
// ---------------------------------------------------------------------------

macro_rules! impl_from_signed_int {
    ($($int:ty),*) => {
        $(
            impl<const I: u32, const F: u32> From<$int> for Q<I, F> {
                /// Converts an integer to `Q<I, F>` by shifting left by `F`.
                #[inline]
                fn from(val: $int) -> Self {
                    Self::from_int(val as i64)
                }
            }
        )*
    };
}

impl_from_signed_int!(i8, i16, i32, i64);

// ---------------------------------------------------------------------------
// From<integer> for UQ<I, F>
// ---------------------------------------------------------------------------

macro_rules! impl_from_unsigned_int {
    ($($int:ty),*) => {
        $(
            impl<const I: u32, const F: u32> From<$int> for UQ<I, F> {
                /// Converts an unsigned integer to `UQ<I, F>` by shifting
                /// left by `F`.
                #[inline]
                fn from(val: $int) -> Self {
                    Self::from_int(val as u64)
                }
            }
        )*
    };
}

impl_from_unsigned_int!(u8, u16, u32, u64);
