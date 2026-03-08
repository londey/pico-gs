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
//!  │  Framebuffer  │  RGB565 framebuffer + u16 Z-buffer
//!  └──────────────┘
//!         │
//!         ▼  .save_png() / .pixels (raw compare)
//!      golden reference
//! ```

pub mod cmd;
pub mod hex_parser;
pub mod math;
pub mod mem;
pub mod pipeline;
pub mod reg;
pub mod test_harness;

/// Top-level GPU model.
/// Holds memory state and the register file matching the RTL's register_file.sv.
///
/// The only interface is `reg_write()` / `reg_write_script()` with raw
/// register addresses and data, matching the RTL for bit-exact golden reference.
pub struct Gpu {
    pub memory: mem::GpuMemory,
    /// Register file state matching register_file.sv.
    pub regs: reg::RegisterFile,
}

impl Gpu {
    /// Create a GPU with the given framebuffer dimensions.
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            memory: mem::GpuMemory::new(width, height),
            regs: reg::RegisterFile::default(),
        }
    }

    /// Process a single register write (RTL-matching interface).
    ///
    /// Each call mirrors one SPI register write as consumed by register_file.sv.
    pub fn reg_write(&mut self, addr: u8, data: u64) {
        self.regs.write(addr, data, &mut self.memory);
    }

    /// Process a sequence of register writes.
    pub fn reg_write_script(&mut self, script: &[reg::RegWrite]) {
        for rw in script {
            self.reg_write(rw.addr, rw.data);
        }
    }

    /// Export the current framebuffer as a PNG image.
    pub fn framebuffer_to_png(&self, path: &std::path::Path) -> Result<(), image::ImageError> {
        self.memory.framebuffer.save_png(path)
    }
}
