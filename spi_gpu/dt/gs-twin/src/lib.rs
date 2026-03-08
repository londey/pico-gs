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
pub mod math;
pub mod mem;
pub mod pipeline;
pub mod test_harness;

/// Top-level GPU model. Holds memory state and pipeline configuration.
/// Feed it a command stream, get a framebuffer out.
pub struct Gpu {
    pub state: pipeline::GpuState,
    pub memory: mem::GpuMemory,
}

impl Gpu {
    /// Create a GPU with the given framebuffer dimensions.
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            state: pipeline::GpuState::default(),
            memory: mem::GpuMemory::new(width, height),
        }
    }

    /// Execute a complete command stream.
    pub fn execute(&mut self, commands: &[cmd::GpuCommand]) {
        for command in commands {
            self.step(command);
        }
    }

    /// Execute a single GPU command.
    pub fn step(&mut self, command: &cmd::GpuCommand) {
        pipeline::command_proc::execute(command, &mut self.state, &mut self.memory);
    }

    /// Export the current framebuffer as a PNG image.
    pub fn framebuffer_to_png(&self, path: &std::path::Path) -> Result<(), image::ImageError> {
        self.memory.framebuffer.save_png(path)
    }
}
