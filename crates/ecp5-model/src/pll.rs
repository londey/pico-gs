//! ECP5 EHXPLLL — Simplified PLL Clock Model.
//!
//! Models the PLL as a cycle counter that produces tick signals for each
//! derived clock domain.  Does not model VCO, feedback, or jitter — just
//! the integer clock division ratios.
//!
//! In the pico-gs design (50 MHz input):
//! - `clk_core`:  100 MHz (reference clock — every tick)
//! - `clk_pixel`:  25 MHz (core / 4)
//! - `clk_tmds`:  250 MHz (core × 2.5 — modeled as ticking every cycle
//!   with a note that in hardware this is a higher-frequency domain)
//! - `clk_sdram`: 100 MHz, 90° phase shift (same frequency as core;
//!   phase is not modeled)

/// PLL configuration (clock division ratios relative to core clock).
#[derive(Debug, Clone)]
pub struct PllConfig {
    /// Core-to-pixel clock divider.  Pixel clock ticks every `pixel_div`
    /// core cycles.
    pub pixel_div: u32,
    /// Number of core cycles before the PLL reports lock.
    pub lock_delay: u64,
}

impl Default for PllConfig {
    fn default() -> Self {
        Self {
            pixel_div: 4,
            lock_delay: 200,
        }
    }
}

/// Output signals from the PLL on a given core cycle.
#[derive(Debug, Clone, Copy, Default)]
pub struct PllOutputs {
    /// Core clock tick (always true — this is the reference).
    pub clk_core_tick: bool,
    /// Pixel clock tick (true every `pixel_div` core cycles).
    pub clk_pixel_tick: bool,
    /// SDRAM clock tick (same frequency as core; phase not modeled).
    pub clk_sdram_tick: bool,
    /// PLL lock indicator.
    pub locked: bool,
}

/// ECP5 EHXPLLL simplified clock model.
#[derive(Debug, Clone)]
pub struct Pll {
    config: PllConfig,
    cycle: u64,
}

impl Pll {
    /// Create a new PLL with the given configuration.
    pub fn new(config: PllConfig) -> Self {
        Self { config, cycle: 0 }
    }

    /// Advance one core clock cycle and return the derived clock signals.
    pub fn tick(&mut self) -> PllOutputs {
        let outputs = PllOutputs {
            clk_core_tick: true,
            clk_pixel_tick: self.cycle.is_multiple_of(u64::from(self.config.pixel_div)),
            clk_sdram_tick: true,
            locked: self.cycle >= self.config.lock_delay,
        };
        self.cycle += 1;
        outputs
    }

    /// Current cycle count.
    pub fn cycle(&self) -> u64 {
        self.cycle
    }
}

impl Default for Pll {
    fn default() -> Self {
        Self::new(PllConfig::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verify pixel clock fires exactly every 4th core cycle.
    #[test]
    fn pixel_clock_divides_by_4() {
        let mut pll = Pll::default();
        let mut pixel_ticks = 0u32;

        for _ in 0..100 {
            let out = pll.tick();
            assert!(out.clk_core_tick);
            if out.clk_pixel_tick {
                pixel_ticks += 1;
            }
        }

        assert_eq!(pixel_ticks, 25); // 100 / 4
    }

    /// Verify PLL reports unlocked until lock_delay cycles have elapsed.
    #[test]
    fn lock_after_delay() {
        let mut pll = Pll::new(PllConfig {
            lock_delay: 10,
            ..PllConfig::default()
        });

        for _ in 0..10 {
            let out = pll.tick();
            assert!(!out.locked);
        }

        let out = pll.tick();
        assert!(out.locked);
    }
}
