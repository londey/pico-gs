//! Pixel pipeline module tick (stub).

use crate::state::{GpuState, PixelPipelineState};

/// Advance the pixel pipeline by one core clock cycle.
pub fn pixel_pipeline_tick(prev: &GpuState) -> PixelPipelineState {
    prev.pixel_pipeline.clone()
}
