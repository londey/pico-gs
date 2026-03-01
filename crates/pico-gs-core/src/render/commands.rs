// Spec-ref: unit_021_core_1_render_executor.md `899cd15ce77a6291` 2026-02-25
//! Render command execution: clear, triangle submit, texture upload, vsync.
//!
//! Generic over `SpiTransport + FlowControl` so it works on any platform.

use pico_gs_hal::{FlowControl, SpiTransport};

use crate::gpu::driver::{GpuDriver, GpuError};
use crate::gpu::registers;
use crate::render::{ClearCommand, RenderCommand, ScreenTriangleCommand, UploadTextureCommand};

/// Convert RGBA8888 color to RGB565.
///
/// Drops the alpha channel. Red gets 5 bits, green 6, blue 5.
fn rgba_to_rgb565(r: u8, g: u8, b: u8) -> u16 {
    ((r as u16 >> 3) << 11) | ((g as u16 >> 2) << 5) | (b as u16 >> 3)
}

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

/// Clear framebuffer using hardware MEM_FILL (REQ-005.08).
///
/// Converts the RGBA8888 color to RGB565 and issues a MEM_FILL command for
/// the color buffer.  When `clear_depth` is true, a second MEM_FILL fills
/// the Z-buffer with `depth_value`.
///
/// Base addresses and surface dimensions are derived from the driver's
/// current draw framebuffer state (`GpuDriver::draw_fb()`).
fn execute_clear<S: SpiTransport>(
    gpu: &mut GpuDriver<S>,
    cmd: &ClearCommand,
) -> Result<(), GpuError<S::Error>> {
    let (color_base, z_base, width_log2, height_log2) = gpu.draw_fb();

    // Compute word count: width * height pixels, each pixel is one 16-bit word.
    let word_count = 1u32 << (width_log2 as u32 + height_log2 as u32);

    // Convert RGBA8888 to RGB565 for the color buffer fill.
    let [r, g, b, _a] = cmd.color;
    let rgb565 = rgba_to_rgb565(r, g, b);

    // MEM_FILL for color buffer.
    gpu.gpu_mem_fill(color_base, rgb565, word_count)?;

    // MEM_FILL for Z-buffer (if requested).
    if cmd.clear_depth {
        gpu.gpu_mem_fill(z_base, cmd.depth_value, word_count)?;
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

    // Configure TEX0 via unified TEX0_CFG register.
    // Pack base_addr (512-byte granularity), dimensions, wrapping, and enable.
    let base_512 = (cmd.gpu_dword_addr >> 6) as u16; // dword_addr >> 6 = byte_addr >> 9
    let cfg: u64 = (1u64) // ENABLE (bit 0)
        | ((tex.width_log2 as u64) << registers::TexCfgReg::WIDTH_LOG2_OFFSET)
        | ((tex.height_log2 as u64) << registers::TexCfgReg::HEIGHT_LOG2_OFFSET)
        | ((base_512 as u64) << registers::TexCfgReg::BASE_ADDR_OFFSET);
    gpu.write(registers::TEX0_CFG, cfg)?;

    Ok(())
}

/// Wait for vsync and swap framebuffers.
fn execute_vsync<S: SpiTransport + FlowControl>(
    gpu: &mut GpuDriver<S>,
) -> Result<(), GpuError<S::Error>> {
    gpu.wait_vsync();
    gpu.swap_buffers()
}
