//! Utah Teapot mesh: body of revolution generated at runtime.
//!
//! Generates a low-poly teapot body (no spout/handle) suitable for the
//! Gouraud-lit spinning demo. 146 vertices, 288 triangles.

use crate::render::mesh::MeshRef;
use glam::Vec3;

/// Segments around the Y axis.
const SEGMENTS: usize = 16;

/// Teapot body profile: (radius, y) pairs from bottom cap to top cap.
/// First and last entries have radius=0 (cap vertices on the axis).
const PROFILE: [(f32, f32); 11] = [
    (0.00, -0.50), // bottom center (cap)
    (0.50, -0.50), // bottom rim
    (0.80, -0.35), // lower belly
    (0.95, -0.10), // widest lower
    (0.95, 0.10),  // widest upper
    (0.80, 0.30),  // upper belly
    (0.55, 0.50),  // shoulder
    (0.40, 0.60),  // neck
    (0.45, 0.65),  // rim lip
    (0.50, 0.70),  // rim top
    (0.00, 0.70),  // top center (cap)
];

const NUM_RINGS: usize = PROFILE.len() - 2; // 9 non-degenerate rings
const BODY_VERTS: usize = NUM_RINGS * SEGMENTS; // 144

/// Maximum vertex count for the teapot mesh.
pub const MAX_VERTICES: usize = BODY_VERTS + 2; // + bottom cap + top cap = 146

/// Maximum triangle count.
/// Bottom cap fan (16) + body quads (8 bands x 16 segments x 2) + top cap fan (16) = 288.
pub const MAX_TRIANGLES: usize = SEGMENTS * 2 + (NUM_RINGS - 1) * SEGMENTS * 2;

/// Pre-generated teapot mesh data (body of revolution).
pub struct TeapotMesh {
    pub positions: [Vec3; MAX_VERTICES],
    pub normals: [Vec3; MAX_VERTICES],
    pub indices: [[u16; 3]; MAX_TRIANGLES],
    pub vertex_count: usize,
    pub triangle_count: usize,
}

impl TeapotMesh {
    /// Generate the teapot mesh by revolving the body profile around the Y axis.
    ///
    /// Called once at startup on Core 0. Returns ~5 KB of mesh data.
    pub fn generate() -> Self {
        let mut positions = [Vec3::ZERO; MAX_VERTICES];
        let mut normals = [Vec3::ZERO; MAX_VERTICES];
        let mut indices = [[0u16; 3]; MAX_TRIANGLES];
        let mut vi = 0usize;
        let mut ti = 0usize;

        // Precompute sin/cos for each segment angle.
        let mut cos_tab = [0.0f32; SEGMENTS];
        let mut sin_tab = [0.0f32; SEGMENTS];
        let seg_f = SEGMENTS as f32;
        for s in 0..SEGMENTS {
            let angle = (s as f32) * core::f32::consts::TAU / seg_f;
            cos_tab[s] = libm::cosf(angle);
            sin_tab[s] = libm::sinf(angle);
        }

        // --- Bottom cap vertex (index 0) ---
        let bottom_idx = vi as u16;
        positions[vi] = Vec3::new(0.0, PROFILE[0].1, 0.0);
        normals[vi] = Vec3::NEG_Y;
        vi += 1;

        // --- Body ring vertices (profile indices 1..=9) ---
        let ring_base = vi;
        let num_profile = PROFILE.len();

        for p in 1..num_profile - 1 {
            let (r, y) = PROFILE[p];

            // Profile tangent for analytical normal computation.
            let (prev_r, prev_y) = PROFILE[p - 1];
            let next_p = if p + 1 < num_profile { p + 1 } else { p };
            let (next_r, next_y) = PROFILE[next_p];
            let tr = next_r - prev_r;
            let ty = next_y - prev_y;

            // Outward normal in profile plane: rotate tangent 90 degrees.
            let len = libm::sqrtf(ty * ty + tr * tr);
            let (nr, ny) = if len > 1e-6 {
                (ty / len, -tr / len)
            } else {
                (1.0, 0.0)
            };

            for s in 0..SEGMENTS {
                let cos_a = cos_tab[s];
                let sin_a = sin_tab[s];

                positions[vi] = Vec3::new(r * cos_a, y, r * sin_a);
                normals[vi] = Vec3::new(nr * cos_a, ny, nr * sin_a);
                vi += 1;
            }
        }

        // --- Top cap vertex ---
        let top_idx = vi as u16;
        positions[vi] = Vec3::new(0.0, PROFILE[num_profile - 1].1, 0.0);
        normals[vi] = Vec3::Y;
        vi += 1;

        // --- Bottom cap fan: bottom_idx -> first ring ---
        for s in 0..SEGMENTS {
            let next_s = (s + 1) % SEGMENTS;
            indices[ti] = [
                bottom_idx,
                (ring_base + next_s) as u16,
                (ring_base + s) as u16,
            ];
            ti += 1;
        }

        // --- Body quad strips between adjacent rings ---
        for ring in 0..NUM_RINGS - 1 {
            let base_curr = ring_base + ring * SEGMENTS;
            let base_next = ring_base + (ring + 1) * SEGMENTS;

            for s in 0..SEGMENTS {
                let next_s = (s + 1) % SEGMENTS;
                let a = (base_curr + s) as u16;
                let b = (base_curr + next_s) as u16;
                let c = (base_next + next_s) as u16;
                let d = (base_next + s) as u16;

                indices[ti] = [a, b, c];
                ti += 1;
                indices[ti] = [a, c, d];
                ti += 1;
            }
        }

        // --- Top cap fan: last ring -> top_idx ---
        let last_ring_base = ring_base + (NUM_RINGS - 1) * SEGMENTS;
        for s in 0..SEGMENTS {
            let next_s = (s + 1) % SEGMENTS;
            indices[ti] = [
                (last_ring_base + s) as u16,
                (last_ring_base + next_s) as u16,
                top_idx,
            ];
            ti += 1;
        }

        Self {
            positions,
            normals,
            indices,
            vertex_count: vi,
            triangle_count: ti,
        }
    }

    /// Create a MeshRef for use with the platform-agnostic render pipeline.
    pub fn as_mesh_ref(&self) -> MeshRef<'_> {
        MeshRef {
            positions: &self.positions[..self.vertex_count],
            normals: &self.normals[..self.vertex_count],
            indices: &self.indices[..self.triangle_count],
        }
    }
}
