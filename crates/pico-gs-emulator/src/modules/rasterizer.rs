//! Rasterizer module tick (stub).

use crate::state::{GpuState, RasterizerState};

/// Advance the rasterizer by one core clock cycle.
pub fn rasterizer_tick(prev: &GpuState) -> RasterizerState {
    prev.rasterizer.clone()
}
