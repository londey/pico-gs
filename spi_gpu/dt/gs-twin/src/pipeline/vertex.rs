//! Vertex stage: model-view-projection transform.
//!
//! Transforms object-space vertices through the MVP matrix to produce
//! clip-space coordinates. All arithmetic is Q16.16 fixed-point,
//! matching the RTL's MULT18X18D-based multiply-accumulate chain.
//!
//! # RTL Implementation Notes
//! The RTL vertex pipeline reads 3 × Q16.16 position components from
//! the vertex SRAM, appends w=1.0 (0x0001_0000), and multiplies by
//! the 4×4 MVP matrix stored in the register bank. The MAC chain
//! computes 4 dot products sequentially (one per output component),
//! each requiring 4 multiply-accumulate cycles.

use crate::cmd::Vertex;
use crate::math::{Coord, Mat4, Vec4};
use crate::pipeline::ClipVertex;

/// Transform a vertex from object space to clip space.
///
/// This is a pure function implementing what the RTL's vertex pipeline
/// computes in hardware: `clip_pos = MVP × [position, 1]`.
///
/// # Numeric Behavior
/// - Input position: Q16.16 per component (from vertex SRAM)
/// - W component: exactly 1.0 (0x0001_0000 in Q16.16)
/// - Matrix elements: Q16.16 (from register bank)
/// - Each multiply: Q16.16 × Q16.16 → Q16.16 (truncated from 36-bit product)
/// - Accumulation: Q16.16 wrapping add (4 terms per output component)
/// - Output: Q16.16 per component (clip space)
pub fn transform(vertex: &Vertex, mvp: &Mat4) -> ClipVertex {
    let pos = Vec4 {
        x: vertex.position.x,
        y: vertex.position.y,
        z: vertex.position.z,
        w: Coord::ONE,
    };

    let clip_pos = mvp.transform(pos);

    ClipVertex {
        clip_pos,
        uv: vertex.uv,
        color: vertex.color,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::math::{Coord, Rgb565, TexVec2, Vec3};

    #[test]
    fn identity_transform_preserves_position() {
        let v = Vertex {
            position: Vec3::from_f32(1.0, 2.0, 3.0),
            uv: TexVec2::default(),
            color: Rgb565(0),
        };
        let result = transform(&v, &Mat4::identity());
        assert_eq!(result.clip_pos.x, Coord::from_num(1.0));
        assert_eq!(result.clip_pos.y, Coord::from_num(2.0));
        assert_eq!(result.clip_pos.z, Coord::from_num(3.0));
        assert_eq!(result.clip_pos.w, Coord::ONE);
    }

    #[test]
    fn translation_matrix_offsets_position() {
        // Translation by (10, 20, 30)
        let mat = Mat4::from_f32([
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [10.0, 20.0, 30.0, 1.0],
        ]);
        let v = Vertex {
            position: Vec3::from_f32(1.0, 2.0, 3.0),
            uv: TexVec2::default(),
            color: Rgb565(0),
        };
        let result = transform(&v, &mat);
        assert_eq!(result.clip_pos.x, Coord::from_num(11.0));
        assert_eq!(result.clip_pos.y, Coord::from_num(22.0));
        assert_eq!(result.clip_pos.z, Coord::from_num(33.0));
        assert_eq!(result.clip_pos.w, Coord::ONE);
    }
}
