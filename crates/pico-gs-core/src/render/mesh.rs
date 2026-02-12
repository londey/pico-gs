//! Mesh rendering: transform, light, and submit triangles.
//!
//! Processes a static mesh (positions + normals + indices) through the
//! MVP transform -> Gouraud lighting -> GPU vertex packing pipeline,
//! then calls an enqueue closure for each ScreenTriangleCommand.

use crate::gpu::vertex::GpuVertex;
use crate::render::lighting::compute_lighting;
use crate::render::transform::{is_front_facing, transform_normal, transform_vertex, ScreenVertex};
use crate::render::{AmbientLight, DirectionalLight, RenderCommand, ScreenTriangleCommand};
use glam::{Mat4, Vec3};

/// Maximum vertices supported in a single mesh render call.
const MAX_TRANSFORMED: usize = 148;

/// Cached per-vertex transform + lighting result.
#[derive(Clone, Copy)]
struct TransformedVertex {
    screen: ScreenVertex,
    color: [u8; 4],
}

/// A reference to static mesh data for rendering.
/// Decouples the render pipeline from any specific mesh storage format.
pub struct MeshRef<'a> {
    pub positions: &'a [Vec3],
    pub normals: &'a [Vec3],
    pub indices: &'a [[u16; 3]],
}

/// Render a mesh for one frame: transform all vertices, then submit
/// front-facing triangles as ScreenTriangleCommands.
///
/// The `enqueue` closure handles backpressure (SPSC queue on RP2350,
/// direct execution on PC).
pub fn render_mesh<F>(
    mesh: &MeshRef<'_>,
    mvp: &Mat4,
    mv: &Mat4,
    base_color: [u8; 4],
    lights: &[DirectionalLight; 4],
    ambient: &AmbientLight,
    mut enqueue: F,
) where
    F: FnMut(RenderCommand),
{
    // Phase 1: Transform all vertices and compute lighting.
    let mut transformed = [TransformedVertex {
        screen: ScreenVertex {
            x: 0.0,
            y: 0.0,
            z: 0.0,
            w: 1.0,
        },
        color: [0; 4],
    }; MAX_TRANSFORMED];

    let vert_count = mesh.positions.len().min(MAX_TRANSFORMED);
    for i in 0..vert_count {
        let pos = mesh.positions[i];
        let norm = mesh.normals[i];

        let screen = transform_vertex(pos, mvp);
        let eye_normal = transform_normal(norm, mv);
        let color = compute_lighting(eye_normal, base_color, lights, ambient);

        transformed[i] = TransformedVertex { screen, color };
    }

    // Phase 2: Submit front-facing triangles.
    for &[i0, i1, i2] in mesh.indices {
        let (i0, i1, i2) = (i0 as usize, i1 as usize, i2 as usize);

        if i0 >= vert_count || i1 >= vert_count || i2 >= vert_count {
            continue;
        }

        let tv0 = &transformed[i0];
        let tv1 = &transformed[i1];
        let tv2 = &transformed[i2];

        // Back-face culling.
        if !is_front_facing(&tv0.screen, &tv1.screen, &tv2.screen) {
            continue;
        }

        // Pack into GpuVertex format.
        let gv0 = screen_to_gpu(&tv0.screen, tv0.color);
        let gv1 = screen_to_gpu(&tv1.screen, tv1.color);
        let gv2 = screen_to_gpu(&tv2.screen, tv2.color);

        enqueue(RenderCommand::SubmitScreenTriangle(ScreenTriangleCommand {
            v0: gv0,
            v1: gv1,
            v2: gv2,
            textured: false,
        }));
    }
}

/// Convert a screen-space vertex + color into a packed GpuVertex.
fn screen_to_gpu(sv: &ScreenVertex, color: [u8; 4]) -> GpuVertex {
    GpuVertex::from_color_position(color[0], color[1], color[2], color[3], sv.x, sv.y, sv.z)
}
