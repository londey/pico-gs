use crate::types::{MeshPatch, VertexData};
use std::collections::BTreeMap;

/// Split a mesh into patches using a greedy sequential algorithm.
///
/// Each patch has at most `max_vertices` vertices and `max_indices` indices.
/// Uses `BTreeMap` for deterministic vertex mapping (reproducible builds).
pub fn split_into_patches(
    vertices: &[VertexData],
    indices: &[u32],
    max_vertices: usize,
    max_indices: usize,
) -> Vec<MeshPatch> {
    let mut patches = Vec::new();
    let mut current_verts: Vec<VertexData> = Vec::new();
    let mut current_indices: Vec<u16> = Vec::new();
    let mut vertex_map: BTreeMap<u32, u16> = BTreeMap::new();
    let mut patch_index: usize = 0;

    for tri in indices.chunks_exact(3) {
        let i0 = tri[0];
        let i1 = tri[1];
        let i2 = tri[2];

        // Count how many new vertices this triangle needs
        let new_verts = [i0, i1, i2]
            .iter()
            .filter(|&&idx| !vertex_map.contains_key(&idx))
            .count();

        let would_have_verts = current_verts.len() + new_verts;
        let would_have_indices = current_indices.len() + 3;

        // If adding this triangle would exceed limits, finalize current patch
        if (would_have_verts > max_vertices || would_have_indices > max_indices)
            && !current_verts.is_empty()
        {
            patches.push(MeshPatch {
                vertices: std::mem::take(&mut current_verts),
                indices: std::mem::take(&mut current_indices),
                patch_index,
            });
            patch_index += 1;
            vertex_map.clear();
        }

        // Add each vertex of the triangle
        for &global_idx in &[i0, i1, i2] {
            let local_idx = *vertex_map.entry(global_idx).or_insert_with(|| {
                let local = current_verts.len() as u16;
                current_verts.push(vertices[global_idx as usize]);
                local
            });
            current_indices.push(local_idx);
        }
    }

    // Finalize the last patch
    if !current_verts.is_empty() {
        patches.push(MeshPatch {
            vertices: current_verts,
            indices: current_indices,
            patch_index,
        });
    }

    patches
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_vertex(x: f32, y: f32, z: f32) -> VertexData {
        VertexData {
            position: [x, y, z],
            uv: [0.0, 0.0],
            normal: [0.0, 1.0, 0.0],
        }
    }

    #[test]
    fn test_single_triangle_single_patch() {
        let verts = vec![
            make_vertex(0.0, 0.0, 0.0),
            make_vertex(1.0, 0.0, 0.0),
            make_vertex(0.0, 1.0, 0.0),
        ];
        let indices = vec![0, 1, 2];

        let patches = split_into_patches(&verts, &indices, 16, 32);
        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0].vertices.len(), 3);
        assert_eq!(patches[0].indices.len(), 3);
        assert_eq!(patches[0].patch_index, 0);
    }

    #[test]
    fn test_split_exceeds_vertex_limit() {
        // Create 6 vertices forming 2 independent triangles
        let verts: Vec<VertexData> = (0..6).map(|i| make_vertex(i as f32, 0.0, 0.0)).collect();
        // Two triangles with no shared vertices
        let indices = vec![0, 1, 2, 3, 4, 5];

        // Limit to 3 vertices per patch -> should force 2 patches
        let patches = split_into_patches(&verts, &indices, 3, 32);
        assert_eq!(patches.len(), 2);
        assert_eq!(patches[0].vertices.len(), 3);
        assert_eq!(patches[1].vertices.len(), 3);
    }

    #[test]
    fn test_split_exceeds_index_limit() {
        // 4 vertices, 2 triangles sharing an edge
        let verts = vec![
            make_vertex(0.0, 0.0, 0.0),
            make_vertex(1.0, 0.0, 0.0),
            make_vertex(0.0, 1.0, 0.0),
            make_vertex(1.0, 1.0, 0.0),
        ];
        let indices = vec![0, 1, 2, 1, 3, 2];

        // Index limit of 3 -> each triangle gets its own patch
        let patches = split_into_patches(&verts, &indices, 16, 3);
        assert_eq!(patches.len(), 2);
    }

    #[test]
    fn test_vertex_sharing_within_patch() {
        // 4 vertices, 2 triangles sharing edge 1-2
        let verts = vec![
            make_vertex(0.0, 0.0, 0.0),
            make_vertex(1.0, 0.0, 0.0),
            make_vertex(0.0, 1.0, 0.0),
            make_vertex(1.0, 1.0, 0.0),
        ];
        let indices = vec![0, 1, 2, 1, 3, 2];

        let patches = split_into_patches(&verts, &indices, 16, 32);
        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0].vertices.len(), 4); // shared vertices not duplicated within patch
        assert_eq!(patches[0].indices.len(), 6);
    }

    #[test]
    fn test_determinism() {
        let verts: Vec<VertexData> = (0..20).map(|i| make_vertex(i as f32, 0.0, 0.0)).collect();
        let indices: Vec<u32> = (0..20).collect();

        let patches1 = split_into_patches(&verts, &indices, 5, 32);
        let patches2 = split_into_patches(&verts, &indices, 5, 32);

        assert_eq!(patches1.len(), patches2.len());
        for (p1, p2) in patches1.iter().zip(patches2.iter()) {
            assert_eq!(p1.vertices.len(), p2.vertices.len());
            assert_eq!(p1.indices, p2.indices);
        }
    }

    #[test]
    fn test_all_indices_valid() {
        let verts: Vec<VertexData> = (0..12).map(|i| make_vertex(i as f32, 0.0, 0.0)).collect();
        let indices: Vec<u32> = (0..12).collect();

        let patches = split_into_patches(&verts, &indices, 5, 32);
        for patch in &patches {
            for &idx in &patch.indices {
                assert!(
                    (idx as usize) < patch.vertices.len(),
                    "Index {} out of bounds (vertex count: {})",
                    idx,
                    patch.vertices.len()
                );
            }
        }
    }
}
