// Spec-ref: unit_021_core_1_render_executor.md `2ea56d6fed942e2b` 2026-02-19
//! Render command execution: clear, triangle submit, texture upload, vsync.
//!
//! Generic over `SpiTransport + FlowControl` so it works on any platform.

use pico_gs_hal::{FlowControl, SpiTransport};

use crate::gpu::driver::{GpuDriver, GpuError};
use crate::gpu::registers;
use crate::gpu::vertex::GpuVertex;
use crate::render::{ClearCommand, RenderCommand, ScreenTriangleCommand, UploadTextureCommand};

/// Texture metadata for the command executor.
pub struct TextureInfo<'a> {
    pub data: &'a [u64],
    pub width: u16,
    pub height: u16,
    pub width_log2: u8,
    pub height_log2: u8,
}

/// Trait for looking up texture data by ID.
pub trait TextureSource {
    fn get_texture(&self, id: u8) -> Option<TextureInfo<'_>>;
}

/// Execute a single render command against the GPU.
pub fn execute<S: SpiTransport + FlowControl>(
    gpu: &mut GpuDriver<S>,
    cmd: &RenderCommand,
    textures: &dyn TextureSource,
) -> Result<(), GpuError<S::Error>> {
    match cmd {
        RenderCommand::ClearFramebuffer(clear) => execute_clear(gpu, clear),
        RenderCommand::WaitVsync => execute_vsync(gpu),
        RenderCommand::SubmitScreenTriangle(tri) => execute_screen_triangle(gpu, tri),
        RenderCommand::SetRenderMode(flags) => {
            gpu.write(registers::RENDER_MODE, flags.to_render_mode())
        }
        RenderCommand::SetZRange { z_min, z_max } => gpu.set_z_range(*z_min, *z_max),
        RenderCommand::UploadTexture(upload_cmd) => {
            execute_upload_texture(gpu, upload_cmd, textures)
        }
    }
}

/// Submit a pre-packed screen-space triangle to the GPU.
fn execute_screen_triangle<S: SpiTransport>(
    gpu: &mut GpuDriver<S>,
    cmd: &ScreenTriangleCommand,
) -> Result<(), GpuError<S::Error>> {
    gpu.submit_triangle(&cmd.v0, &cmd.v1, &cmd.v2, cmd.textured)
}

/// Clear framebuffer by rendering two full-viewport triangles.
fn execute_clear<S: SpiTransport>(
    gpu: &mut GpuDriver<S>,
    cmd: &ClearCommand,
) -> Result<(), GpuError<S::Error>> {
    let [r, g, b, a] = cmd.color;

    // Flat shading, color-write enabled, no depth.
    gpu.write(registers::RENDER_MODE, registers::RENDER_MODE_COLOR_WRITE)?;
    gpu.write(registers::COLOR, crate::gpu::vertex::pack_color(r, g, b, a))?;

    // Two triangles covering 640x480 viewport.
    let v00 = GpuVertex::from_color_position(r, g, b, a, 0.0, 0.0, 0.0);
    let v10 = GpuVertex::from_color_position(r, g, b, a, 639.0, 0.0, 0.0);
    let v11 = GpuVertex::from_color_position(r, g, b, a, 639.0, 479.0, 0.0);
    let v01 = GpuVertex::from_color_position(r, g, b, a, 0.0, 479.0, 0.0);

    gpu.submit_triangle(&v00, &v10, &v11, false)?;
    gpu.submit_triangle(&v00, &v11, &v01, false)?;

    if cmd.clear_depth {
        // Z-only pass: ALWAYS compare, Z-write enabled, no color write.
        gpu.write(
            registers::RENDER_MODE,
            registers::RENDER_MODE_Z_TEST
                | registers::RENDER_MODE_Z_WRITE
                | registers::Z_COMPARE_ALWAYS,
        )?;

        // Full-screen triangles at far plane depth.
        let far_v00 = GpuVertex::from_color_position(0, 0, 0, 0, 0.0, 0.0, 1.0);
        let far_v10 = GpuVertex::from_color_position(0, 0, 0, 0, 639.0, 0.0, 1.0);
        let far_v11 = GpuVertex::from_color_position(0, 0, 0, 0, 639.0, 479.0, 1.0);
        let far_v01 = GpuVertex::from_color_position(0, 0, 0, 0, 0.0, 479.0, 1.0);

        gpu.submit_triangle(&far_v00, &far_v10, &far_v11, false)?;
        gpu.submit_triangle(&far_v00, &far_v11, &far_v01, false)?;
    }

    Ok(())
}

/// Upload texture data to GPU SRAM and configure texture unit 0.
fn execute_upload_texture<S: SpiTransport>(
    gpu: &mut GpuDriver<S>,
    cmd: &UploadTextureCommand,
    textures: &dyn TextureSource,
) -> Result<(), GpuError<S::Error>> {
    let tex = match textures.get_texture(cmd.texture_id) {
        Some(t) => t,
        None => return Ok(()), // Invalid texture ID — skip silently.
    };

    // Upload pixel data via MEM_ADDR/MEM_DATA.
    gpu.upload_memory(cmd.gpu_dword_addr, tex.data)?;

    // Configure TEX0.
    gpu.write(registers::TEX0_BASE, cmd.gpu_dword_addr as u64)?;

    // TEX0_FMT: swizzle=RGBA(0), height_log2, width_log2, not compressed, enabled.
    let fmt: u64 = ((tex.height_log2 as u64) << 8)
        | ((tex.width_log2 as u64) << 4)
        // bit 1 = 0 (not compressed), bit 0 = 1 (enabled)
        | 1;
    gpu.write(registers::TEX0_FMT, fmt)?;

    // REPEAT wrapping on both axes.
    gpu.write(registers::TEX0_WRAP, 0)?;

    Ok(())
}

/// Wait for vsync and swap framebuffers.
fn execute_vsync<S: SpiTransport + FlowControl>(
    gpu: &mut GpuDriver<S>,
) -> Result<(), GpuError<S::Error>> {
    gpu.wait_vsync();
    gpu.swap_buffers()
}
