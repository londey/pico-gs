//! Display module tick (stub).

use crate::state::{DisplayState, GpuState};

/// Advance the display module by one pixel clock cycle.
pub fn display_tick(prev: &GpuState) -> DisplayState {
    prev.display.clone()
}
