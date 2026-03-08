//! Alpha test — discard fragments based on alpha comparison.
//!
//! Compares the fragment's alpha channel against a reference value
//! using a configurable comparison function (same encoding as depth
//! compare).
//! Fragments that fail are discarded before alpha blending.
//!
//! # RTL Implementation Notes
//!
//! Can kill the fragment (✗).
//! Uses the same comparison function encoding as the depth test
//! (3-bit field in RENDER_MODE).

use super::fragment::ColoredFragment;
use gpu_registers::components::z_compare_e::ZCompareE;
use qfixed::Q;

/// Test a fragment's alpha against a reference value.
///
/// # Arguments
///
/// * `frag` - Colored fragment (after color combiner).
/// * `alpha_test_en` - Whether alpha testing is enabled.
/// * `alpha_func` - Comparison function (same encoding as depth compare).
/// * `alpha_ref` - Reference alpha value, Q4.12.
///
/// # Returns
///
/// `Some(frag)` if the fragment passes, `None` if discarded.
pub fn alpha_test(
    frag: ColoredFragment,
    _alpha_test_en: bool,
    _alpha_func: ZCompareE,
    _alpha_ref: Q<4, 12>,
) -> Option<ColoredFragment> {
    // TODO: implement alpha comparison
    Some(frag)
}
