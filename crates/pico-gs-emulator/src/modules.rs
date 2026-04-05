//! GPU module tick functions.
//!
//! Each module is a pure function: `fn module_tick(prev: &GpuState) -> ModuleState`.
//! These are stubs that return the previous state unchanged.  Real
//! implementations will be added incrementally.

mod display;
mod memory;
mod pixel_pipeline;
mod rasterizer;
mod spi;

pub use display::display_tick;
pub use memory::memory_tick;
pub use pixel_pipeline::pixel_pipeline_tick;
pub use rasterizer::rasterizer_tick;
pub use spi::spi_tick;
