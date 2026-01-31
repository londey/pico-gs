# Tasks: Asset Data Preparation Tool

**Input**: Design documents from `/workspaces/pico-gs/specs/003-asset-data-prep/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Project Initialization)

**Purpose**: Create project structure and configure dependencies

- [ ] T001 Create tools/asset-prep/ directory structure with Cargo.toml
- [ ] T002 Create tools/asset-prep/src/ directory for source files
- [ ] T003 Create tools/asset-prep/tests/ directory with integration/ and fixtures/ subdirectories
- [ ] T004 [P] Add image = "0.25" dependency to tools/asset-prep/Cargo.toml
- [ ] T005 [P] Add tobj = "4.0" dependency to tools/asset-prep/Cargo.toml
- [ ] T006 [P] Add clap = { version = "4.5", features = ["derive"] } dependency to tools/asset-prep/Cargo.toml
- [ ] T007 Create tools/asset-prep/src/main.rs with basic CLI skeleton
- [ ] T008 Create tools/asset-prep/src/lib.rs with module declarations

**Checkpoint**: Project structure ready, dependencies configured, builds successfully with `cargo build`

---

## Phase 2: Foundational (Shared Types & Utilities)

**Purpose**: Core infrastructure that ALL user stories depend on - MUST be complete before ANY user story implementation

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [ ] T009 [P] Create TextureAsset struct in tools/asset-prep/src/types.rs
- [ ] T010 [P] Create VertexData struct in tools/asset-prep/src/types.rs
- [ ] T011 [P] Create MeshPatch struct in tools/asset-prep/src/types.rs
- [ ] T012 [P] Create MeshAsset struct in tools/asset-prep/src/types.rs
- [ ] T013 [P] Create OutputFile and BinaryFile structs in tools/asset-prep/src/types.rs
- [ ] T014 Create identifier generation function in tools/asset-prep/src/identifier.rs (sanitize filename to Rust identifier)
- [ ] T015 Add identifier conflict detection in tools/asset-prep/src/identifier.rs
- [ ] T016 Add parent directory extraction for identifiers in tools/asset-prep/src/identifier.rs
- [ ] T017 [P] Create CLI Args struct with clap derive in tools/asset-prep/src/main.rs
- [ ] T018 [P] Create texture subcommand definition in tools/asset-prep/src/main.rs
- [ ] T019 [P] Create mesh subcommand definition in tools/asset-prep/src/main.rs
- [ ] T020 [P] Create batch subcommand definition in tools/asset-prep/src/main.rs
- [ ] T021 Add global --quiet flag handling in tools/asset-prep/src/main.rs
- [ ] T022 Create error types and Result aliases in tools/asset-prep/src/lib.rs
- [ ] T023 Add progress reporting utility in tools/asset-prep/src/lib.rs (respects --quiet flag)

**Checkpoint**: Foundation ready - all user stories can now proceed (sequentially or in parallel)

---

## Phase 3: User Story 1 - PNG to RGBA8888 Texture Conversion (Priority: P1) 🎯 MVP

**Goal**: Convert PNG images to RGBA8888 format with validation of power-of-two dimensions (8×8 to 1024×1024)

**Independent Test**: Convert a 256×256 PNG and verify RGBA8888 output with correct dimensions and pixel data

**Why this is MVP**: Core functionality for all textured rendering, can be tested independently without mesh data or firmware integration

### Implementation for User Story 1

- [ ] T024 [US1] Create tools/asset-prep/src/png_converter.rs module
- [ ] T025 [US1] Implement is_power_of_two(n: u32) helper in tools/asset-prep/src/png_converter.rs
- [ ] T026 [US1] Implement validate_texture_dimensions(width: u32, height: u32) in tools/asset-prep/src/png_converter.rs
- [ ] T027 [US1] Implement load_and_validate_png(path: &Path) in tools/asset-prep/src/png_converter.rs (uses image::open)
- [ ] T028 [US1] Implement convert_to_rgba8(img: DynamicImage) in tools/asset-prep/src/png_converter.rs
- [ ] T029 [US1] Add error handling for non-power-of-two dimensions with actionable hints in tools/asset-prep/src/png_converter.rs
- [ ] T030 [US1] Add error handling for out-of-range dimensions (< 8×8 or > 1024×1024) in tools/asset-prep/src/png_converter.rs
- [ ] T031 [US1] Implement convert_texture(input: PathBuf, quiet: bool) -> Result&lt;TextureAsset&gt; in tools/asset-prep/src/png_converter.rs
- [ ] T032 [US1] Wire texture subcommand to png_converter::convert_texture in tools/asset-prep/src/main.rs
- [ ] T033 [US1] Add progress output for texture conversion in tools/asset-prep/src/png_converter.rs (dimensions, size, identifier)

**Checkpoint**: At this point, User Story 1 (PNG texture conversion) should be fully functional and testable independently

---

## Phase 4: User Story 2 - OBJ to Mesh Patches Conversion (Priority: P2)

**Goal**: Convert OBJ mesh files to patch format with vertex data (positions, UVs, normals) and triangle indices, automatically splitting large meshes

**Independent Test**: Convert cube.obj and verify vertex positions, UVs, normals, indices are correctly extracted and split into patches

**Why P2**: Essential for 3D rendering, depends on working asset pipeline but can be tested independently from texture conversion

### Implementation for User Story 2

- [ ] T034 [P] [US2] Create tools/asset-prep/src/obj_converter.rs module
- [ ] T035 [P] [US2] Create tools/asset-prep/src/mesh_patcher.rs module
- [ ] T036 [US2] Implement load_obj_mesh(path: &Path) in tools/asset-prep/src/obj_converter.rs (uses tobj::load_obj with triangulate: true)
- [ ] T037 [US2] Implement handle_missing_attributes(mesh: &tobj::Mesh) in tools/asset-prep/src/obj_converter.rs (default UVs and normals)
- [ ] T038 [US2] Implement validate_mesh_data(positions: &[f32], indices: &[u32]) in tools/asset-prep/src/obj_converter.rs
- [ ] T039 [US2] Add warning output for missing UVs in tools/asset-prep/src/obj_converter.rs
- [ ] T040 [US2] Add warning output for missing normals in tools/asset-prep/src/obj_converter.rs
- [ ] T041 [US2] Define MAX_VERTICES_PER_PATCH and MAX_INDICES_PER_PATCH constants in tools/asset-prep/src/mesh_patcher.rs (default 16 and 32)
- [ ] T042 [US2] Implement greedy sequential split algorithm in tools/asset-prep/src/mesh_patcher.rs (split_into_patches function)
- [ ] T043 [US2] Add vertex_map for global-to-local index mapping in tools/asset-prep/src/mesh_patcher.rs
- [ ] T044 [US2] Implement patch boundary detection (vertex/index limit exceeded) in tools/asset-prep/src/mesh_patcher.rs
- [ ] T045 [US2] Implement vertex duplication across patch boundaries in tools/asset-prep/src/mesh_patcher.rs
- [ ] T046 [US2] Implement convert_mesh(input: PathBuf, patch_size: usize, index_limit: usize, quiet: bool) -> Result&lt;MeshAsset&gt; in tools/asset-prep/src/obj_converter.rs
- [ ] T047 [US2] Wire mesh subcommand to obj_converter::convert_mesh in tools/asset-prep/src/main.rs
- [ ] T048 [US2] Add progress output for mesh conversion in tools/asset-prep/src/obj_converter.rs (original counts, patch count, identifier)
- [ ] T049 [US2] Add patch count reporting (always, regardless of splitting) in tools/asset-prep/src/obj_converter.rs

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently

---

## Phase 5: User Story 3 - Firmware-Compatible Output Generation (Priority: P3)

**Goal**: Generate Rust const arrays with include_bytes!() macros and binary data files for direct firmware inclusion

**Independent Test**: Include generated Rust files in firmware build and verify compilation succeeds with correct data structures

**Why P3**: Integration feature that completes the pipeline from source files to compiled firmware, depends on US1 and US2

### Implementation for User Story 3

- [ ] T050 [US3] Create tools/asset-prep/src/output_gen.rs module
- [ ] T051 [US3] Implement generate_texture_output(asset: &TextureAsset, output_dir: &Path) -> Result&lt;OutputFile&gt; in tools/asset-prep/src/output_gen.rs
- [ ] T052 [US3] Generate Rust source template for textures with WIDTH, HEIGHT, DATA constants in tools/asset-prep/src/output_gen.rs
- [ ] T053 [US3] Add metadata comments to texture Rust output (source path, dimensions, size, 4K alignment requirement) in tools/asset-prep/src/output_gen.rs
- [ ] T054 [US3] Add usage example comments to texture Rust output in tools/asset-prep/src/output_gen.rs
- [ ] T055 [US3] Generate binary file for texture pixel data (RGBA8888, row-major) in tools/asset-prep/src/output_gen.rs
- [ ] T056 [US3] Implement generate_mesh_patch_output(asset: &MeshAsset, patch: &MeshPatch, output_dir: &Path) -> Result&lt;OutputFile&gt; in tools/asset-prep/src/output_gen.rs
- [ ] T057 [US3] Generate Rust source template for mesh patches with VERTEX_COUNT, INDEX_COUNT, and include_bytes!() for 4 arrays in tools/asset-prep/src/output_gen.rs
- [ ] T058 [US3] Add metadata comments to mesh Rust output (source path, patch index, vertex/index counts, triangle count) in tools/asset-prep/src/output_gen.rs
- [ ] T059 [US3] Add usage example comments with bytemuck::cast_slice to mesh Rust output in tools/asset-prep/src/output_gen.rs
- [ ] T060 [US3] Generate 4 binary files per mesh patch (positions, UVs, normals, indices) in tools/asset-prep/src/output_gen.rs
- [ ] T061 [US3] Implement little-endian encoding for f32 values (positions, UVs, normals) in tools/asset-prep/src/output_gen.rs
- [ ] T062 [US3] Implement little-endian encoding for u16 indices in tools/asset-prep/src/output_gen.rs
- [ ] T063 [US3] Implement write_output_files(output: &OutputFile, output_dir: &Path) in tools/asset-prep/src/output_gen.rs
- [ ] T064 [US3] Wire texture output generation to texture subcommand in tools/asset-prep/src/main.rs
- [ ] T065 [US3] Wire mesh output generation to mesh subcommand in tools/asset-prep/src/main.rs
- [ ] T066 [US3] Add file naming convention (identifier_lowercase.rs and .bin) in tools/asset-prep/src/output_gen.rs
- [ ] T067 [US3] Add patch naming convention (identifier_lowercase_patchN.rs and _pos/_uv/_norm/_idx.bin) in tools/asset-prep/src/output_gen.rs

**Checkpoint**: All user stories should now be independently functional - generated files compile in firmware

---

## Phase 6: Batch Processing & Integration (Builds on US1, US2, US3)

**Purpose**: Batch mode that processes entire directories, combining all three user stories

- [ ] T068 Implement directory scanning for .png and .obj files in tools/asset-prep/src/main.rs
- [ ] T069 Add recursive file discovery in tools/asset-prep/src/main.rs
- [ ] T070 Skip hidden files (starting with '.') in tools/asset-prep/src/main.rs
- [ ] T071 Implement batch texture processing loop in tools/asset-prep/src/main.rs
- [ ] T072 Implement batch mesh processing loop in tools/asset-prep/src/main.rs
- [ ] T073 Add batch progress output (scanning, counts, per-file progress) in tools/asset-prep/src/main.rs
- [ ] T074 Add batch summary output (total textures/meshes converted, total patches) in tools/asset-prep/src/main.rs
- [ ] T075 Wire batch subcommand to batch processing logic in tools/asset-prep/src/main.rs
- [ ] T076 Add identifier conflict detection across batch in tools/asset-prep/src/main.rs

**Checkpoint**: Batch mode works, processes entire asset directories with progress reporting

---

## Phase 7: Error Handling & Edge Cases

**Purpose**: Robust error handling with actionable error messages

- [ ] T077 [P] Add file not found error handling with path hints in tools/asset-prep/src/lib.rs
- [ ] T078 [P] Add corrupted PNG error handling in tools/asset-prep/src/png_converter.rs
- [ ] T079 [P] Add corrupted OBJ error handling in tools/asset-prep/src/obj_converter.rs
- [ ] T080 [P] Add grayscale PNG handling (convert to RGBA8) in tools/asset-prep/src/png_converter.rs
- [ ] T081 [P] Add indexed color PNG handling (apply palette) in tools/asset-prep/src/png_converter.rs
- [ ] T082 [P] Add quad face triangulation handling in tools/asset-prep/src/obj_converter.rs (tobj handles this)
- [ ] T083 [P] Add polygon face triangulation handling (fan triangulation) in tools/asset-prep/src/obj_converter.rs
- [ ] T084 Add IO error handling with permission hints in tools/asset-prep/src/output_gen.rs
- [ ] T085 Add empty mesh validation (no vertices/faces) in tools/asset-prep/src/obj_converter.rs
- [ ] T086 Add proper exit codes (0=success, 2=not found, 3=invalid format, 4=validation, 5=IO, 6=conflict) in tools/asset-prep/src/main.rs

**Checkpoint**: All edge cases handled with clear error messages and actionable hints

---

## Phase 8: Polish & Documentation

**Purpose**: Final improvements for usability and maintainability

- [ ] T087 Add help text examples to CLI subcommands in tools/asset-prep/src/main.rs
- [ ] T088 Add version info from Cargo.toml in tools/asset-prep/src/main.rs
- [ ] T089 Create tools/asset-prep/README.md with installation and basic usage
- [ ] T090 Add fixture files to tools/asset-prep/tests/fixtures/ (test-texture.png, test-cube.obj, test-teapot.obj)
- [ ] T091 Validate quickstart.md examples work end-to-end
- [ ] T092 Add sample integration with build.rs in quickstart.md
- [ ] T093 Create example firmware assets module in quickstart.md
- [ ] T094 Test quiet mode suppresses output correctly
- [ ] T095 Verify all error messages include actionable hints

**Checkpoint**: Tool is polished, documented, and ready for release

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational completion
- **User Story 2 (Phase 4)**: Depends on Foundational completion (can run in parallel with US1)
- **User Story 3 (Phase 5)**: Depends on US1 and US2 completion (needs both texture and mesh output types)
- **Batch Processing (Phase 6)**: Depends on US1, US2, US3 completion
- **Error Handling (Phase 7)**: Can run in parallel with user stories (different concerns)
- **Polish (Phase 8)**: Depends on all previous phases

### User Story Dependencies

- **User Story 1 (P1)**: MVP - Can start after Foundational (Phase 2)
- **User Story 2 (P2)**: Can start after Foundational (Phase 2) - Parallel with US1
- **User Story 3 (P3)**: Requires US1 and US2 to define output types

### Within Each User Story

**US1 (Texture Conversion)**:
- T024 (create module) → T025-T030 (validation/conversion logic in parallel) → T031 (integrate) → T032-T033 (wire to CLI)

**US2 (Mesh Conversion)**:
- T034-T035 (create modules in parallel) → T036-T040 (OBJ loading in parallel) → T041-T045 (patching logic) → T046 (integrate) → T047-T049 (wire to CLI)

**US3 (Output Generation)**:
- T050 (create module) → T051-T055 (texture output in parallel with T056-T062 mesh output) → T063 (write files) → T064-T067 (integrate)

### Parallel Opportunities

**Phase 1 (Setup)**: T004, T005, T006 (add dependencies in parallel)

**Phase 2 (Foundational)**:
- T009-T013 (create all type structs in parallel)
- T017-T020 (create all CLI subcommands in parallel)

**Phase 3 (US1)**: T025, T026, T027, T028 (validation and conversion helpers in parallel)

**Phase 4 (US2)**:
- T034, T035 (create modules in parallel)
- T036, T037, T038, T039, T040 (OBJ loading and validation in parallel)

**Phase 5 (US3)**:
- T051-T055 (texture output) can run in parallel with T056-T062 (mesh output)

**Phase 7 (Error Handling)**: T077-T083 (most error handling tasks are independent)

**Cross-Story Parallelism**: Once Phase 2 completes, US1 (Phase 3) and US2 (Phase 4) can be worked on simultaneously by different developers

---

## Parallel Example: User Story 1

```bash
# After Foundational phase is complete, launch US1 validation helpers in parallel:
Task T025: "Implement is_power_of_two(n: u32) helper in tools/asset-prep/src/png_converter.rs"
Task T026: "Implement validate_texture_dimensions(width: u32, height: u32) in tools/asset-prep/src/png_converter.rs"
Task T027: "Implement load_and_validate_png(path: &Path) in tools/asset-prep/src/png_converter.rs"
Task T028: "Implement convert_to_rgba8(img: DynamicImage) in tools/asset-prep/src/png_converter.rs"

# Then integrate sequentially:
Task T031: "Implement convert_texture(...) in tools/asset-prep/src/png_converter.rs"
Task T032: "Wire texture subcommand to png_converter::convert_texture in tools/asset-prep/src/main.rs"
```

---

## Parallel Example: User Story 3

```bash
# After US1 and US2 complete, launch texture and mesh output generation in parallel:
Task T051-T055: "Generate texture output (Rust + binary) in tools/asset-prep/src/output_gen.rs"
Task T056-T062: "Generate mesh output (Rust + 4 binaries) in tools/asset-prep/src/output_gen.rs"

# Then integrate sequentially:
Task T063: "Implement write_output_files(...) in tools/asset-prep/src/output_gen.rs"
Task T064-T067: "Wire output generation to subcommands in tools/asset-prep/src/main.rs"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup → Project builds
2. Complete Phase 2: Foundational → Types and CLI structure ready
3. Complete Phase 3: User Story 1 → PNG texture conversion works
4. **STOP and VALIDATE**: Convert a 256×256 PNG, verify RGBA8888 output
5. Result: Working texture converter (MVP deliverable!)

### Incremental Delivery (Recommended)

1. **Setup + Foundational** → Foundation ready
2. **Add US1 (P1)** → Test independently → PNG converter works! 🎯
3. **Add US2 (P2)** → Test independently → Mesh converter works!
4. **Add US3 (P3)** → Test independently → Firmware integration works!
5. **Add Batch (Phase 6)** → Full workflow complete
6. Each phase adds value without breaking previous work

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together (T001-T023)
2. Once Foundational is done (after T023):
   - **Developer A**: User Story 1 (T024-T033) - PNG conversion
   - **Developer B**: User Story 2 (T034-T049) - OBJ conversion
   - **Developer C**: Error Handling (T077-T086) - Can start early
3. After US1 and US2 complete:
   - **Developer A + B**: User Story 3 together (T050-T067) - Output generation
4. After US3 complete:
   - **Any developer**: Batch mode (T068-T076)
5. **Everyone**: Polish & Documentation (T087-T095)

---

## Task Count Summary

- **Phase 1 (Setup)**: 8 tasks
- **Phase 2 (Foundational)**: 15 tasks (CRITICAL - blocks all stories)
- **Phase 3 (US1 - Texture)**: 10 tasks (MVP)
- **Phase 4 (US2 - Mesh)**: 16 tasks
- **Phase 5 (US3 - Output)**: 18 tasks
- **Phase 6 (Batch)**: 9 tasks
- **Phase 7 (Error Handling)**: 10 tasks
- **Phase 8 (Polish)**: 9 tasks
- **Total**: 95 tasks

### Priority Breakdown

- **P1 (MVP - US1)**: 33 tasks (Setup + Foundational + US1)
- **P2 (US2)**: +16 tasks = 49 total
- **P3 (US3)**: +18 tasks = 67 total
- **Full Feature**: 95 tasks (includes batch, error handling, polish)

---

## Notes

- **[P] tasks**: Different files, no dependencies - can run in parallel
- **[Story] label**: Maps task to specific user story for traceability
- **MVP path**: T001-T033 delivers working PNG texture converter
- **Each user story**: Independently completable and testable
- **Commit strategy**: Commit after each task or logical group
- **Checkpoints**: Stop at any checkpoint to validate independently
- **No tests included**: Spec did not explicitly request TDD, focus on implementation
- **File paths**: All paths are absolute from repository root (`/workspaces/pico-gs/`)
- **Dependencies**: Research.md decisions (image, tobj, clap) already resolved
- **Binary format**: Little-endian throughout (matches RP2350 native byte order)
