//! Clock domain modeling.
//!
//! Tracks which clock domains are active on a given core cycle.
//! The PLL derives all clocks from the 50 MHz board oscillator:
//!
//! - `clk_core`:  100 MHz (every tick)
//! - `clk_pixel`:  25 MHz (every 4th core tick)
//! - `clk_sdram`: 100 MHz (every tick, 90° phase not modeled)

use ecp5_model::{Pll, PllConfig, PllOutputs};

/// Clock domain state for the emulator.
#[derive(Debug, Clone)]
pub struct ClockState {
    /// PLL instance.
    pll: Pll,
    /// Outputs from the most recent PLL tick.
    outputs: PllOutputs,
}

impl ClockState {
    /// Create a new clock state with default PLL configuration.
    pub fn new() -> Self {
        Self {
            pll: Pll::new(PllConfig::default()),
            outputs: PllOutputs::default(),
        }
    }

    /// Advance one core clock cycle.
    pub fn tick(&mut self) {
        self.outputs = self.pll.tick();
    }

    /// Whether the pixel clock is active this cycle.
    pub fn pixel_tick(&self) -> bool {
        self.outputs.clk_pixel_tick
    }

    /// Whether the PLL is locked.
    pub fn locked(&self) -> bool {
        self.outputs.locked
    }

    /// Current core cycle count.
    pub fn cycle(&self) -> u64 {
        self.pll.cycle()
    }
}

impl Default for ClockState {
    fn default() -> Self {
        Self::new()
    }
}
