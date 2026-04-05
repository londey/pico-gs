//! ECP5 MULT18X18D — 18×18 Signed Multiplier with Optional Pipeline.
//!
//! Models the ECP5 DSP multiplier block.  Accepts two 18-bit signed inputs
//! and produces a 36-bit signed output.
//!
//! Pipeline configuration is trait-based, matching the ECP5's synthesis-time
//! `REG_INPUTA`, `REG_INPUTB`, and `REG_OUTPUT` parameters.
//!
//! # Example
//!
//! ```
//! use ecp5_model::mult18x18d::*;
//!
//! // Combinational (0-latency) multiplier
//! let mut mul = Mult18x18d::<Combinational>::new();
//!
//! // Fully pipelined (input + output registers)
//! let mut mul_pipe = Mult18x18d::<Pipelined>::new();
//! ```

use std::marker::PhantomData;

// ---------------------------------------------------------------------------
// Pipeline configuration trait and implementations
// ---------------------------------------------------------------------------

/// Compile-time pipeline configuration for a MULT18X18D.
///
/// Determines which internal pipeline registers are enabled.
pub trait MulPipeline: Clone + std::fmt::Debug {
    /// Enable pipeline register on input A.
    const REG_INPUT_A: bool;

    /// Enable pipeline register on input B.
    const REG_INPUT_B: bool;

    /// Enable pipeline register on output.
    const REG_OUTPUT: bool;
}

/// Combinational multiplier — no pipeline registers (0 additional latency).
#[derive(Debug, Clone)]
pub struct Combinational;

/// Fully pipelined multiplier — input and output registers enabled.
#[derive(Debug, Clone)]
pub struct Pipelined;

/// Input-registered multiplier — input registers only, combinational output.
#[derive(Debug, Clone)]
pub struct InputRegistered;

impl MulPipeline for Combinational {
    const REG_INPUT_A: bool = false;
    const REG_INPUT_B: bool = false;
    const REG_OUTPUT: bool = false;
}

impl MulPipeline for Pipelined {
    const REG_INPUT_A: bool = true;
    const REG_INPUT_B: bool = true;
    const REG_OUTPUT: bool = true;
}

impl MulPipeline for InputRegistered {
    const REG_INPUT_A: bool = true;
    const REG_INPUT_B: bool = true;
    const REG_OUTPUT: bool = false;
}

// ---------------------------------------------------------------------------
// MULT18X18D struct
// ---------------------------------------------------------------------------

/// ECP5 MULT18X18D 18×18 signed multiplier.
///
/// # Type Parameters
///
/// * `P` - Pipeline configuration (e.g., [`Combinational`], [`Pipelined`]).
#[derive(Debug, Clone)]
pub struct Mult18x18d<P: MulPipeline> {
    /// Registered input A (used when `REG_INPUT_A` is true).
    reg_a: i32,

    /// Registered input B (used when `REG_INPUT_B` is true).
    reg_b: i32,

    /// Registered output (used when `REG_OUTPUT` is true).
    reg_p: i64,

    /// Current output value.
    output: i64,

    /// Marker for pipeline configuration.
    _marker: PhantomData<P>,
}

impl<P: MulPipeline> Mult18x18d<P> {
    /// Create a new multiplier with the compile-time pipeline configuration.
    pub fn new() -> Self {
        Self {
            reg_a: 0,
            reg_b: 0,
            reg_p: 0,
            output: 0,
            _marker: PhantomData,
        }
    }

    /// Advance one clock cycle.
    ///
    /// Inputs are 18-bit signed values (sign-extended from bits [17:0]).
    /// Output is a 36-bit signed product.
    ///
    /// Returns the output value from *before* this tick (matching the
    /// double-buffer pattern where consumers read the previous cycle's
    /// registered output).
    ///
    /// # Arguments
    ///
    /// * `a` - First 18-bit signed operand.
    /// * `b` - Second 18-bit signed operand.
    ///
    /// # Returns
    ///
    /// The 36-bit signed product from the previous cycle.
    pub fn tick(&mut self, a: i32, b: i32) -> i64 {
        let prev_output = self.output;

        // Sign-extend inputs to 18 bits
        let a_18 = sign_extend_18(a);
        let b_18 = sign_extend_18(b);

        // Input stage: registered or combinational
        let mul_a = if P::REG_INPUT_A {
            let prev_a = self.reg_a;
            self.reg_a = a_18;
            prev_a
        } else {
            a_18
        };

        let mul_b = if P::REG_INPUT_B {
            let prev_b = self.reg_b;
            self.reg_b = b_18;
            prev_b
        } else {
            b_18
        };

        // Multiply
        let product = i64::from(mul_a) * i64::from(mul_b);

        // Output stage: registered or combinational
        if P::REG_OUTPUT {
            self.output = self.reg_p;
            self.reg_p = product;
        } else {
            self.output = product;
        }

        prev_output
    }

    /// Current output value (available without ticking).
    pub fn output(&self) -> i64 {
        self.output
    }
}

impl<P: MulPipeline> Default for Mult18x18d<P> {
    fn default() -> Self {
        Self::new()
    }
}

/// Sign-extend a value from 18 bits to i32.
fn sign_extend_18(val: i32) -> i32 {
    (val << 14) >> 14
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verify combinational multiply produces correct result with no latency.
    #[test]
    fn combinational_multiply() {
        let mut mul = Mult18x18d::<Combinational>::new();

        mul.tick(7, 6);
        let out = mul.tick(0, 0);
        assert_eq!(out, 42);
    }

    /// Verify signed multiplication with negative operands.
    #[test]
    fn combinational_signed() {
        let mut mul = Mult18x18d::<Combinational>::new();

        mul.tick(-3, 5);
        let out = mul.tick(0, 0);
        assert_eq!(out, -15);
    }

    /// Verify fully pipelined mode has correct multi-cycle latency.
    #[test]
    fn pipelined_latency() {
        let mut mul = Mult18x18d::<Pipelined>::new();

        let out0 = mul.tick(10, 20);
        assert_eq!(out0, 0);

        let out1 = mul.tick(0, 0);
        assert_eq!(out1, 0);

        let out2 = mul.tick(0, 0);
        assert_eq!(out2, 0);

        // Result from cycle 0 inputs finally available
        let out3 = mul.tick(0, 0);
        assert_eq!(out3, 200);
    }

    /// Verify 18-bit sign extension treats 0x3FFFF as -1.
    #[test]
    fn sign_extension() {
        let mut mul = Mult18x18d::<Combinational>::new();
        mul.tick(0x3FFFF_u32 as i32, 100);
        let out = mul.tick(0, 0);
        assert_eq!(out, -100);
    }
}
