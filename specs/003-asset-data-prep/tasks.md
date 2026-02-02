# Tasks: Asset Data Preparation Tool

**Input**: Design documents from `/specs/003-asset-data-prep/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Per Article V (Test-First Development), all modules require test coverage.

**Architecture**: Library-first design. The `asset_build_tool` crate exposes a public API consumed by `host_app/build.rs`. An optional CLI binary wraps the library for debugging. Source assets live in `host_app/assets/`, generated output goes to Cargo's `OUT_DIR`.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Library crate**: `asset_build_tool/` at repository root
- **Source assets**: `host_app/assets/` (textures/*.png, meshes/*.obj)
- **Generated output**: `$OUT_DIR/assets/` (ephemeral, not committed)
- **Build integration**: `host_app/build.rs` and `host_app/Cargo.toml`

---

## Phase 1: Setup (Project Infrastructure)

**Purpose**: Project initialization, build integration scaffolding, and test fixtures

- [ ] T001 Create asset_build_tool directory and Cargo.toml manifest
- [ ] T002 Add asset_build_tool to workspace members in root Cargo.toml
- [ ] T003 [P] Create src/lib.rs with crate-level lints per Article X (deny unsafe_code, clippy configuration) and public API stubs
- [ ] T004 [P] Create src/main.rs with CLI entry point stub (thin wrapper over library)
- [ ] T005 [P] Add dependencies to asset_build_tool/Cargo.toml (image, tobj, clap, thiserror, log with default-features=false)
- [ ] T006 [P] Add dev-dependencies to asset_build_tool/Cargo.toml (env_logger for tests)
- [ ] T007 [P] Configure cargo-deny in asset_build_tool/deny.toml (license and advisory validation)
- [ ] T008 [P] Create asset_build_tool/tests/fixtures/ directory for test assets
- [ ] T009 [P] Add test fixture: valid_256x256.png (RGBA8, power-of-two)
- [ ] T010 [P] Add test fixture: invalid_300x200.png (non-power-of-two, should fail validation)
- [ ] T011 [P] Add test fixture: cube.obj (8 vertices, 12 triangles, fits in 1 patch)
- [ ] T012 [P] Add test fixture: teapot.obj or multi-patch mesh (~1000 vertices for patch splitting)
- [ ] T013 [P] Create host_app/assets/textures/ directory and move timber_square_planks.png from assets/source/textures/
- [ ] T014 [P] Create host_app/assets/meshes/ directory and move teapot.obj from assets/source/meshes/
- [ ] T015 [P] Add [build-dependencies] section to host_app/Cargo.toml with asset-prep = { path = "../asset_build_tool" }
- [ ] T016 [P] Create host_app/build.rs stub that calls asset_build_tool::build_assets() (initially a no-op or prints a message)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [ ] T017 [P] Create src/error.rs with AssetError enum using thiserror (Io, ImageDecode, ObjParse, InvalidDimensions, etc. per data-model.md)
- [ ] T018 [P] Create src/identifier.rs with generate_identifier function (parent dir + filename sanitization per contracts/output-format.md)
- [ ] T019 [P] Write unit tests for identifier generation in asset_build_tool/tests/identifier_tests.rs
- [ ] T020 [P] Create src/binary_writer.rs with functions to write f32/u16 arrays as little-endian binary files
- [ ] T021 [P] Write unit tests for binary writer in asset_build_tool/tests/binary_writer_tests.rs
- [ ] T022 [P] Define AssetBuildConfig and GeneratedAsset structs in src/lib.rs per data-model.md
- [ ] T023 Create src/main.rs CLI structure with clap derive API (Cli struct, Commands enum for texture/mesh subcommands per contracts/cli-interface.md)
- [ ] T024 Add --quiet global flag handling and env_logger initialization in src/main.rs

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Convert PNG to GPU Texture Format (Priority: P1) 🎯 MVP

**Goal**: Convert PNG images to RGBA8888 GPU format with power-of-two validation (8×8 to 1024×1024)

**Independent Test**: Convert a valid 256×256 PNG and verify output matches expected RGBA8888 format with correct dimensions and pixel values. No mesh data or firmware integration required.

### Tests for User Story 1

> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [ ] T025 [P] [US1] Unit test for is_power_of_two validation in asset_build_tool/tests/texture_tests.rs
- [ ] T026 [P] [US1] Unit test for texture dimension range validation (8×8 min, 1024×1024 max) in asset_build_tool/tests/texture_tests.rs
- [ ] T027 [P] [US1] Unit test for PNG to RGBA8888 conversion (grayscale, indexed, RGB, RGBA inputs) in asset_build_tool/tests/texture_tests.rs
- [ ] T028 [P] [US1] Integration test for convert_texture() library function with valid_256x256.png fixture in asset_build_tool/tests/integration_tests.rs

### Implementation for User Story 1

- [ ] T029 [P] [US1] Create src/texture.rs module with TextureAsset struct per data-model.md
- [ ] T030 [US1] Implement validate_texture_dimensions function in src/texture.rs (power-of-two check, size range)
- [ ] T031 [US1] Implement load_and_convert_png function in src/texture.rs (uses image crate, converts to RGBA8)
- [ ] T032 [US1] Implement pub fn convert_texture() in src/lib.rs (public API: load, validate, convert, return TextureAsset)
- [ ] T033 [US1] Implement texture CLI command handler in src/main.rs (calls convert_texture() library function, handles errors)
- [ ] T034 [US1] Add progress output for texture conversion using log::info (dimensions, size, identifier, output path)
- [ ] T035 [US1] Run integration test with valid PNG fixture and verify TextureAsset output is correct

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently

---

## Phase 4: User Story 2 - Convert OBJ to Mesh Patches (Priority: P2)

**Goal**: Convert OBJ mesh files to GPU-compatible patch format with automatic splitting (≤16 vertices, ≤32 indices per patch)

**Independent Test**: Convert a simple cube.obj (8 vertices, 12 triangles) and verify vertex positions, UVs, normals, and indices are correctly extracted and fit in 1 patch. Convert teapot.obj and verify automatic splitting into multiple patches.

### Tests for User Story 2

- [ ] T036 [P] [US2] Unit test for mesh data validation (non-empty, correct array lengths) in asset_build_tool/tests/mesh_tests.rs
- [ ] T037 [P] [US2] Unit test for missing attribute handling (default UVs, default normals) in asset_build_tool/tests/mesh_tests.rs
- [ ] T038 [P] [US2] Unit test for patch splitting algorithm with cube fixture in asset_build_tool/tests/patch_tests.rs
- [ ] T039 [P] [US2] Unit test for patch splitting with multi-patch mesh in asset_build_tool/tests/patch_tests.rs
- [ ] T040 [P] [US2] Integration test for convert_mesh() library function with cube.obj fixture in asset_build_tool/tests/integration_tests.rs

### Implementation for User Story 2

- [ ] T041 [P] [US2] Create src/mesh.rs module with MeshAsset and VertexData structs per data-model.md
- [ ] T042 [P] [US2] Create src/patch.rs module with MeshPatch struct per data-model.md
- [ ] T043 [US2] Implement load_obj_mesh function in src/mesh.rs (uses tobj crate with triangulate=true)
- [ ] T044 [US2] Implement handle_missing_attributes function in src/mesh.rs (default UVs [0,0], default normals [0,0,0])
- [ ] T045 [US2] Implement validate_mesh_data function in src/mesh.rs (check non-empty, array lengths, index bounds)
- [ ] T046 [US2] Implement split_into_patches function in src/patch.rs (greedy sequential algorithm per research.md)
- [ ] T047 [US2] Implement pub fn convert_mesh() in src/lib.rs (public API: load, validate, split, return MeshAsset)
- [ ] T048 [US2] Implement mesh CLI command handler in src/main.rs (calls convert_mesh() library function, parse --patch-size and --index-limit)
- [ ] T049 [US2] Add progress output for mesh conversion using log::info (original vertex/triangle count, patch count, output paths)
- [ ] T050 [US2] Run integration test with cube.obj and verify single patch output is correct

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently

---

## Phase 5: User Story 3 - Generate Firmware-Compatible Output via build.rs (Priority: P3)

**Goal**: Generate Rust const arrays with include_bytes!() references to binary data files in OUT_DIR, integrated via host_app/build.rs

**Independent Test**: Run `cargo build -p pico-gs-host` and verify generated .rs files in OUT_DIR compile without errors, contain expected data structures, and binary files are accessible via include_bytes!()

### Tests for User Story 3

- [ ] T051 [P] [US3] Unit test for texture Rust wrapper generation in asset_build_tool/tests/codegen_tests.rs (verify format matches contracts/output-format.md)
- [ ] T052 [P] [US3] Unit test for mesh patch Rust wrapper generation in asset_build_tool/tests/codegen_tests.rs
- [ ] T053 [P] [US3] Unit test for master mod.rs generation in asset_build_tool/tests/codegen_tests.rs
- [ ] T054 [P] [US3] Integration test for build_assets() library function with fixture directory in asset_build_tool/tests/integration_tests.rs

### Implementation for User Story 3

- [ ] T055 [P] [US3] Create src/codegen.rs module with OutputFile and BinaryFile structs per data-model.md
- [ ] T056 [US3] Implement generate_texture_output function in src/codegen.rs (creates .rs wrapper with WIDTH, HEIGHT, DATA consts and .bin file per contracts/output-format.md)
- [ ] T057 [US3] Implement generate_mesh_patch_output function in src/codegen.rs (creates .rs wrapper with VERTEX_COUNT, INDEX_COUNT, POSITIONS, UVS, NORMALS, INDICES consts and 4 .bin files)
- [ ] T058 [US3] Implement write_output_files function in src/codegen.rs (writes .rs and .bin files to output directory)
- [ ] T059 [US3] Implement generate_mod_rs function in src/codegen.rs (generates master mod.rs that re-exports all asset modules via include!())
- [ ] T060 [US3] Implement pub fn build_assets() in src/lib.rs (public API: scan source_dir, convert all assets, write to out_dir, generate mod.rs, return Vec<GeneratedAsset>)
- [ ] T061 [US3] Implement host_app/build.rs to call build_assets() with correct paths (CARGO_MANIFEST_DIR/assets → OUT_DIR/assets)
- [ ] T062 [US3] Add cargo:rerun-if-changed directives in host_app/build.rs for source asset directory and individual files
- [ ] T063 [US3] Update host_app/src/assets/mod.rs to use include!(concat!(env!("OUT_DIR"), "/assets/mod.rs"))
- [ ] T064 [US3] Add metadata comments to generated .rs files (source path, dimensions/counts, memory requirements per contracts/output-format.md)
- [ ] T065 [US3] Integrate output generation into convert_texture() and convert_mesh() library functions (or as separate step in build_assets())
- [ ] T066 [US3] Run cargo build -p pico-gs-host and verify assets are generated and firmware compiles

**Checkpoint**: Full pipeline working — cargo build -p pico-gs-host converts assets and compiles firmware in one step

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories and final verification

- [ ] T067 [P] Add comprehensive rustdoc comments to all public items in src/lib.rs, src/texture.rs, src/mesh.rs, src/patch.rs, src/codegen.rs
- [ ] T068 [P] Verify all error messages are actionable per success criterion SC-009 (include suggestions for fixes)
- [ ] T069 [P] Simplify build.sh to remove asset orchestration steps (Steps 1-2), since cargo build now handles assets via build.rs
- [ ] T070 Run cargo fmt to format all code
- [ ] T071 Run cargo fmt --check to verify formatting
- [ ] T072 Run cargo clippy -- -D warnings to check for lints
- [ ] T073 Run cargo test -p asset-prep to execute all unit, integration, and contract tests
- [ ] T074 Run cargo build -p pico-gs-host --release to verify release build with asset generation
- [ ] T075 Run cargo doc --no-deps -p asset-prep to generate documentation
- [ ] T076 Run cargo deny check to validate licenses and advisories
- [ ] T077 Run cargo audit to scan for security vulnerabilities
- [ ] T078 Test full workflow: add a new PNG to host_app/assets/textures/, run cargo build, verify it appears in firmware
- [ ] T079 Update CLAUDE.md project structure and build commands to reflect library + build.rs architecture

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-5)**: All depend on Foundational phase completion
  - User stories can then proceed in parallel (if staffed)
  - Or sequentially in priority order (P1 → P2 → P3)
- **Polish (Phase 6)**: Depends on all desired user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 2 (P2)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 3 (P3)**: Integrates with US1 and US2 via build_assets(), but codegen can be tested independently with fixtures. build.rs integration (T061-T063) depends on US1 and US2 having working convert functions.

### Within Each User Story

- Tests (if included) MUST be written and FAIL before implementation
- Module creation before function implementation
- Validation/parsing before processing
- Library API functions before CLI wrappers
- Integration tests after implementation complete
- Story complete before moving to next priority

### Parallel Opportunities

- All Setup tasks marked [P] can run in parallel
- All Foundational tasks marked [P] can run in parallel (within Phase 2)
- Once Foundational phase completes, all user stories can start in parallel (if team capacity allows)
- All tests for a user story marked [P] can run in parallel
- Modules within a story marked [P] can run in parallel (e.g., texture.rs and error.rs are independent)

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (including host_app/build.rs stub)
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1 (PNG texture conversion)
4. **STOP and VALIDATE**: Test User Story 1 independently with various PNG files
5. Run build verification (cargo fmt, clippy, test, build --release)

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 (PNG textures) → Test independently → MVP complete!
3. Add User Story 2 (OBJ meshes) → Test independently → Mesh support added
4. Add User Story 3 (Firmware output via build.rs) → `cargo build` now handles everything → Full pipeline complete
5. Each story adds value without breaking previous stories

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: User Story 1 (PNG conversion)
   - Developer B: User Story 2 (OBJ parsing and patching)
   - Developer C: User Story 3 (Output generation + build.rs integration)
3. Stories complete and integrate independently

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Verify tests fail before implementing (TDD approach per Article V)
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Follow Article X: Rust Code Standards for all implementations (thiserror for errors, log for output, no unwrap/expect)
- Build verification must pass before considering feature complete (fmt, clippy, test, deny, audit)
- Library API is the primary interface; CLI wraps library functions for debugging
- Generated output goes to OUT_DIR (ephemeral), source assets are committed in host_app/assets/

---

## Task Count Summary

- **Phase 1 (Setup)**: 16 tasks
- **Phase 2 (Foundational)**: 8 tasks (BLOCKING)
- **Phase 3 (User Story 1 - Textures)**: 11 tasks (4 tests + 7 implementation)
- **Phase 4 (User Story 2 - Meshes)**: 15 tasks (5 tests + 10 implementation)
- **Phase 5 (User Story 3 - Output + build.rs)**: 16 tasks (4 tests + 12 implementation)
- **Phase 6 (Polish)**: 13 tasks

**Total**: 79 tasks

**Parallel opportunities**: ~35 tasks marked [P] can run in parallel within their phase
**Test coverage**: 13 test tasks ensuring comprehensive validation per Article V
**Independent stories**: Each user story (US1, US2, US3) can be tested and delivered independently
**Key addition**: Phase 5 now includes build.rs integration (T061-T063) and master mod.rs generation (T059)
