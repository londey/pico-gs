use crate::error::AssetError;
#[cfg(test)]
use crate::mesh_patcher;
use crate::types::{GeneratedAsset, MeshAsset, TextureAsset};
use std::fs;
use std::io::Write;
use std::path::Path;

/// Format an f32 as a valid Rust literal (always includes decimal point).
fn f32_literal(v: f32) -> String {
    let s = format!("{}", v);
    if s.contains('.') || s.contains("inf") || s.contains("NaN") {
        s
    } else {
        format!("{}.0", s)
    }
}

/// Write texture output files (.rs wrapper + .bin data) and return generated asset metadata.
pub fn write_texture_output(
    texture: &TextureAsset,
    out_dir: &Path,
) -> Result<Vec<GeneratedAsset>, AssetError> {
    let lower_id = texture.identifier.to_lowercase();
    let rs_filename = format!("{}.rs", lower_id);
    let bin_filename = format!("{}.bin", lower_id);

    let rs_path = out_dir.join(&rs_filename);
    let bin_path = out_dir.join(&bin_filename);

    // Write binary data (raw RGBA8888 pixels)
    fs::write(&bin_path, &texture.data)?;

    // Generate Rust wrapper
    let rust_source = format!(
        r#"// Generated from: {}
// Dimensions: {}×{} RGBA8
// Size: {} bytes ({:.1} KB)
// GPU Requirements: 4K-aligned base address

pub const {id}_WIDTH: u32 = {w};
pub const {id}_HEIGHT: u32 = {h};
pub const {id}_DATA: &[u8] = include_bytes!("{bin}");
"#,
        texture.source.display(),
        texture.width,
        texture.height,
        texture.data.len(),
        texture.data.len() as f64 / 1024.0,
        id = texture.identifier,
        w = texture.width,
        h = texture.height,
        bin = bin_filename,
    );

    fs::write(&rs_path, rust_source)?;

    Ok(vec![GeneratedAsset {
        module_name: lower_id,
        identifier: texture.identifier.clone(),
        rs_path: rs_filename.into(),
        source_path: texture.source.clone(),
    }])
}

/// Write mesh output files (per-patch .rs wrappers + single .bin SoA blob each).
pub fn write_mesh_output(
    mesh: &MeshAsset,
    out_dir: &Path,
) -> Result<Vec<GeneratedAsset>, AssetError> {
    let mut generated = Vec::new();

    for patch in &mesh.patches {
        let base_name = format!(
            "{}_patch{}",
            mesh.identifier.to_lowercase(),
            patch.patch_index
        );
        let rs_filename = format!("{}.rs", base_name);
        let bin_filename = format!("{}.bin", base_name);

        let const_name = format!("{}_PATCH{}", mesh.identifier, patch.patch_index);

        // Write single SoA blob binary
        fs::write(out_dir.join(&bin_filename), &patch.data)?;

        // Generate Rust wrapper per INT-031
        let rust_source = format!(
            "// Generated from: {} (patch {} of {})\n\
             // Vertices: {}, Entries: {}\n\
             // Patch AABB: ({}, {}, {}) to ({}, {}, {})\n\
             // Data size: {} bytes (SoA blob: u16 pos + i16 norm + i16 uv + u16 idx)\n\
             \n\
             pub const {c}_VERTEX_COUNT: usize = {vc};\n\
             pub const {c}_ENTRY_COUNT: usize = {ec};\n\
             pub const {c}_AABB_MIN: [f32; 3] = [{amin_x}, {amin_y}, {amin_z}];\n\
             pub const {c}_AABB_MAX: [f32; 3] = [{amax_x}, {amax_y}, {amax_z}];\n\
             pub const {c}_DATA: &[u8] = include_bytes!(\"{bin}\");\n",
            mesh.source.display(),
            patch.patch_index,
            mesh.patches.len(),
            patch.vertex_count,
            patch.entry_count,
            f32_literal(patch.aabb_min[0]),
            f32_literal(patch.aabb_min[1]),
            f32_literal(patch.aabb_min[2]),
            f32_literal(patch.aabb_max[0]),
            f32_literal(patch.aabb_max[1]),
            f32_literal(patch.aabb_max[2]),
            patch.data.len(),
            c = const_name,
            vc = patch.vertex_count,
            ec = patch.entry_count,
            amin_x = f32_literal(patch.aabb_min[0]),
            amin_y = f32_literal(patch.aabb_min[1]),
            amin_z = f32_literal(patch.aabb_min[2]),
            amax_x = f32_literal(patch.aabb_max[0]),
            amax_y = f32_literal(patch.aabb_max[1]),
            amax_z = f32_literal(patch.aabb_max[2]),
            bin = bin_filename,
        );

        fs::write(out_dir.join(&rs_filename), rust_source)?;

        generated.push(GeneratedAsset {
            module_name: base_name,
            identifier: const_name,
            rs_path: rs_filename.into(),
            source_path: mesh.source.clone(),
        });
    }

    // Generate per-mesh wrapper with mesh-level AABB and MeshPatchDescriptor array
    let mesh_base_name = mesh.identifier.to_lowercase();
    let mesh_rs_filename = format!("{}.rs", mesh_base_name);

    let mut mesh_source = format!(
        "// Generated from: {}\n\
         // Patches: {}\n\
         // Total vertices: {}, Total entries: {}\n\
         \n\
         /// Overall mesh bounding box (model space).\n\
         /// Also serves as quantization AABB for u16 position encoding.\n\
         pub const {id}_AABB_MIN: [f32; 3] = [{min_x}, {min_y}, {min_z}];\n\
         pub const {id}_AABB_MAX: [f32; 3] = [{max_x}, {max_y}, {max_z}];\n\
         pub const {id}_PATCH_COUNT: usize = {pc};\n\
         \n\
         /// Per-patch descriptors.\n\
         pub const {id}_PATCHES: [MeshPatchDescriptor; {pc}] = [\n",
        mesh.source.display(),
        mesh.patches.len(),
        mesh.total_vertices(),
        mesh.total_entries(),
        id = mesh.identifier,
        min_x = f32_literal(mesh.aabb_min[0]),
        min_y = f32_literal(mesh.aabb_min[1]),
        min_z = f32_literal(mesh.aabb_min[2]),
        max_x = f32_literal(mesh.aabb_max[0]),
        max_y = f32_literal(mesh.aabb_max[1]),
        max_z = f32_literal(mesh.aabb_max[2]),
        pc = mesh.patches.len(),
    );

    for patch in &mesh.patches {
        let const_name = format!("{}_PATCH{}", mesh.identifier, patch.patch_index);
        mesh_source.push_str(&format!(
            "    MeshPatchDescriptor {{\n\
             \x20       data: {c}_DATA,\n\
             \x20       aabb_min: [{amin_x}, {amin_y}, {amin_z}],\n\
             \x20       aabb_max: [{amax_x}, {amax_y}, {amax_z}],\n\
             \x20       vertex_count: {vc},\n\
             \x20       entry_count: {ec},\n\
             \x20   }},\n",
            c = const_name,
            amin_x = f32_literal(patch.aabb_min[0]),
            amin_y = f32_literal(patch.aabb_min[1]),
            amin_z = f32_literal(patch.aabb_min[2]),
            amax_x = f32_literal(patch.aabb_max[0]),
            amax_y = f32_literal(patch.aabb_max[1]),
            amax_z = f32_literal(patch.aabb_max[2]),
            vc = patch.vertex_count,
            ec = patch.entry_count,
        ));
    }

    mesh_source.push_str("];\n");

    fs::write(out_dir.join(&mesh_rs_filename), mesh_source)?;

    generated.push(GeneratedAsset {
        module_name: mesh_base_name,
        identifier: mesh.identifier.clone(),
        rs_path: mesh_rs_filename.into(),
        source_path: mesh.source.clone(),
    });

    Ok(generated)
}

/// Write the master `mod.rs` that includes all generated asset files.
pub fn write_mod_rs(generated: &[GeneratedAsset], out_dir: &Path) -> Result<(), AssetError> {
    let mod_path = out_dir.join("mod.rs");
    let mut file = fs::File::create(&mod_path)?;

    writeln!(file, "// Auto-generated by asset_build_tool - do not edit")?;
    writeln!(file)?;

    // Emit MeshPatchDescriptor struct if there are any mesh assets
    let has_meshes = generated.iter().any(|g| g.identifier.contains("PATCH"));
    if has_meshes {
        writeln!(file, "#[derive(Copy, Clone)]")?;
        writeln!(file, "pub struct MeshPatchDescriptor {{")?;
        writeln!(file, "    pub data: &'static [u8],")?;
        writeln!(file, "    pub aabb_min: [f32; 3],")?;
        writeln!(file, "    pub aabb_max: [f32; 3],")?;
        writeln!(file, "    pub vertex_count: usize,")?;
        writeln!(file, "    pub entry_count: usize,")?;
        writeln!(file, "}}")?;
        writeln!(file)?;
    }

    // Sort for deterministic output
    let mut rs_files: Vec<&str> = generated
        .iter()
        .map(|g| g.rs_path.to_str().unwrap_or(""))
        .collect();
    rs_files.sort();

    for rs_file in rs_files {
        if !rs_file.is_empty() {
            writeln!(file, "include!(\"{}\");", rs_file)?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{MeshPatch, VertexData};
    use std::path::PathBuf;

    /// Build a test MeshAsset from raw vertex/index data (mirrors obj_converter pipeline).
    fn make_test_mesh(
        verts: &[VertexData],
        indices: &[u16],
        aabb_min: [f32; 3],
        aabb_max: [f32; 3],
    ) -> MeshAsset {
        let data = mesh_patcher::pack_soa_blob(verts, indices, aabb_min, aabb_max);
        let (patch_min, patch_max) = mesh_patcher::compute_aabb(verts);
        MeshAsset {
            source: PathBuf::from("meshes/cube.obj"),
            patches: vec![MeshPatch {
                data,
                aabb_min: patch_min,
                aabb_max: patch_max,
                vertex_count: verts.len(),
                entry_count: indices.len(),
                patch_index: 0,
            }],
            identifier: "MESHES_CUBE".to_string(),
            original_vertex_count: verts.len(),
            original_triangle_count: indices.len() / 3,
            aabb_min,
            aabb_max,
        }
    }

    #[test]
    fn test_write_texture_output() {
        let dir = tempfile::tempdir().unwrap();
        let texture = TextureAsset {
            source: PathBuf::from("textures/test.png"),
            width: 8,
            height: 8,
            data: vec![0u8; 8 * 8 * 4],
            identifier: "TEXTURES_TEST".to_string(),
        };

        let result = write_texture_output(&texture, dir.path());
        assert!(result.is_ok());
        let generated = result.unwrap();
        assert_eq!(generated.len(), 1);
        assert_eq!(generated[0].identifier, "TEXTURES_TEST");

        // Check files exist
        assert!(dir.path().join("textures_test.rs").exists());
        assert!(dir.path().join("textures_test.bin").exists());

        // Check bin file size
        let bin_data = fs::read(dir.path().join("textures_test.bin")).unwrap();
        assert_eq!(bin_data.len(), 8 * 8 * 4);

        // Check rs file contains expected constants
        let rs_content = fs::read_to_string(dir.path().join("textures_test.rs")).unwrap();
        assert!(rs_content.contains("TEXTURES_TEST_WIDTH"));
        assert!(rs_content.contains("TEXTURES_TEST_HEIGHT"));
        assert!(rs_content.contains("TEXTURES_TEST_DATA"));
        assert!(rs_content.contains("include_bytes!"));
    }

    #[test]
    fn test_write_mesh_output() {
        let dir = tempfile::tempdir().unwrap();
        let verts = [
            VertexData {
                position: [0.0, 0.0, 0.0],
                uv: [0.0, 0.0],
                normal: [0.0, 1.0, 0.0],
            },
            VertexData {
                position: [1.0, 0.0, 0.0],
                uv: [1.0, 0.0],
                normal: [0.0, 1.0, 0.0],
            },
            VertexData {
                position: [0.0, 1.0, 0.0],
                uv: [0.0, 1.0],
                normal: [0.0, 1.0, 0.0],
            },
        ];
        let indices = [0u16, 1, 2];
        let aabb_min = [0.0, 0.0, 0.0];
        let aabb_max = [1.0, 1.0, 1.0];
        let mesh = make_test_mesh(&verts, &indices, aabb_min, aabb_max);

        let result = write_mesh_output(&mesh, dir.path());
        assert!(result.is_ok());
        let generated = result.unwrap();
        // 1 per-patch + 1 per-mesh wrapper = 2 generated assets
        assert_eq!(generated.len(), 2);

        // Check per-patch files exist
        assert!(dir.path().join("meshes_cube_patch0.rs").exists());
        assert!(dir.path().join("meshes_cube_patch0.bin").exists());

        // Check blob size: N=3 vertices * 16 + M=3 indices * 2 = 54 bytes
        let bin_data = fs::read(dir.path().join("meshes_cube_patch0.bin")).unwrap();
        assert_eq!(bin_data.len(), 3 * 16 + 3 * 2);

        // Check per-patch rs file contains expected constants
        let rs_content = fs::read_to_string(dir.path().join("meshes_cube_patch0.rs")).unwrap();
        assert!(rs_content.contains("MESHES_CUBE_PATCH0_VERTEX_COUNT"));
        assert!(rs_content.contains("MESHES_CUBE_PATCH0_ENTRY_COUNT"));
        assert!(rs_content.contains("MESHES_CUBE_PATCH0_AABB_MIN"));
        assert!(rs_content.contains("MESHES_CUBE_PATCH0_AABB_MAX"));
        assert!(rs_content.contains("MESHES_CUBE_PATCH0_DATA"));
        assert!(rs_content.contains("include_bytes!"));

        // Check per-mesh wrapper exists with mesh-level AABB and descriptor array
        assert!(dir.path().join("meshes_cube.rs").exists());
        let mesh_rs = fs::read_to_string(dir.path().join("meshes_cube.rs")).unwrap();
        assert!(mesh_rs.contains("MESHES_CUBE_AABB_MIN"));
        assert!(mesh_rs.contains("MESHES_CUBE_AABB_MAX"));
        assert!(mesh_rs.contains("MESHES_CUBE_PATCH_COUNT"));
        assert!(mesh_rs.contains("MESHES_CUBE_PATCHES"));
        assert!(mesh_rs.contains("MeshPatchDescriptor"));
    }

    #[test]
    fn test_write_mod_rs() {
        let dir = tempfile::tempdir().unwrap();
        let generated = vec![
            GeneratedAsset {
                module_name: "textures_player".to_string(),
                identifier: "TEXTURES_PLAYER".to_string(),
                rs_path: "textures_player.rs".into(),
                source_path: PathBuf::from("textures/player.png"),
            },
            GeneratedAsset {
                module_name: "meshes_cube_patch0".to_string(),
                identifier: "MESHES_CUBE_PATCH0".to_string(),
                rs_path: "meshes_cube_patch0.rs".into(),
                source_path: PathBuf::from("meshes/cube.obj"),
            },
        ];

        let result = write_mod_rs(&generated, dir.path());
        assert!(result.is_ok());

        let content = fs::read_to_string(dir.path().join("mod.rs")).unwrap();
        assert!(content.contains("Auto-generated"));
        assert!(content.contains(r#"include!("meshes_cube_patch0.rs")"#));
        assert!(content.contains(r#"include!("textures_player.rs")"#));
    }

    #[test]
    fn test_write_mod_rs_empty() {
        let dir = tempfile::tempdir().unwrap();
        let result = write_mod_rs(&[], dir.path());
        assert!(result.is_ok());

        let content = fs::read_to_string(dir.path().join("mod.rs")).unwrap();
        assert!(content.contains("Auto-generated"));
        assert!(!content.contains("include!"));
    }
}
