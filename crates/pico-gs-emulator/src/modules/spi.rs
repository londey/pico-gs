//! SPI + register file module tick (stub).

use crate::state::{GpuState, InfraState};

/// Advance the SPI/register infrastructure by one core clock cycle.
pub fn spi_tick(prev: &GpuState) -> InfraState {
    prev.infrastructure.clone()
}
