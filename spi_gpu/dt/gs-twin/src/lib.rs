//! # gs-twin
//!
//! Bit-accurate, transaction-level digital twin of the pico-gs ECP5
//! graphics synthesizer.
//!
//! This crate models the GPU pipeline as pure functions operating on
//! fixed-point types that match the RTL's wire formats bit-for-bit.
//! It is deliberately *not* cycle-accurate — Verilator owns that role.
//! Instead, gs-twin answers "what should the output look like?" at the
//! algorithm level, producing golden reference framebuffers that the
//! RTL's output must match exactly.
//!
//! ## Fixed-Point Contract
//!
//! Every numeric type in the pipeline uses the same Q format as the
//! corresponding RTL wire. The type aliases in [`math`] are the
//! authoritative specification for each format. If a Verilator dump
//! and the twin disagree on a pixel value, it's a real bug — not a
//! floating-point approximation artifact.
//!
//! ## Architecture
//!
//! ```text
//!  Command Stream (binary fixture)
//!        │
//!        ▼
//!  ┌─────────────┐
//!  │  cmd::Decoder│  parse GPU register writes / draw calls
//!  └──────┬──────┘
//!         │  Vec<GpuCommand>
//!         ▼
//!  ┌──────────────┐
//!  │  pipeline::   │
//!  │  CommandProc  │  interpret commands, update GpuState
//!  └──────┬───────┘
//!         │  DrawCall { vertices, state_snapshot }
//!         ▼
//!  ┌──────────────┐
//!  │  pipeline::   │
//!  │  VertexStage  │  MVP transform (Q16.16 fixed-point MAC)
//!  └──────┬───────┘
//!         │  Vec<ClipVertex> (Q16.16 clip coords)
//!         ▼
//!  ┌──────────────┐
//!  │  pipeline::   │
//!  │  Clip +       │  frustum reject, perspective divide,
//!  │  Viewport     │  viewport → Q12.4 screen coords
//!  └──────┬───────┘
//!         │  Vec<ScreenTriangle> (Q12.4 + Q4.12 depth)
//!         ▼
//!  ┌──────────────┐
//!  │  pipeline::   │
//!  │  Rasterizer   │  edge functions (Q16.16) → fragments
//!  └──────┬───────┘
//!         │  Vec<Fragment> (Q4.12 depth, Q2.14 UVs, RGB565)
//!         ▼
//!  ┌──────────────┐
//!  │  pipeline::   │
//!  │  FragmentStage│  depth test, texture sample, color write
//!  └──────┬───────┘
//!         │  pixel writes
//!         ▼
//!  ┌──────────────┐
//!  │  mem::        │
//!  │  Framebuffer  │  RGB565 framebuffer + Q4.12 Z-buffer
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

/// Top-level GPU model. Holds memory state and pipeline configuration.
///
/// Supports two interfaces:
/// - **High-level**: `execute()` / `step()` with [`cmd::GpuCommand`] variants
/// - **Low-level**: `reg_write()` with raw register addresses and data,
///   matching the RTL's register_file.sv for bit-exact golden reference
pub struct Gpu {
    pub state: pipeline::GpuState,
    pub memory: mem::GpuMemory,
    /// Register file state for the low-level register-write interface.
    pub regs: reg::RegisterFile,
}

impl Gpu {
    /// Create a GPU with the given framebuffer dimensions.
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            state: pipeline::GpuState::default(),
            memory: mem::GpuMemory::new(width, height),
            regs: reg::RegisterFile::default(),
        }
    }

    /// Execute a complete command stream (high-level GpuCommand interface).
    pub fn execute(&mut self, commands: &[cmd::GpuCommand]) {
        for command in commands {
            self.step(command);
        }
    }

    /// Execute a single GPU command (high-level interface).
    pub fn step(&mut self, command: &cmd::GpuCommand) {
        pipeline::command_proc::execute(command, &mut self.state, &mut self.memory);
    }

    /// Process a single register write (low-level RTL-matching interface).
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
