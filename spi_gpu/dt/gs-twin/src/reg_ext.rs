//! Helpers for constructing gpu-registers types from raw `u64` values.
//!
//! The generated register types are `#[repr(transparent)]` wrappers over `u64`,
//! but `from_raw()` lives on a `pub(crate)` trait and is inaccessible to
//! external crates.
//! Since the types are transparent newtypes, `transmute` from `u64` is
//! trivially sound.

/// Construct any `#[repr(transparent)]` register type from a raw 64-bit value.
///
/// # Safety rationale
///
/// All gpu-registers types are `#[repr(transparent)]` over `u64`, so this
/// transmute is a no-op at the machine level.
///
/// # Panics
///
/// Debug-asserts that `T` is exactly 8 bytes.
#[allow(unsafe_code)]
pub fn reg_from_raw<T: Copy>(raw: u64) -> T {
    debug_assert!(core::mem::size_of::<T>() == core::mem::size_of::<u64>());
    unsafe { core::mem::transmute_copy(&raw) }
}

/// Extract the raw 64-bit value from any `#[repr(transparent)]` register type.
///
/// # Safety rationale
///
/// All gpu-registers types are `#[repr(transparent)]` over `u64`, so this
/// transmute is a no-op at the machine level.
///
/// # Panics
///
/// Debug-asserts that `T` is exactly 8 bytes.
#[allow(unsafe_code)]
pub fn reg_to_raw<T: Copy>(reg: T) -> u64 {
    debug_assert!(core::mem::size_of::<T>() == core::mem::size_of::<u64>());
    unsafe { core::mem::transmute_copy(&reg) }
}
