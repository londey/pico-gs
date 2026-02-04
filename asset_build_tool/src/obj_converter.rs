use crate::error::AssetError;
use crate::identifier::generate_identifier;
use crate::mesh_patcher;
use crate::types::{MeshAsset, VertexData};
use std::path::Path;

/// Load an OBJ file, merge all objects/groups, split into patches, return `MeshAsset`.
pub fn load_and_convert(
    path: &Path,
    patch_size: usize,
    index_limit: usize,
) -> Result<MeshAsset, AssetError> {
    let load_options = tobj::LoadOptions {
        triangulate: true,
        single_index: true,
        ..Default::default()
    };

    let (models, _materials) =
        tobj::load_obj(path, &load_options).map_err(|e| AssetError::ObjParse {
            path: path.to_path_buf(),
            message: e.to_string(),
        })?;

    if models.is_empty() {
        return Err(AssetError::Validation(format!(
            "OBJ file has no geometry: {}",
            path.display()
        )));
    }

    // Warn about multiple objects/groups being merged
    if models.len() > 1 {
        log::warn!(
            "OBJ contains {} objects/groups, all geometry will be merged",
            models.len()
        );
    }

    // Merge all models into unified vertex + index data
    let (vertices, indices, original_vertex_count) = merge_models(&models)?;
    let original_triangle_count = indices.len() / 3;

    if vertices.is_empty() || indices.is_empty() {
        return Err(AssetError::Validation(format!(
            "Mesh has no vertices or faces: {}",
            path.display()
        )));
    }

    // Split into patches
    let patches = mesh_patcher::split_into_patches(&vertices, &indices, patch_size, index_limit);

    let identifier = generate_identifier(path)?;

    Ok(MeshAsset {
        source: path.to_path_buf(),
        patches,
        identifier,
        original_vertex_count,
        original_triangle_count,
    })
}

/// Merge all tobj models into a single unified vertex list and index list.
fn merge_models(models: &[tobj::Model]) -> Result<(Vec<VertexData>, Vec<u32>, usize), AssetError> {
    let mut vertices = Vec::new();
    let mut indices = Vec::new();
    let mut vertex_offset: u32 = 0;

    for model in models {
        let mesh = &model.mesh;

        if mesh.positions.is_empty() {
            continue;
        }

        let vert_count = mesh.positions.len() / 3;
        let has_uvs = !mesh.texcoords.is_empty();
        let has_normals = !mesh.normals.is_empty();

        if !has_uvs {
            log::warn!(
                "Mesh '{}' has no UV coordinates, using default (0.0, 0.0)",
                model.name
            );
        }
        if !has_normals {
            log::warn!(
                "Mesh '{}' has no normals, using default (0.0, 0.0, 0.0)",
                model.name
            );
        }

        for i in 0..vert_count {
            let position = [
                mesh.positions[i * 3],
                mesh.positions[i * 3 + 1],
                mesh.positions[i * 3 + 2],
            ];
            let uv = if has_uvs && i * 2 + 1 < mesh.texcoords.len() {
                [mesh.texcoords[i * 2], mesh.texcoords[i * 2 + 1]]
            } else {
                [0.0, 0.0]
            };
            let normal = if has_normals && i * 3 + 2 < mesh.normals.len() {
                [
                    mesh.normals[i * 3],
                    mesh.normals[i * 3 + 1],
                    mesh.normals[i * 3 + 2],
                ]
            } else {
                [0.0, 0.0, 0.0]
            };

            vertices.push(VertexData {
                position,
                uv,
                normal,
            });
        }

        // Remap indices with offset
        for &idx in &mesh.indices {
            indices.push(idx + vertex_offset);
        }

        vertex_offset += vert_count as u32;
    }

    let original_vertex_count = vertices.len();
    Ok((vertices, indices, original_vertex_count))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_merge_empty_model_name() {
        // Simple validation: merge_models should handle empty input
        let models: Vec<tobj::Model> = Vec::new();
        let result = merge_models(&models);
        assert!(result.is_ok());
        let (verts, indices, _) = result.unwrap();
        assert!(verts.is_empty());
        assert!(indices.is_empty());
    }
}
