//! Command processor.
//!
//! Interprets GPU commands (register writes, draw calls) and dispatches
//! draw operations through the pipeline. This mirrors the RTL's SPI
//! command decoder + state machine.

use crate::cmd::{GpuCommand, Vertex};
use crate::mem::GpuMemory;
use crate::pipeline::{self, GpuState, Viewport};

/// Process a single GPU command, updating state and/or rendering.
pub fn execute(cmd: &GpuCommand, state: &mut GpuState, memory: &mut GpuMemory) {
    match cmd {
        GpuCommand::Nop => {}

        GpuCommand::SetMvpMatrix(mat) => {
            state.mvp = *mat;
        }

        GpuCommand::SetViewport {
            x,
            y,
            width,
            height,
        } => {
            state.viewport = Viewport {
                x: *x,
                y: *y,
                width: *width,
                height: *height,
            };
        }

        GpuCommand::ClearColor(color) => {
            memory.framebuffer.clear(*color);
        }

        GpuCommand::ClearDepth(value) => {
            memory.depth_buffer.clear_raw(*value);
        }

        GpuCommand::LoadVertices {
            base_addr: _,
            vertices: _,
        } => {
            // TODO: serialize vertices into vertex_sram at base_addr.
            // For now, draw commands use the immediate-mode path below.
        }

        GpuCommand::LoadIndices {
            base_addr: _,
            indices: _,
        } => {
            // TODO: store indices in SRAM
        }

        GpuCommand::LoadTexture {
            slot,
            width,
            height,
            data,
        } => {
            memory.textures.slots[*slot as usize] = Some(crate::mem::Texture {
                width: *width,
                height: *height,
                data: data.clone(),
            });
        }

        GpuCommand::SetDepthTest(func) => {
            state.depth_func = *func;
        }

        GpuCommand::SetCullMode(mode) => {
            state.cull_mode = *mode;
        }

        GpuCommand::BindTexture(slot) => {
            state.bound_texture = Some(*slot);
        }

        GpuCommand::DrawArrays {
            base_addr: _,
            vertex_count: _,
        } => {
            // TODO: read vertices from SRAM and dispatch through pipeline.
        }

        GpuCommand::DrawIndexed {
            vertex_base: _,
            index_base: _,
            index_count: _,
        } => {
            // TODO: indexed draw from SRAM.
        }
    }
}

/// Immediate-mode draw: takes vertices directly, runs full pipeline.
///
/// This is the primary "golden reference" path. Test fixtures call this
/// with known vertex data and compare framebuffer output against
/// Verilator dumps.
pub fn draw_triangles(vertices: &[Vertex], state: &GpuState, memory: &mut GpuMemory) {
    for tri_verts in vertices.chunks_exact(3) {
        // 1. Vertex stage: transform to clip space
        let clip_verts: Vec<_> = tri_verts
            .iter()
            .map(|v| pipeline::vertex::transform(v, &state.mvp))
            .collect();

        // 2. Clip + cull + viewport project
        let Some(screen_tri) = pipeline::clip::clip_and_project(
            &clip_verts[0],
            &clip_verts[1],
            &clip_verts[2],
            &state.viewport,
            state.cull_mode,
        ) else {
            continue;
        };

        // 3. Rasterize: generate fragments
        let fragments = pipeline::rasterize::rasterize_triangle(&screen_tri);

        // 4. Fragment stage: depth test + texturing + framebuffer write
        for frag in fragments {
            pipeline::fragment::process_fragment(&frag, state, memory);
        }
    }
}
