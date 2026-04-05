//! Top-level tick logic and emulator entry point.
//!
//! The core pattern: `fn tick(prev: &GpuState, sdram: &mut SdramController) -> GpuState`
//!
//! All modules read from `prev` (previous cycle's registered state) and
//! produce their portion of the next state.  SDRAM is shared mutable
//! because it's 32 MB of sparse storage that shouldn't be cloned per tick.

use sdram_model::SdramController;

use crate::modules;
use crate::state::GpuState;

/// Top-level GPU emulator.
pub struct Emulator {
    /// Current GPU registered state.
    state: GpuState,
    /// SDRAM chip model (shared mutable, not double-buffered).
    sdram: SdramController,
}

impl Emulator {
    /// Create a new emulator with all modules in reset state.
    pub fn new() -> Self {
        Self {
            state: GpuState::new(),
            sdram: SdramController::new(),
        }
    }

    /// Advance one core clock cycle.
    pub fn step(&mut self) {
        self.state = tick(&self.state, &mut self.sdram);
    }

    /// Run for the specified number of core clock cycles.
    pub fn run(&mut self, cycles: u64) {
        for _ in 0..cycles {
            self.step();
        }
    }

    /// Immutable reference to the current GPU state.
    pub fn state(&self) -> &GpuState {
        &self.state
    }

    /// Mutable reference to the SDRAM model (for pre-loading memory).
    pub fn sdram_mut(&mut self) -> &mut SdramController {
        &mut self.sdram
    }

    /// Immutable reference to the SDRAM model.
    pub fn sdram(&self) -> &SdramController {
        &self.sdram
    }
}

impl Default for Emulator {
    fn default() -> Self {
        Self::new()
    }
}

/// Advance the GPU state by one core clock cycle.
///
/// All modules read from `prev` and produce their new state.
/// SDRAM is passed as shared mutable since it's too large to clone.
fn tick(prev: &GpuState, sdram: &mut SdramController) -> GpuState {
    let mut next = prev.clone();

    // Advance clock
    next.clock.tick();

    // Tick all modules (stubs for now — each returns prev state unchanged)
    next.rasterizer = modules::rasterizer_tick(prev);
    next.pixel_pipeline = modules::pixel_pipeline_tick(prev);
    next.memory = modules::memory_tick(prev, sdram);

    // Display ticks on pixel clock only
    if next.clock.pixel_tick() {
        next.display = modules::display_tick(prev);
    }

    next.infrastructure = modules::spi_tick(prev);

    next
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verify 1000 cycles run without panic and clock advances correctly.
    #[test]
    fn smoke_test_1000_cycles() {
        let mut emu = Emulator::new();
        emu.run(1000);
        // Should not panic; clock should have advanced
        assert_eq!(emu.state().clock.cycle(), 1000);
    }

    /// Verify pixel clock fires exactly 25 times in 100 core cycles (div 4).
    #[test]
    fn pixel_clock_fires_correctly() {
        let mut emu = Emulator::new();
        let mut pixel_ticks = 0u32;

        for _ in 0..100 {
            emu.step();
            if emu.state().clock.pixel_tick() {
                pixel_ticks += 1;
            }
        }

        assert_eq!(pixel_ticks, 25); // 100 / 4
    }
}
