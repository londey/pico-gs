# Tasks: Asset Data Preparation Tool

**Input**: Design documents from `/specs/003-asset-data-prep/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Per Article V (Test-First Development), all modules require test coverage.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Workspace member**: `asset_build_tool/` at repository root
- Paths shown below use `asset_build_tool/src/` and `asset_build_tool/tests/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [ ] T001 Create asset_build_tool directory and Cargo.toml manifest
- [ ] T002 Add asset_build_tool to workspace members in root Cargo.toml
- [ ] T003 [P] Create src/lib.rs with crate-level lints per Article X (deny unsafe_code, clippy configuration)
- [ ] T004 [P] Create src/main.rs with CLI entry point stub
- [ ] T005 [P] Add dependencies to asset_build_tool/Cargo.toml (image, tobj, clap, thiserror, log with default-features=false)
- [ ] T006 [P] Add dev-dependencies to asset_build_tool/Cargo.toml (env_logger for tests)
- [ ] T007 [P] Configure cargo-deny in asset_build_tool/deny.toml (license and advisory validation)
- [ ] T008 [P] Create asset_build_tool/tests/fixtures/ directory for test assets
- [ ] T009 [P] Add test fixture: valid_256x256.png (RGBA8, power-of-two)
- [ ] T010 [P] Add test fixture: invalid_300x200.png (non-power-of-two, should fail validation)
- [ ] T011 [P] Add test fixture: cube.obj (8 vertices, 12 triangles, fits in 1 patch)
- [ ] T012 [P] Add test fixture: teapot.obj or multi-patch mesh (~1000 vertices for patch splitting)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [ ] T013 [P] Create src/error.rs with AssetError enum using thiserror (Io, ImageDecode, ObjParse, InvalidDimensions, etc. per data-model.md)
- [ ] T014 [P] Create src/identifier.rs with generate_identifier function (parent dir + filename sanitization per contracts/output-format.md)
- [ ] T015 [P] Write unit tests for identifier generation in asset_build_tool/tests/identifier_tests.rs
- [ ] T016 [P] Create src/binary_writer.rs with functions to write f32/u16 arrays as little-endian binary files
- [ ] T017 [P] Write unit tests for binary writer in asset_build_tool/tests/binary_writer_tests.rs
- [ ] T018 Create src/main.rs CLI structure with clap derive API (Cli struct, Commands enum for texture/mesh subcommands per contracts/cli-interface.md)
- [ ] T019 Add --quiet global flag handling and env_logger initialization in src/main.rs

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Convert PNG to GPU Texture Format (Priority: P1) 🎯 MVP

**Goal**: Convert PNG images to RGBA8888 GPU format with power-of-two validation (8×8 to 1024×1024)

**Independent Test**: Convert a valid 256×256 PNG and verify output matches expected RGBA8888 format with correct dimensions and pixel values. No mesh data or firmware integration required.

### Tests for User Story 1

> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [ ] T020 [P] [US1] Unit test for is_power_of_two validation in asset_build_tool/tests/texture_tests.rs
- [ ] T021 [P] [US1] Unit test for texture dimension range validation (8×8 min, 1024×1024 max) in asset_build_tool/tests/texture_tests.rs
- [ ] T022 [P] [US1] Unit test for PNG to RGBA8888 conversion (grayscale, indexed, RGB, RGBA inputs) in asset_build_tool/tests/texture_tests.rs
- [ ] T023 [P] [US1] Integration test for texture CLI command with valid_256x256.png fixture in asset_build_tool/tests/integration_tests.rs

### Implementation for User Story 1

- [ ] T024 [P] [US1] Create src/texture.rs module with TextureAsset struct per data-model.md
- [ ] T025 [US1] Implement validate_texture_dimensions function in src/texture.rs (power-of-two check, size range)
- [ ] T026 [US1] Implement load_and_convert_png function in src/texture.rs (uses image crate, converts to RGBA8)
- [ ] T027 [US1] Implement texture CLI command handler in src/main.rs (parse args, call texture module, handle errors)
- [ ] T028 [US1] Add progress output for texture conversion using log::info (dimensions, size, identifier, output path)
- [ ] T029 [US1] Run integration test with valid PNG fixture and verify .rs and .bin files are generated correctly

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently

---

## Phase 4: User Story 2 - Convert OBJ to Mesh Patches (Priority: P2)

**Goal**: Convert OBJ mesh files to GPU-compatible patch format with automatic splitting (≤16 vertices, ≤32 indices per patch)

**Independent Test**: Convert a simple cube.obj (8 vertices, 12 triangles) and verify vertex positions, UVs, normals, and indices are correctly extracted and fit in 1 patch. Convert teapot.obj and verify automatic splitting into multiple patches.

### Tests for User Story 2

- [ ] T030 [P] [US2] Unit test for mesh data validation (non-empty, correct array lengths) in asset_build_tool/tests/mesh_tests.rs
- [ ] T031 [P] [US2] Unit test for missing attribute handling (default UVs, default normals) in asset_build_tool/tests/mesh_tests.rs
- [ ] T032 [P] [US2] Unit test for patch splitting algorithm with cube fixture in asset_build_tool/tests/patch_tests.rs
- [ ] T033 [P] [US2] Unit test for patch splitting with multi-patch mesh in asset_build_tool/tests/patch_tests.rs
- [ ] T034 [P] [US2] Integration test for mesh CLI command with cube.obj fixture in asset_build_tool/tests/integration_tests.rs

### Implementation for User Story 2

- [ ] T035 [P] [US2] Create src/mesh.rs module with MeshAsset and VertexData structs per data-model.md
- [ ] T036 [P] [US2] Create src/patch.rs module with MeshPatch struct per data-model.md
- [ ] T037 [US2] Implement load_obj_mesh function in src/mesh.rs (uses tobj crate with triangulate=true)
- [ ] T038 [US2] Implement handle_missing_attributes function in src/mesh.rs (default UVs [0,0], default normals [0,0,0])
- [ ] T039 [US2] Implement validate_mesh_data function in src/mesh.rs (check non-empty, array lengths, index bounds)
- [ ] T040 [US2] Implement split_into_patches function in src/patch.rs (greedy sequential algorithm per research.md)
- [ ] T041 [US2] Implement mesh CLI command handler in src/main.rs (parse args including --patch-size and --index-limit, call mesh module)
- [ ] T042 [US2] Add progress output for mesh conversion using log::info (original vertex/triangle count, patch count, output paths)
- [ ] T043 [US2] Run integration test with cube.obj and verify single patch output is correct

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently

---

## Phase 5: User Story 3 - Generate Firmware-Compatible Output (Priority: P3)

**Goal**: Generate Rust const arrays with include_bytes!() references to binary data files for direct firmware inclusion

**Independent Test**: Include generated .rs files in a test firmware build and verify they compile without errors, contain expected data structures, and binary files are accessible via include_bytes!()

### Tests for User Story 3

- [ ] T044 [P] [US3] Unit test for texture Rust wrapper generation in asset_build_tool/tests/codegen_tests.rs (verify format matches contracts/output-format.md)
- [ ] T045 [P] [US3] Unit test for mesh patch Rust wrapper generation in asset_build_tool/tests/codegen_tests.rs
- [ ] T046 [P] [US3] Contract test: Create test Rust file that includes generated texture .rs and verifies it compiles in asset_build_tool/tests/contract_tests.rs
- [ ] T047 [P] [US3] Contract test: Create test Rust file that includes generated mesh .rs and verifies it compiles with bytemuck::cast_slice in asset_build_tool/tests/contract_tests.rs

### Implementation for User Story 3

- [ ] T048 [P] [US3] Create src/codegen.rs module with OutputFile and BinaryFile structs per data-model.md
- [ ] T049 [US3] Implement generate_texture_output function in src/codegen.rs (creates .rs wrapper with WIDTH, HEIGHT, DATA consts and .bin file per contracts/output-format.md)
- [ ] T050 [US3] Implement generate_mesh_patch_output function in src/codegen.rs (creates .rs wrapper with VERTEX_COUNT, INDEX_COUNT, POSITIONS, UVS, NORMALS, INDICES consts and 4 .bin files)
- [ ] T051 [US3] Implement write_output_files function in src/codegen.rs (writes .rs and .bin files to output directory)
- [ ] T052 [US3] Integrate output generation into texture CLI command handler in src/main.rs
- [ ] T053 [US3] Integrate output generation into mesh CLI command handler in src/main.rs (loop over all patches)
- [ ] T054 [US3] Add metadata comments to generated .rs files (source path, dimensions/counts, memory requirements per contracts/output-format.md)
- [ ] T055 [US3] Run contract tests to verify generated files compile and binary data is accessible

**Checkpoint**: All user stories should now be independently functional

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [ ] T056 [P] Add comprehensive rustdoc comments to all public items in src/lib.rs, src/texture.rs, src/mesh.rs, src/patch.rs, src/codegen.rs
- [ ] T057 [P] Add usage examples to README.md (texture conversion, mesh conversion, batch processing workflow)
- [ ] T058 [P] Verify all error messages are actionable per success criterion SC-009 (include suggestions for fixes)
- [ ] T059 Run cargo fmt to format all code
- [ ] T060 Run cargo fmt --check to verify formatting
- [ ] T061 Run cargo clippy -- -D warnings to check for lints
- [ ] T062 Run cargo test to execute all unit, integration, and contract tests
- [ ] T063 Run cargo build --release to verify release build
- [ ] T064 Run cargo doc --no-deps --document-private-items to generate documentation
- [ ] T065 Run cargo deny check to validate licenses and advisories
- [ ] T066 Run cargo audit to scan for security vulnerabilities
- [ ] T067 [P] Update build.sh to invoke asset_build_tool for asset compilation
- [ ] T068 [P] Create assets/source/textures/ directory with timber_square_planks.png (existing asset)
- [ ] T069 Test full workflow: convert timber_square_planks.png using asset_build_tool and verify output

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
- **User Story 3 (P3)**: Integrates with US1 and US2 output generation, but can be implemented independently by testing with fixtures

### Within Each User Story

- Tests (if included) MUST be written and FAIL before implementation
- Module creation before function implementation
- Validation/parsing before processing
- CLI command handlers after core logic
- Integration tests after implementation complete
- Story complete before moving to next priority

### Parallel Opportunities

- All Setup tasks marked [P] can run in parallel
- All Foundational tasks marked [P] can run in parallel (within Phase 2)
- Once Foundational phase completes, all user stories can start in parallel (if team capacity allows)
- All tests for a user story marked [P] can run in parallel
- Modules within a story marked [P] can run in parallel (e.g., texture.rs and error.rs are independent)
- Different user stories can be worked on in parallel by different team members

---

## Parallel Example: User Story 1

```bash
# Launch all tests for User Story 1 together:
Task: "Unit test for is_power_of_two validation in asset_build_tool/tests/texture_tests.rs"
Task: "Unit test for texture dimension range validation in asset_build_tool/tests/texture_tests.rs"
Task: "Unit test for PNG to RGBA8888 conversion in asset_build_tool/tests/texture_tests.rs"
Task: "Integration test for texture CLI command in asset_build_tool/tests/integration_tests.rs"

# Launch all modules for User Story 1 together:
Task: "Create src/texture.rs module with TextureAsset struct"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1 (PNG texture conversion)
4. **STOP and VALIDATE**: Test User Story 1 independently with various PNG files
5. Run build verification (cargo fmt, clippy, test, build --release)

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 (PNG textures) → Test independently → MVP complete!
3. Add User Story 2 (OBJ meshes) → Test independently → Mesh support added
4. Add User Story 3 (Firmware output) → Test independently → Full pipeline complete
5. Each story adds value without breaking previous stories

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: User Story 1 (PNG conversion)
   - Developer B: User Story 2 (OBJ parsing and patching)
   - Developer C: User Story 3 (Output generation for both)
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

---

## Task Count Summary

- **Phase 1 (Setup)**: 12 tasks
- **Phase 2 (Foundational)**: 7 tasks (BLOCKING)
- **Phase 3 (User Story 1 - Textures)**: 10 tasks (4 tests + 6 implementation)
- **Phase 4 (User Story 2 - Meshes)**: 14 tasks (5 tests + 9 implementation)
- **Phase 5 (User Story 3 - Output)**: 12 tasks (4 tests + 8 implementation)
- **Phase 6 (Polish)**: 14 tasks

**Total**: 69 tasks

**Parallel opportunities**: 32 tasks marked [P] can run in parallel within their phase
**Test coverage**: 15 test tasks ensuring comprehensive validation per Article V
**Independent stories**: Each user story (US1, US2, US3) can be tested and delivered independently
