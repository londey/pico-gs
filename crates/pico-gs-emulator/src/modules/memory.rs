//! Memory arbiter module tick (stub).

use sdram_model::SdramController;

use crate::state::{GpuState, MemoryArbiterState};

/// Advance the memory arbiter by one core clock cycle.
pub fn memory_tick(prev: &GpuState, _sdram: &mut SdramController) -> MemoryArbiterState {
    prev.memory.clone()
}
