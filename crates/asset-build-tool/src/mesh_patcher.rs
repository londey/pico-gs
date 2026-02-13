use crate::types::{RawMeshPatch, VertexData};
use std::collections::BTreeMap;

/// Split a mesh into raw patches using a greedy sequential algorithm.
///
/// Each patch has at most `max_vertices` vertices and `max_indices` indices.
/// Uses `BTreeMap` for deterministic vertex mapping (reproducible builds).
///
/// Returns `RawMeshPatch` with f32 vertex data; call `compute_mesh_aabb`
/// and `pack_soa_blob` to produce quantized `MeshPatch` blobs.
pub fn split_into_patches(
    vertices: &[VertexData],
    indices: &[u32],
    max_vertices: usize,
    max_indices: usize,
) -> Vec<RawMeshPatch> {
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
            patches.push(RawMeshPatch {
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
        patches.push(RawMeshPatch {
            vertices: current_verts,
            indices: current_indices,
            patch_index,
        });
    }

    patches
}

/// Compute axis-aligned bounding box from a slice of vertices.
///
/// # Arguments
///
/// * `vertices` - Vertex data to compute AABB from.
///
/// # Returns
///
/// Tuple of (min, max) as `([f32; 3], [f32; 3])`.
/// Returns `([0.0; 3], [0.0; 3])` for empty input.
pub fn compute_aabb(vertices: &[VertexData]) -> ([f32; 3], [f32; 3]) {
    if vertices.is_empty() {
        return ([0.0; 3], [0.0; 3]);
    }

    let mut min = vertices[0].position;
    let mut max = vertices[0].position;

    for v in &vertices[1..] {
        for axis in 0..3 {
            if v.position[axis] < min[axis] {
                min[axis] = v.position[axis];
            }
            if v.position[axis] > max[axis] {
                max[axis] = v.position[axis];
            }
        }
    }

    (min, max)
}

/// Compute the mesh-wide AABB across all raw patches.
///
/// # Arguments
///
/// * `patches` - All raw mesh patches to encompass.
///
/// # Returns
///
/// Tuple of (min, max) as `([f32; 3], [f32; 3])`.
/// Returns `([0.0; 3], [0.0; 3])` if there are no patches or no vertices.
pub fn compute_mesh_aabb(patches: &[RawMeshPatch]) -> ([f32; 3], [f32; 3]) {
    let all_vertices: Vec<&VertexData> = patches.iter().flat_map(|p| p.vertices.iter()).collect();
    if all_vertices.is_empty() {
        return ([0.0; 3], [0.0; 3]);
    }

    let mut min = all_vertices[0].position;
    let mut max = all_vertices[0].position;

    for v in &all_vertices[1..] {
        for axis in 0..3 {
            if v.position[axis] < min[axis] {
                min[axis] = v.position[axis];
            }
            if v.position[axis] > max[axis] {
                max[axis] = v.position[axis];
            }
        }
    }

    (min, max)
}

/// Quantize a single f32 position value to u16 using AABB range.
///
/// Maps `[aabb_min, aabb_max]` to `[0, 65535]`.
/// Degenerate axis (min == max) maps to 0.
///
/// # Arguments
///
/// * `pos` - Position value in model space.
/// * `aabb_min` - Minimum of the quantization range.
/// * `aabb_max` - Maximum of the quantization range.
///
/// # Returns
///
/// Quantized u16 value in `[0, 65535]`.
pub fn quantize_position(pos: f32, aabb_min: f32, aabb_max: f32) -> u16 {
    let extent = aabb_max - aabb_min;
    if extent <= 0.0 {
        return 0;
    }
    let t = (pos - aabb_min) / extent;
    (t * 65535.0).round().clamp(0.0, 65535.0) as u16
}

/// Quantize a normal component to i16 1:15 signed fixed-point.
///
/// Maps `[-1.0, +1.0]` to `[-32767, +32767]`.
///
/// # Arguments
///
/// * `normal` - Normal component (expected in `[-1.0, 1.0]`).
///
/// # Returns
///
/// Quantized i16 value.
pub fn quantize_normal(normal: f32) -> i16 {
    (normal * 32767.0).round().clamp(-32768.0, 32767.0) as i16
}

/// Quantize a UV coordinate to i16 1:2:13 signed fixed-point.
///
/// Maps with scale factor 8192 (13 fractional bits).
/// Range: `[-4.0, +3.9998]`.
///
/// # Arguments
///
/// * `uv` - UV coordinate value.
///
/// # Returns
///
/// Quantized i16 value.
pub fn quantize_uv(uv: f32) -> i16 {
    (uv * 8192.0).round().clamp(-32768.0, 32767.0) as i16
}

/// Pack vertex data and indices into a single contiguous SoA blob.
///
/// Layout: `[pos_x[], pos_y[], pos_z[], norm_x[], norm_y[], norm_z[],
///           uv_u[], uv_v[], indices[]]`.
/// All multi-byte values are little-endian.
/// Indices remain u16 (2 bytes each) until strip optimization is implemented.
///
/// # Arguments
///
/// * `vertices` - Per-vertex attribute data (position, normal, UV).
/// * `indices` - Triangle indices (u16, local to this patch).
/// * `aabb_min` - Mesh-wide AABB minimum (quantization coordinate system).
/// * `aabb_max` - Mesh-wide AABB maximum (quantization coordinate system).
///
/// # Returns
///
/// Contiguous byte vector: N×16 + M×2 bytes (u16 indices).
pub fn pack_soa_blob(
    vertices: &[VertexData],
    indices: &[u16],
    aabb_min: [f32; 3],
    aabb_max: [f32; 3],
) -> Vec<u8> {
    let n = vertices.len();
    let m = indices.len();
    let mut blob = Vec::with_capacity(n * 16 + m * 2);

    // Positions: 3 arrays of u16 (SoA: all X, then all Y, then all Z)
    for axis in 0..3 {
        for v in vertices {
            let q = quantize_position(v.position[axis], aabb_min[axis], aabb_max[axis]);
            blob.extend_from_slice(&q.to_le_bytes());
        }
    }

    // Normals: 3 arrays of i16 1:15
    for axis in 0..3 {
        for v in vertices {
            let q = quantize_normal(v.normal[axis]);
            blob.extend_from_slice(&q.to_le_bytes());
        }
    }

    // UVs: 2 arrays of i16 1:2:13
    for v in vertices {
        let q = quantize_uv(v.uv[0]);
        blob.extend_from_slice(&q.to_le_bytes());
    }
    for v in vertices {
        let q = quantize_uv(v.uv[1]);
        blob.extend_from_slice(&q.to_le_bytes());
    }

    // Indices: u16 little-endian (strip optimization not yet implemented)
    for &idx in indices {
        blob.extend_from_slice(&idx.to_le_bytes());
    }

    blob
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

    // --- AABB tests ---

    #[test]
    fn test_aabb_single_vertex() {
        let verts = vec![make_vertex(1.0, 2.0, 3.0)];
        let (min, max) = compute_aabb(&verts);
        assert_eq!(min, [1.0, 2.0, 3.0]);
        assert_eq!(max, [1.0, 2.0, 3.0]);
    }

    #[test]
    fn test_aabb_empty() {
        let (min, max) = compute_aabb(&[]);
        assert_eq!(min, [0.0, 0.0, 0.0]);
        assert_eq!(max, [0.0, 0.0, 0.0]);
    }

    #[test]
    fn test_aabb_cube_vertices() {
        let verts = vec![
            make_vertex(-1.0, -1.0, -1.0),
            make_vertex(1.0, 1.0, 1.0),
            make_vertex(0.5, -0.5, 0.0),
        ];
        let (min, max) = compute_aabb(&verts);
        assert_eq!(min, [-1.0, -1.0, -1.0]);
        assert_eq!(max, [1.0, 1.0, 1.0]);
    }

    #[test]
    fn test_aabb_negative_coordinates() {
        let verts = vec![
            make_vertex(-5.0, -3.0, -10.0),
            make_vertex(-2.0, -1.0, -4.0),
        ];
        let (min, max) = compute_aabb(&verts);
        assert_eq!(min, [-5.0, -3.0, -10.0]);
        assert_eq!(max, [-2.0, -1.0, -4.0]);
    }

    #[test]
    fn test_mesh_aabb_multiple_patches() {
        let verts = vec![
            make_vertex(0.0, 0.0, 0.0),
            make_vertex(1.0, 0.0, 0.0),
            make_vertex(0.0, 1.0, 0.0),
            make_vertex(2.0, 0.0, 0.0),
            make_vertex(0.0, 2.0, 0.0),
            make_vertex(0.0, 0.0, 3.0),
        ];
        let indices = vec![0, 1, 2, 3, 4, 5];
        let patches = split_into_patches(&verts, &indices, 3, 32);
        assert_eq!(patches.len(), 2);

        let (min, max) = compute_mesh_aabb(&patches);
        assert_eq!(min, [0.0, 0.0, 0.0]);
        assert_eq!(max, [2.0, 2.0, 3.0]);
    }

    // --- Position quantization tests ---

    #[test]
    fn test_quantize_position_min() {
        assert_eq!(quantize_position(0.0, 0.0, 10.0), 0);
    }

    #[test]
    fn test_quantize_position_max() {
        assert_eq!(quantize_position(10.0, 0.0, 10.0), 65535);
    }

    #[test]
    fn test_quantize_position_midpoint() {
        assert_eq!(quantize_position(5.0, 0.0, 10.0), 32768);
    }

    #[test]
    fn test_quantize_position_degenerate() {
        // Zero-extent axis: should return 0 without panic
        assert_eq!(quantize_position(5.0, 5.0, 5.0), 0);
    }

    #[test]
    fn test_quantize_position_clamped() {
        // Out-of-range values should be clamped
        assert_eq!(quantize_position(-1.0, 0.0, 10.0), 0);
        assert_eq!(quantize_position(11.0, 0.0, 10.0), 65535);
    }

    // --- Normal quantization tests ---

    #[test]
    fn test_quantize_normal_positive_one() {
        assert_eq!(quantize_normal(1.0), 32767);
    }

    #[test]
    fn test_quantize_normal_negative_one() {
        assert_eq!(quantize_normal(-1.0), -32767);
    }

    #[test]
    fn test_quantize_normal_zero() {
        assert_eq!(quantize_normal(0.0), 0);
    }

    // --- UV quantization tests ---

    #[test]
    fn test_quantize_uv_zero() {
        assert_eq!(quantize_uv(0.0), 0);
    }

    #[test]
    fn test_quantize_uv_one() {
        assert_eq!(quantize_uv(1.0), 8192);
    }

    #[test]
    fn test_quantize_uv_negative_one() {
        assert_eq!(quantize_uv(-1.0), -8192);
    }

    #[test]
    fn test_quantize_uv_clamp() {
        // Beyond the representable range
        assert_eq!(quantize_uv(5.0), 32767);
    }

    // --- SoA blob tests ---

    fn make_full_vertex(
        px: f32,
        py: f32,
        pz: f32,
        nx: f32,
        ny: f32,
        nz: f32,
        u: f32,
        v: f32,
    ) -> VertexData {
        VertexData {
            position: [px, py, pz],
            normal: [nx, ny, nz],
            uv: [u, v],
        }
    }

    #[test]
    fn test_soa_blob_total_size() {
        let vertices = vec![
            make_full_vertex(0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0),
            make_full_vertex(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0),
            make_full_vertex(0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0),
        ];
        let indices: Vec<u16> = vec![0, 1, 2];
        let aabb_min = [0.0, 0.0, 0.0];
        let aabb_max = [1.0, 1.0, 1.0];

        let blob = pack_soa_blob(&vertices, &indices, aabb_min, aabb_max);

        // N=3 vertices, M=3 indices (u16): 3*16 + 3*2 = 54 bytes
        assert_eq!(blob.len(), 3 * 16 + 3 * 2);
    }

    #[test]
    fn test_soa_blob_position_layout() {
        // Single vertex at AABB max corner: should quantize to 65535 on all axes
        let vertices = vec![make_full_vertex(10.0, 20.0, 30.0, 0.0, 0.0, 1.0, 0.5, 0.5)];
        let indices: Vec<u16> = vec![0];
        let aabb_min = [0.0, 0.0, 0.0];
        let aabb_max = [10.0, 20.0, 30.0];

        let blob = pack_soa_blob(&vertices, &indices, aabb_min, aabb_max);

        // pos_x at offset 0: should be 65535
        let pos_x = u16::from_le_bytes([blob[0], blob[1]]);
        assert_eq!(pos_x, 65535);

        // pos_y at offset N*2 = 2: should be 65535
        let pos_y = u16::from_le_bytes([blob[2], blob[3]]);
        assert_eq!(pos_y, 65535);

        // pos_z at offset N*4 = 4: should be 65535
        let pos_z = u16::from_le_bytes([blob[4], blob[5]]);
        assert_eq!(pos_z, 65535);
    }

    #[test]
    fn test_soa_blob_normal_layout() {
        // Vertex with normal (0, 0, 1)
        let vertices = vec![make_full_vertex(0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0)];
        let indices: Vec<u16> = vec![0];
        let aabb_min = [0.0; 3];
        let aabb_max = [1.0; 3];

        let blob = pack_soa_blob(&vertices, &indices, aabb_min, aabb_max);

        let n = 1_usize;
        // norm_x at offset N*6 = 6
        let norm_x = i16::from_le_bytes([blob[n * 6], blob[n * 6 + 1]]);
        assert_eq!(norm_x, 0);

        // norm_y at offset N*8 = 8
        let norm_y = i16::from_le_bytes([blob[n * 8], blob[n * 8 + 1]]);
        assert_eq!(norm_y, 0);

        // norm_z at offset N*10 = 10
        let norm_z = i16::from_le_bytes([blob[n * 10], blob[n * 10 + 1]]);
        assert_eq!(norm_z, 32767);
    }

    #[test]
    fn test_soa_blob_uv_layout() {
        // Vertex with UV (0.5, 0.75)
        let vertices = vec![make_full_vertex(0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.5, 0.75)];
        let indices: Vec<u16> = vec![0];
        let aabb_min = [0.0; 3];
        let aabb_max = [1.0; 3];

        let blob = pack_soa_blob(&vertices, &indices, aabb_min, aabb_max);

        let n = 1_usize;
        // uv_u at offset N*12 = 12
        let uv_u = i16::from_le_bytes([blob[n * 12], blob[n * 12 + 1]]);
        // 0.5 * 8192 = 4096
        assert_eq!(uv_u, 4096);

        // uv_v at offset N*14 = 14
        let uv_v = i16::from_le_bytes([blob[n * 14], blob[n * 14 + 1]]);
        // 0.75 * 8192 = 6144
        assert_eq!(uv_v, 6144);
    }

    #[test]
    fn test_soa_blob_uv_layout_multi_vertex() {
        // 3 vertices with different UVs
        let vertices = vec![
            make_full_vertex(0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0),
            make_full_vertex(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0),
            make_full_vertex(0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0),
        ];
        let indices: Vec<u16> = vec![0, 1, 2];
        let aabb_min = [0.0; 3];
        let aabb_max = [1.0; 3];

        let blob = pack_soa_blob(&vertices, &indices, aabb_min, aabb_max);

        let n = 3_usize;
        // uv_u array starts at offset N*12 = 36
        let uv_u_0 = i16::from_le_bytes([blob[n * 12], blob[n * 12 + 1]]);
        let uv_u_1 = i16::from_le_bytes([blob[n * 12 + 2], blob[n * 12 + 3]]);
        let uv_u_2 = i16::from_le_bytes([blob[n * 12 + 4], blob[n * 12 + 5]]);
        assert_eq!(uv_u_0, 0); // 0.0 * 8192
        assert_eq!(uv_u_1, 8192); // 1.0 * 8192
        assert_eq!(uv_u_2, 0); // 0.0 * 8192

        // uv_v array starts at offset N*14 = 42
        let uv_v_0 = i16::from_le_bytes([blob[n * 14], blob[n * 14 + 1]]);
        let uv_v_1 = i16::from_le_bytes([blob[n * 14 + 2], blob[n * 14 + 3]]);
        let uv_v_2 = i16::from_le_bytes([blob[n * 14 + 4], blob[n * 14 + 5]]);
        assert_eq!(uv_v_0, 0); // 0.0 * 8192
        assert_eq!(uv_v_1, 0); // 0.0 * 8192
        assert_eq!(uv_v_2, 8192); // 1.0 * 8192
    }

    #[test]
    fn test_quantize_uv_edge_range() {
        // Near the edges of the representable range [-4.0, +3.9998]
        // -4.0 * 8192 = -32768
        assert_eq!(quantize_uv(-4.0), -32768);
        // +3.9998 ≈ 32766.3 → 32766 after rounding
        let near_max = quantize_uv(32767.0 / 8192.0);
        assert_eq!(near_max, 32767);
        // Just beyond range: clamped
        assert_eq!(quantize_uv(4.0), 32767);
        assert_eq!(quantize_uv(-4.1), -32768);
    }

    #[test]
    fn test_soa_blob_index_section() {
        let vertices = vec![
            make_full_vertex(0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0),
            make_full_vertex(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0),
        ];
        let indices: Vec<u16> = vec![0, 1, 0];
        let aabb_min = [0.0; 3];
        let aabb_max = [1.0; 3];

        let blob = pack_soa_blob(&vertices, &indices, aabb_min, aabb_max);

        let n = 2_usize;
        // Indices start at offset N*16 = 32
        let idx_start = n * 16;
        let idx0 = u16::from_le_bytes([blob[idx_start], blob[idx_start + 1]]);
        let idx1 = u16::from_le_bytes([blob[idx_start + 2], blob[idx_start + 3]]);
        let idx2 = u16::from_le_bytes([blob[idx_start + 4], blob[idx_start + 5]]);
        assert_eq!(idx0, 0);
        assert_eq!(idx1, 1);
        assert_eq!(idx2, 0);
    }

    // --- Round-trip accuracy tests ---

    #[test]
    fn test_position_round_trip_accuracy() {
        // Quantize then dequantize: error should be < 1 LSB of the range
        let aabb_min = -5.0_f32;
        let aabb_max = 10.0_f32;
        let extent = aabb_max - aabb_min;
        let lsb = extent / 65535.0;

        for &val in &[aabb_min, aabb_max, 0.0, 2.5, -3.7] {
            let q = quantize_position(val, aabb_min, aabb_max);
            let reconstructed = aabb_min + (q as f32 / 65535.0) * extent;
            let error = (val - reconstructed).abs();
            assert!(
                error <= lsb,
                "Position round-trip error {:.6} > LSB {:.6} for input {}",
                error,
                lsb,
                val
            );
        }
    }

    #[test]
    fn test_normal_round_trip_accuracy() {
        // Normal quantization precision: < 1/32768
        let lsb = 1.0 / 32767.0;
        for &val in &[0.0_f32, 1.0, -1.0, 0.5, -0.5, 0.707] {
            let q = quantize_normal(val);
            let reconstructed = q as f32 / 32767.0;
            let error = (val - reconstructed).abs();
            assert!(
                error <= lsb,
                "Normal round-trip error {:.6} > LSB {:.6} for input {}",
                error,
                lsb,
                val
            );
        }
    }

    #[test]
    fn test_uv_round_trip_accuracy() {
        // UV quantization precision: < 1/8192
        let lsb = 1.0 / 8192.0;
        for &val in &[0.0_f32, 1.0, -1.0, 0.5, -0.5, 2.0, -3.5] {
            let q = quantize_uv(val);
            let reconstructed = q as f32 / 8192.0;
            let error = (val - reconstructed).abs();
            assert!(
                error <= lsb,
                "UV round-trip error {:.6} > LSB {:.6} for input {}",
                error,
                lsb,
                val
            );
        }
    }
}
