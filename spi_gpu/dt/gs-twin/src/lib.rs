#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
// Allow some pedantic lints that are too strict for this project
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::must_use_candidate)]
#![allow(clippy::missing_errors_doc)]
#![allow(clippy::missing_panics_doc)]
#![allow(clippy::enum_variant_names)]
// Until 1.0.0, allow dead code and unused dependency warnings
#![allow(dead_code)]
#![allow(unused_crate_dependencies)]

//! # gs-twin
//!
//! Bit-accurate, transaction-level digital twin of the pico-gs ECP5
//! graphics synthesizer.
//!
//! This crate models the GPU's register-write interface and integer-pixel
//! rasterizer, producing golden reference framebuffers that the RTL's
//! output must match exactly.
//! It is deliberately *not* cycle-accurate — Verilator owns that role.
//!
//! The GPU accepts pre-transformed screen-space vertices via 72-bit SPI
//! register writes.
//! All vertex transformation, clipping, and projection is performed by
//! the host CPU (RP2350), not the GPU hardware.
//!
//! ## Architecture
//!
//! ```text
//!  Register writes (hex script / test fixture)
//!        │
//!        ▼
//!  ┌──────────────┐
//!  │  reg::        │
//!  │  RegisterFile │  decode register writes, latch vertices
//!  └──────┬───────┘
//!         │  vertex kick → IntTriangle
//!         ▼
//!  ┌──────────────┐
//!  │  pipeline::   │
//!  │  rasterize    │  integer edge functions → IntFragment
//!  └──────┬───────┘
//!         │  depth test + color write
//!         ▼
//!  ┌──────────────┐
//!  │  mem::        │
//!  │  SDRAM        │  flat 32 MiB backing store, 4x4 tiled (INT-011)
//!  └──────────────┘
//!         │
//!         ▼  .save_png() / extract methods
//!      golden reference
//! ```

pub mod hex_parser;
pub mod math;
pub mod mem;
pub mod pipeline;
pub mod reg;
mod reg_ext;
pub mod test_harness;

/// Top-level GPU model.
///
/// Holds memory state and the register file matching the RTL's register_file.sv.
///
/// The only interface is `reg_write()` / `reg_write_script()` with raw
/// register addresses and data, matching the RTL for bit-exact golden reference.
pub struct Gpu {
    /// GPU memory (SDRAM, vertex SRAM, texture store).
    pub memory: mem::GpuMemory,

    /// Register file state matching register_file.sv.
    pub regs: reg::RegisterFile,

    /// Default framebuffer width (used when fb_config hasn't been set).
    pub default_width: u32,

    /// Default framebuffer height (used when fb_config hasn't been set).
    pub default_height: u32,
}

impl Gpu {
    /// Create a GPU with the given default framebuffer dimensions.
    ///
    /// # Arguments
    ///
    /// * `width` - Default framebuffer width in pixels.
    /// * `height` - Default framebuffer height in pixels.
    ///
    /// # Returns
    ///
    /// A new `Gpu` with zeroed 32 MiB SDRAM and default register state.
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            memory: mem::GpuMemory::new(),
            regs: reg::RegisterFile::default(),
            default_width: width,
            default_height: height,
        }
    }

    /// Process a single register write (RTL-matching interface).
    ///
    /// Each call mirrors one SPI register write as consumed by register_file.sv.
    ///
    /// # Arguments
    ///
    /// * `addr` - 7-bit register index (0..127).
    /// * `data` - 64-bit register data.
    pub fn reg_write(&mut self, addr: u8, data: u64) {
        self.regs.write(addr, data, &mut self.memory);
    }

    /// Process a sequence of register writes.
    ///
    /// # Arguments
    ///
    /// * `script` - Ordered slice of register write commands.
    pub fn reg_write_script(&mut self, script: &[reg::RegWrite]) {
        for rw in script {
            self.reg_write(rw.addr, rw.data);
        }
    }

    /// Get the effective framebuffer dimensions from fb_config,
    /// falling back to defaults if fb_config hasn't been programmed.
    fn effective_fb_dims(&self) -> (u16, u8, u32, u32) {
        let cfg = self.regs.fb_config();
        let wl2 = cfg.width_log2();
        if wl2 > 0 {
            let w = 1u32 << wl2;
            let h = 1u32 << cfg.height_log2();
            (cfg.color_base(), wl2, w, h)
        } else {
            // fb_config not yet programmed — use defaults
            // Assume color_base = 0, compute width_log2 from default_width
            let wl2 = (self.default_width as f64).log2().ceil() as u8;
            (0, wl2, self.default_width, self.default_height)
        }
    }

    /// Export the current framebuffer as a PNG image.
    ///
    /// # Arguments
    ///
    /// * `path` - Output file path for the PNG.
    ///
    /// # Errors
    ///
    /// Returns `image::ImageError` if the PNG cannot be written.
    pub fn framebuffer_to_png(&self, path: &std::path::Path) -> Result<(), image::ImageError> {
        let (base, wl2, w, h) = self.effective_fb_dims();
        self.memory.save_png(base, wl2, w, h, path)
    }

    /// Extract the current framebuffer as a linear `Vec<u16>` of RGB565 pixels.
    pub fn extract_framebuffer_rgb565(&self) -> Vec<u16> {
        let (base, wl2, w, h) = self.effective_fb_dims();
        self.memory.extract_rgb565_linear(base, wl2, w, h)
    }
}
