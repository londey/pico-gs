// Spec-ref: unit_026_intercore_queue.md `b6e2e8bae3f95390` 2026-02-12
//! Inter-core SPSC command queue types (RP2350-specific).

use pico_gs_core::render::RenderCommand;

/// Render command queue capacity.
///
/// Teapot demo submits ~290 commands per frame (clear + mode + ~288 triangles + vsync).
/// Queue depth of 64 allows Core 0 to run ahead of Core 1 by up to 64 commands.
///
/// Memory: 64 x ~80 bytes (largest variant) = 5 KB SRAM.
pub const QUEUE_CAPACITY: usize = 64;

/// The inter-core render command queue type.
pub type CommandQueue = heapless::spsc::Queue<RenderCommand, QUEUE_CAPACITY>;
/// Producer end of the command queue (owned by Core 0).
pub type CommandProducer<'a> = heapless::spsc::Producer<'a, RenderCommand>;
/// Consumer end of the command queue (owned by Core 1).
pub type CommandConsumer<'a> = heapless::spsc::Consumer<'a, RenderCommand>;
