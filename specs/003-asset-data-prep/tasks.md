# Tasks: Asset Data Preparation Library

**Input**: Design documents from `/specs/003-asset-data-prep/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Included per constitution Article I (Test-First Development) and plan.md verification strategy.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Library crate**: `asset_build_tool/src/`, `asset_build_tool/tests/`
- **Firmware crate**: `host_app/src/`, `host_app/build.rs`
- **Workspace root**: `Cargo.toml`, `build.sh`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization, workspace configuration, and dependency setup

- [x] T001 Create `asset_build_tool/Cargo.toml` with library + optional binary targets, add dependencies: `image` (default-features=false, features=["png"]), `tobj`, `thiserror`, `log`, `clap` (features=["derive"], optional for binary)
- [x] T002 Register `asset_build_tool` as workspace member in root `Cargo.toml`
- [x] T003 [P] Create `asset_build_tool/src/lib.rs` with module declarations (texture, mesh, patch, codegen, identifier, error) and public API stubs for `build_assets()`, `convert_texture()`, `convert_mesh()`, `generate_mod_rs()`
- [x] T004 [P] Create `asset_build_tool/src/error.rs` with `AssetError` enum using `thiserror` (variants: Io, ImageDecode, ObjParse, Validation, IdentifierCollision, CodeGen)
- [x] T005 [P] Create directory structure: `host_app/assets/textures/`, `host_app/assets/meshes/`, `asset_build_tool/tests/fixtures/`
- [x] T006 [P] Create test fixture files in `asset_build_tool/tests/fixtures/`: `valid_8x8.png` (8x8 RGBA), `valid_256x256.png` (256x256 RGBA), `invalid_300x200.png` (non-power-of-two), `cube.obj` (simple 8-vertex cube with UVs and normals)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core shared modules that ALL user stories depend on — identifier generation and collision detection

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

### Tests for Foundational

> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T007 [P] Write unit tests for identifier generation in `asset_build_tool/tests/identifier_tests.rs`: test sanitization rules (alphanumeric passthrough, special chars to underscore, uppercase conversion), parent directory inclusion (`textures/player.png` → `TEXTURES_PLAYER`), leading digit prefix (`3d-cube` → `_3D_CUBE`), edge cases (no parent dir, deeply nested paths)
- [x] T008 [P] Write unit tests for identifier collision detection in `asset_build_tool/tests/identifier_tests.rs`: test that `foo@bar.png` and `foo_bar.png` both mapping to `FOO_BAR` triggers `IdentifierCollision` error, test no collision with distinct identifiers

### Implementation for Foundational

- [x] T009 Implement identifier generation function in `asset_build_tool/src/identifier.rs`: extract parent directory + filename, sanitize to valid Rust identifier, uppercase conversion, leading-digit handling per data-model.md Stage 4 algorithm
- [x] T010 Implement identifier collision detection in `asset_build_tool/src/identifier.rs`: accept list of source paths, generate identifiers, detect and report collisions with clear error listing conflicting files
- [x] T011 Verify foundational tests pass: `cargo test -p asset_build_tool -- identifier`

**Checkpoint**: Identifier generation and collision detection fully working and tested

---

## Phase 3: User Story 1 — Convert PNG to GPU Texture Format (Priority: P1) 🎯 MVP

**Goal**: Convert standard PNG images to RGBA8888 format with power-of-two dimension validation (8×8 to 1024×1024), generating Rust wrapper + binary output files

**Independent Test**: Convert a single PNG image (e.g., 256×256), verify output `.rs` and `.bin` files match expected RGBA8888 format with correct dimensions and pixel values

### Tests for User Story 1

> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T012 [P] [US1] Write unit tests for texture dimension validation in `asset_build_tool/tests/texture_tests.rs`: valid power-of-two dims (8, 16, 32, 64, 128, 256, 512, 1024), invalid non-power-of-two (300×200), below minimum (4×4), above maximum (2048×2048), non-square valid (256×128)
- [x] T013 [P] [US1] Write unit tests for texture format conversion in `asset_build_tool/tests/texture_tests.rs`: RGBA passthrough preserves alpha, grayscale to RGBA replication, pixel data length equals width×height×4
- [x] T014 [P] [US1] Write unit tests for texture output generation in `asset_build_tool/tests/texture_tests.rs`: generated `.rs` file contains correct const declarations (`{ID}_WIDTH`, `{ID}_HEIGHT`, `{ID}_DATA`), `.bin` file size matches width×height×4, `include_bytes!()` reference uses correct filename
- [x] T015 [P] [US1] Write integration test for end-to-end texture conversion in `asset_build_tool/tests/integration_tests.rs`: load `fixtures/valid_256x256.png`, call `convert_texture()`, verify output files written to temp dir, verify `.bin` content matches expected RGBA8888 bytes

### Implementation for User Story 1

- [x] T016 [US1] Implement PNG loading and dimension validation in `asset_build_tool/src/texture.rs`: use `image::open()`, validate power-of-two with `is_power_of_two()`, validate range 8-1024, return `AssetError::Validation` with actionable hints on failure
- [x] T017 [US1] Implement RGBA8888 format conversion in `asset_build_tool/src/texture.rs`: use `img.to_rgba8()` to handle grayscale/indexed/RGB→RGBA conversion, construct `TextureAsset` with pixel data, dimensions, and identifier
- [x] T018 [US1] Implement texture output file generation in `asset_build_tool/src/codegen.rs`: `generate_texture_output()` function that writes `.rs` wrapper (with metadata comments, const declarations, `include_bytes!()`) and `.bin` file (raw RGBA8888 pixel data) per output-format.md template
- [x] T019 [US1] Wire up `convert_texture()` public API in `asset_build_tool/src/lib.rs`: load PNG → validate → convert → generate identifier → write output files → return `TextureAsset`
- [x] T020 [US1] Verify US1 tests pass: `cargo test -p asset_build_tool -- texture` and `cargo test -p asset_build_tool -- integration_tests::texture`

**Checkpoint**: PNG to RGBA8888 conversion fully functional — can convert any valid PNG and generate correct `.rs` + `.bin` output

---

## Phase 4: User Story 2 — Convert OBJ to Mesh Patches (Priority: P2)

**Goal**: Convert OBJ mesh files to patch format with vertex data (positions, UVs, normals) and triangle indices, automatically splitting large meshes into patches (≤16 vertices, ≤32 indices per patch)

**Independent Test**: Convert a simple cube.obj and a complex teapot.obj, verify vertex extraction, triangulation, and patch splitting produce correct output

### Tests for User Story 2

> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T021 [P] [US2] Write unit tests for OBJ parsing in `asset_build_tool/tests/mesh_tests.rs`: extract positions/UVs/normals from valid OBJ, default UVs [0.0, 0.0] when missing, default normals [0.0, 0.0, 0.0] when missing, quad face triangulation, error on empty mesh (no vertices/faces)
- [x] T022 [P] [US2] Write unit tests for mesh merging in `asset_build_tool/tests/mesh_tests.rs`: multiple named objects/groups in single OBJ file merged into one unified mesh output per FR-014a
- [x] T023 [P] [US2] Write unit tests for patch splitting in `asset_build_tool/tests/patch_tests.rs`: single-patch mesh (≤16 verts) stays as one patch, multi-patch mesh splits correctly (no patch exceeds limits), vertex duplication across patch boundaries, all indices valid (< vertex_count), determinism verification (same input → identical output on multiple runs)
- [x] T024 [P] [US2] Write unit tests for mesh output generation in `asset_build_tool/tests/mesh_tests.rs`: generated `.rs` file per patch with correct const declarations (`{ID}_PATCH{n}_VERTEX_COUNT`, `_POSITIONS`, `_UVS`, `_NORMALS`, `_INDICES`), four `.bin` files per patch (pos/uv/norm/idx), binary data sizes match vertex/index counts
- [x] T025 [P] [US2] Write integration test for end-to-end mesh conversion in `asset_build_tool/tests/integration_tests.rs`: load `fixtures/cube.obj`, call `convert_mesh()`, verify output files in temp dir, verify binary data (little-endian f32 positions, u16 indices)
- [x] T026 [P] [US2] Create additional test fixtures: `asset_build_tool/tests/fixtures/teapot.obj` (complex mesh requiring multiple patches) and `asset_build_tool/tests/fixtures/multi_object.obj` (OBJ with multiple named objects)

### Implementation for User Story 2

- [x] T027 [US2] Implement OBJ loading and parsing in `asset_build_tool/src/mesh.rs`: use `tobj::load_obj()` with `triangulate: true`, extract positions/UVs/normals, handle missing attributes with defaults, merge all objects/groups into unified mesh, validate non-empty geometry
- [x] T028 [US2] Implement greedy sequential patch splitting algorithm in `asset_build_tool/src/patch.rs`: `split_into_patches()` per data-model.md algorithm (fill patch with triangles until vertex or index limit exceeded, start new patch), use `BTreeMap` instead of `HashMap` for deterministic vertex mapping, configurable `patch_size` and `index_limit` parameters
- [x] T029 [US2] Implement mesh output file generation in `asset_build_tool/src/codegen.rs`: `generate_mesh_output()` function that writes per-patch `.rs` wrapper and four `.bin` files (positions as f32 LE, UVs as f32 LE, normals as f32 LE, indices as u16 LE) per output-format.md template
- [x] T030 [US2] Wire up `convert_mesh()` public API in `asset_build_tool/src/lib.rs`: load OBJ → validate → merge objects → split into patches → generate identifier → write output files per patch → return `MeshAsset`
- [x] T031 [US2] Verify US2 tests pass: `cargo test -p asset_build_tool -- mesh` and `cargo test -p asset_build_tool -- patch` and `cargo test -p asset_build_tool -- integration_tests::mesh`

**Checkpoint**: OBJ to mesh patch conversion fully functional — can convert any valid OBJ, split into patches, and generate correct `.rs` + `.bin` output per patch

---

## Phase 5: User Story 3 — Seamless Build.rs Integration (Priority: P3)

**Goal**: Automatic asset conversion during firmware build via `host_app/build.rs`, scanning `host_app/assets/`, converting all `.png` and `.obj` files, generating master `mod.rs` in `OUT_DIR`, enabling single `cargo build -p pico-gs-host` command

**Independent Test**: Add a `.png` and `.obj` to `host_app/assets/`, run `cargo build -p pico-gs-host`, verify generated files in `OUT_DIR`, firmware compiles with `include!()`, incremental rebuild only reconverts modified assets

### Tests for User Story 3

> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T032 [P] [US3] Write unit test for `build_assets()` in `asset_build_tool/tests/integration_tests.rs`: call with temp source dir containing sample .png and .obj files, verify `GeneratedAsset` list returned with correct module names, identifiers, source paths
- [x] T033 [P] [US3] Write unit test for empty directory handling in `asset_build_tool/tests/integration_tests.rs`: call `build_assets()` with empty source dir, verify succeeds and generates empty `mod.rs` per FR-040b
- [x] T034 [P] [US3] Write unit test for `generate_mod_rs()` in `asset_build_tool/tests/integration_tests.rs`: verify generated `mod.rs` contains `include!()` directives for all texture and mesh patch files, verify correct file ordering (sorted for determinism)
- [x] T035 [P] [US3] Write unit test for identifier collision across assets in `asset_build_tool/tests/integration_tests.rs`: source dir with files that sanitize to same identifier, verify `build_assets()` returns `IdentifierCollision` error

### Implementation for User Story 3

- [x] T036 [US3] Implement `build_assets()` in `asset_build_tool/src/lib.rs`: scan source dir for `.png` (in `textures/` subdir) and `.obj` (in `meshes/` subdir), sort file paths for determinism, collect identifiers and check for collisions, convert each asset, generate `mod.rs`, return `Vec<GeneratedAsset>` with source paths for `rerun-if-changed`
- [x] T037 [US3] Implement `generate_mod_rs()` in `asset_build_tool/src/codegen.rs`: write `$OUT_DIR/assets/mod.rs` with `include!()` for each generated `.rs` file (textures section + meshes section), sorted alphabetically for determinism, include "auto-generated" header comment
- [x] T038 [US3] Create `host_app/build.rs`: invoke `asset_build_tool::build_assets()` with `AssetBuildConfig` (source_dir = `CARGO_MANIFEST_DIR/assets`, out_dir = `OUT_DIR/assets`), emit `cargo:rerun-if-changed` for source dir and each source file, fail build on any error via `expect()`
- [x] T039 [US3] Add `asset_build_tool` as `[build-dependencies]` in `host_app/Cargo.toml` (path dependency: `{ path = "../asset_build_tool" }`)
- [x] T040 [US3] Create `host_app/src/assets/mod.rs` with `include!(concat!(env!("OUT_DIR"), "/assets/mod.rs"))` to wire generated assets into firmware
- [x] T041 [US3] Implement optional CLI binary in `asset_build_tool/src/main.rs`: `clap` derive with `texture` and `mesh` subcommands, `--quiet` global flag, thin wrapper calling library `convert_texture()` / `convert_mesh()`, progress output via `log` crate, error exit codes per cli-interface.md contract
- [x] T042 [US3] Verify US3 tests pass: `cargo test -p asset_build_tool -- integration_tests::build_assets` and verify `cargo build -p pico-gs-host` succeeds with placeholder assets in `host_app/assets/`

**Checkpoint**: Full build pipeline functional — `cargo build -p pico-gs-host` automatically converts all assets and embeds them in firmware

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Build script cleanup, final verification, and cross-cutting improvements

- [x] T043 [P] Simplify `build.sh` to remove any asset-specific orchestration steps (asset conversion now handled by build.rs, `--assets-only` flag can delegate to `cargo build -p pico-gs-host`)
- [x] T044 [P] Add Rustdoc comments for all public items in `asset_build_tool/src/lib.rs`, `texture.rs`, `mesh.rs`, `patch.rs`, `codegen.rs`, `identifier.rs`, `error.rs`
- [x] T045 Run full build verification: `cargo fmt --check -p asset_build_tool`, `cargo clippy -p asset_build_tool -- -D warnings`, `cargo test -p asset_build_tool`, `cargo build -p pico-gs-host --release`
- [x] T046 Run quickstart.md validation: verify documented CLI examples work, verify build.rs integration steps produce expected output

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup (Phase 1) completion — BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational (Phase 2) — can start after Phase 2
- **User Story 2 (Phase 4)**: Depends on Foundational (Phase 2) — can start after Phase 2, in parallel with US1
- **User Story 3 (Phase 5)**: Depends on US1 (Phase 3) AND US2 (Phase 4) — requires working conversion for both textures and meshes
- **Polish (Phase 6)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) — No dependencies on other stories
- **User Story 2 (P2)**: Can start after Foundational (Phase 2) — No dependencies on US1, can run in parallel
- **User Story 3 (P3)**: Depends on US1 AND US2 — integrates both texture and mesh conversion into build.rs pipeline

### Within Each User Story

- Tests MUST be written and FAIL before implementation
- Validation/loading before conversion logic
- Conversion before output generation
- Output generation before public API wiring
- All tests passing before marking story complete

### Parallel Opportunities

- T003, T004, T005, T006 can all run in parallel (Phase 1, different files)
- T007, T008 can run in parallel (Phase 2 tests, different test groups)
- T012, T013, T014, T015 can all run in parallel (US1 tests, different test functions)
- T021-T026 can all run in parallel (US2 tests, different test files)
- T032-T035 can all run in parallel (US3 tests, different test functions)
- US1 (Phase 3) and US2 (Phase 4) can run in parallel after Phase 2

---

## Parallel Example: User Story 1

```bash
# Launch all tests for US1 together (write tests first):
Task: "Write unit tests for texture dimension validation in asset_build_tool/tests/texture_tests.rs"
Task: "Write unit tests for texture format conversion in asset_build_tool/tests/texture_tests.rs"
Task: "Write unit tests for texture output generation in asset_build_tool/tests/texture_tests.rs"
Task: "Write integration test for end-to-end texture conversion in asset_build_tool/tests/integration_tests.rs"
```

## Parallel Example: User Story 2

```bash
# Launch all tests for US2 together (write tests first):
Task: "Write unit tests for OBJ parsing in asset_build_tool/tests/mesh_tests.rs"
Task: "Write unit tests for mesh merging in asset_build_tool/tests/mesh_tests.rs"
Task: "Write unit tests for patch splitting in asset_build_tool/tests/patch_tests.rs"
Task: "Write unit tests for mesh output generation in asset_build_tool/tests/mesh_tests.rs"
Task: "Write integration test for end-to-end mesh conversion in asset_build_tool/tests/integration_tests.rs"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (identifier generation)
3. Complete Phase 3: User Story 1 (PNG → RGBA8888)
4. **STOP and VALIDATE**: Convert a real PNG, inspect output files
5. This alone enables textured rendering development

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 → Test independently → PNG conversion works (MVP!)
3. Add User Story 2 → Test independently → OBJ mesh conversion works
4. Add User Story 3 → Test independently → Full build.rs pipeline works
5. Each story adds value without breaking previous stories

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: User Story 1 (PNG conversion)
   - Developer B: User Story 2 (OBJ conversion)
3. Both complete → Developer A or B: User Story 3 (build.rs integration)
4. Stories complete and integrate independently

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Verify tests fail before implementing
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Determinism is critical: use sorted file paths, BTreeMap, stable algorithms (no HashMap iteration for output ordering)
- All binary output is little-endian (native for RP2350)
