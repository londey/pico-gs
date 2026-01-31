//! Render command execution: clear, triangle submit, texture upload, vsync.

use crate::assets::textures;
use crate::gpu::registers;
use crate::gpu::vertex::GpuVertex;
use crate::gpu::GpuHandle;
use crate::render::{
    ClearCommand, RenderCommand, RenderFlags, ScreenTriangleCommand, UploadTextureCommand,
};

/// Execute a single render command against the GPU.
pub fn execute(gpu: &mut GpuHandle, cmd: &RenderCommand) {
    match cmd {
        RenderCommand::ClearFramebuffer(clear) => execute_clear(gpu, clear),
        RenderCommand::WaitVsync => execute_vsync(gpu),
        RenderCommand::SubmitScreenTriangle(tri) => execute_screen_triangle(gpu, tri),
        RenderCommand::SetTriMode(flags) => {
            gpu.write(registers::TRI_MODE, flags.to_tri_mode());
        }
        RenderCommand::UploadTexture(upload_cmd) => execute_upload_texture(gpu, upload_cmd),
    }
}

/// Submit a pre-packed screen-space triangle to the GPU.
fn execute_screen_triangle(gpu: &mut GpuHandle, cmd: &ScreenTriangleCommand) {
    gpu.submit_triangle(&cmd.v0, &cmd.v1, &cmd.v2, cmd.textured);
}

/// Clear framebuffer by rendering two full-viewport triangles.
fn execute_clear(gpu: &mut GpuHandle, cmd: &ClearCommand) {
    let [r, g, b, a] = cmd.color;

    // Flat shading, no texture, no depth for color clear.
    gpu.write(registers::TRI_MODE, 0);
    gpu.write(registers::COLOR, crate::gpu::vertex::pack_color(r, g, b, a));

    // Two triangles covering 640x480 viewport.
    let v00 = GpuVertex::from_color_position(r, g, b, a, 0.0, 0.0, 0.0);
    let v10 = GpuVertex::from_color_position(r, g, b, a, 639.0, 0.0, 0.0);
    let v11 = GpuVertex::from_color_position(r, g, b, a, 639.0, 479.0, 0.0);
    let v01 = GpuVertex::from_color_position(r, g, b, a, 0.0, 479.0, 0.0);

    gpu.submit_triangle(&v00, &v10, &v11, false);
    gpu.submit_triangle(&v00, &v11, &v01, false);

    if cmd.clear_depth {
        // Configure Z-buffer for ALWAYS compare, Z-write enabled.
        gpu.write(
            registers::FB_ZBUFFER,
            registers::Z_COMPARE_ALWAYS | registers::ZBUFFER_ADDR as u64,
        );
        gpu.write(
            registers::TRI_MODE,
            registers::TRI_MODE_Z_TEST | registers::TRI_MODE_Z_WRITE,
        );

        // Full-screen triangles at far plane depth.
        let far_v00 = GpuVertex::from_color_position(0, 0, 0, 0, 0.0, 0.0, 1.0);
        let far_v10 = GpuVertex::from_color_position(0, 0, 0, 0, 639.0, 0.0, 1.0);
        let far_v11 = GpuVertex::from_color_position(0, 0, 0, 0, 639.0, 479.0, 1.0);
        let far_v01 = GpuVertex::from_color_position(0, 0, 0, 0, 0.0, 479.0, 1.0);

        gpu.submit_triangle(&far_v00, &far_v10, &far_v11, false);
        gpu.submit_triangle(&far_v00, &far_v11, &far_v01, false);

        // Restore LEQUAL compare.
        gpu.write(
            registers::FB_ZBUFFER,
            registers::Z_COMPARE_LEQUAL | registers::ZBUFFER_ADDR as u64,
        );
    }
}

/// Upload texture data to GPU SRAM and configure texture unit 0.
fn execute_upload_texture(gpu: &mut GpuHandle, cmd: &UploadTextureCommand) {
    let tex_id = cmd.texture_id as usize;
    if tex_id >= textures::TEXTURE_TABLE.len() {
        defmt::warn!("Invalid texture ID: {}", cmd.texture_id);
        return;
    }

    let tex = textures::TEXTURE_TABLE[tex_id];

    // Upload pixel data via MEM_ADDR/MEM_DATA.
    gpu.upload_memory(cmd.gpu_address, tex.data);

    // Configure TEX0.
    gpu.write(registers::TEX0_BASE, cmd.gpu_address as u64);

    // TEX0_FMT: swizzle=RGBA(0), height_log2, width_log2, not compressed, enabled.
    let fmt: u64 = (0u64 << 16)
        | ((tex.height_log2 as u64) << 8)
        | ((tex.width_log2 as u64) << 4)
        | (0 << 1) // not compressed
        | (1 << 0); // enabled
    gpu.write(registers::TEX0_FMT, fmt);

    // REPEAT wrapping on both axes.
    gpu.write(registers::TEX0_WRAP, 0);

    defmt::info!(
        "Texture {} uploaded: {}x{} at GPU addr 0x{:06X}",
        cmd.texture_id,
        tex.width,
        tex.height,
        cmd.gpu_address
    );
}

/// Wait for vsync and swap framebuffers.
fn execute_vsync(gpu: &mut GpuHandle) {
    gpu.wait_vsync();
    gpu.swap_buffers();
}
