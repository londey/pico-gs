//! GPU state hierarchy.
//!
//! All registered state in the GPU is captured in [`GpuState`].
//! Each sub-state struct corresponds to a pipeline.yaml unit group.
//! ECP5 primitive instances (block RAM, DSP) are owned by the module
//! state that uses them.

use crate::clock::ClockState;

/// Top-level GPU registered state.
///
/// This struct is cloned each tick: modules read from `&prev` and produce
/// their portion of the next state.
#[derive(Debug, Clone)]
pub struct GpuState {
    /// Clock domain state.
    pub clock: ClockState,

    /// Rasterizer pipeline (triangle setup, block rasterize, Hi-Z, fragment).
    pub rasterizer: RasterizerState,

    /// Pixel pipeline (stipple through pixel output).
    pub pixel_pipeline: PixelPipelineState,

    /// Display pipeline (scanout, color grade, DVI).
    pub display: DisplayState,

    /// Memory arbiter state.
    pub memory: MemoryArbiterState,

    /// Infrastructure (SPI, register file).
    pub infrastructure: InfraState,
}

impl GpuState {
    /// Create a new GPU state with all modules in their reset state.
    pub fn new() -> Self {
        Self {
            clock: ClockState::new(),
            rasterizer: RasterizerState::default(),
            pixel_pipeline: PixelPipelineState::default(),
            display: DisplayState::default(),
            memory: MemoryArbiterState::default(),
            infrastructure: InfraState::default(),
        }
    }
}

impl Default for GpuState {
    fn default() -> Self {
        Self::new()
    }
}

/// Rasterizer module state.
///
/// Pipeline.yaml: 2 DSP, 10 EBR (triangle_setup, block_rasterize, hiz_test,
/// fragment_rasterize).
#[derive(Debug, Clone, Default)]
pub struct RasterizerState {
    /// Placeholder for FSM state, pipeline registers, EBR/DSP instances.
    _placeholder: (),
}

/// Pixel pipeline module state.
///
/// Pipeline.yaml: 6 DSP, 18 EBR (stipple, z_cache, tex_sampler,
/// color_combiner, alpha_test, alpha_blend, dither, pixel_output).
#[derive(Debug, Clone, Default)]
pub struct PixelPipelineState {
    /// Placeholder for pipeline stage states.
    _placeholder: (),
}

/// Display module state.
///
/// Pipeline.yaml: 0 DSP, 3 EBR (scanout, color_grade, dvi_output).
#[derive(Debug, Clone, Default)]
pub struct DisplayState {
    /// Placeholder.
    _placeholder: (),
}

/// Memory arbiter state.
///
/// Manages SDRAM port arbitration between display, pixel pipeline,
/// Z-buffer cache, and texture sampler.
#[derive(Debug, Clone, Default)]
pub struct MemoryArbiterState {
    /// Placeholder for arbiter FSM.
    _placeholder: (),
}

/// Infrastructure state (SPI transport, register file).
#[derive(Debug, Clone, Default)]
pub struct InfraState {
    /// Placeholder.
    _placeholder: (),
}
