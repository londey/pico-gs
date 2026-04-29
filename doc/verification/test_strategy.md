# Test Strategy

This document records the cross-cutting verification strategy: frameworks, tools, approaches, and coverage goals that apply across all verification documents.
The scope of RTL verification is Verilator-based simulation of the SystemVerilog sources under `rtl/components/*/` and `integration/`.
Rust-side verification (host firmware, asset tools) is out of scope for this document.

## Test Frameworks and Tools

### Verilator

- **Type:** Unit Test, Integration Test
- **Language/Platform:** SystemVerilog → C++ simulation (compiled with Verilator)
- **Usage:** All RTL unit testbenches (VER-001 through VER-005) and pipeline integration tests (VER-010 through VER-014) run under Verilator.
  Testbenches are written in C++ (or SystemVerilog with a DPI-C harness) and linked against the Verilated model.
- **Configuration:** `integration/Makefile` drives Verilator invocation.
  Lint flags: `--lint-only -Wall` for static checks; simulation builds use `--trace` for VCD output.
  Verilator version: 5.x (see `integration/Makefile` for the pinned version).

### Verilator Lint (Static Analysis)

- **Type:** Static Analysis
- **Language/Platform:** SystemVerilog
- **Usage:** `verilator --lint-only -Wall` is run on every RTL source file before simulation.
  All warnings are treated as errors; no pragma suppressions are permitted per the project SystemVerilog style rules.
- **Configuration:** Invoked via `cd integration && make lint`.

## Shared Preconditions

These preconditions apply to every Verilator-based VER document and are not repeated per-file.
Individual VER docs list only preconditions specific to that verification (pre-loaded fixtures, unusual configuration, dependencies on other verifications).

- Verilator 5.x installed and available on `$PATH`.
- All RTL sources in the component under test compile without errors under `verilator --lint-only -Wall`; lint warnings are treated as errors.
- The testbench clock matches the target clock domain (`clk_core` at 100 MHz for pipeline tests; see each component's design doc for its clock domain).
- `cd integration && make <target>` runs the test; per-test Makefile targets are named in each VER's "Test Implementation" section.
- For golden image tests (VER-010 through VER-016, VER-024): the integration simulation harness (`rtl/tb/`) compiles successfully under Verilator; golden images live in `integration/golden/` and are approved and committed before a VER's first run.
- For texture-sampling golden image tests: the behavioral SDRAM model in `rtl/tb/` implements UNIT-011's index-cache miss handling protocol (IDLE → FETCH → WRITE_INDEX → IDLE, burst_len=8 per 4×4 index block) and the palette load FSM (IDLE → PALETTE_LOAD → IDLE, multiple 32-word bursts covering 4096 bytes per slot).
  A stub model that skips the cache miss fill FSM or palette load protocol is not sufficient.
  All texture-sampling tests require palette slot 0 to be pre-loaded before the first draw call; the pre-load sequence must appear in the test command script and be exercised by the SDRAM model.

## Design Decisions

### Reverse-Z Depth Convention

All depth-tested rendering uses the **reverse-Z** convention:

| Property | Value |
|----------|-------|
| Near plane Z | 1.0 (0xFFFF in 16-bit unsigned) |
| Far plane Z | 0.0 (0x0000) |
| Z-buffer clear value | 0x0000 |
| Z compare function | GEQUAL |

**Rationale:** With a 16-bit unsigned Z-buffer, reverse-Z produces an intuitive greyscale visualization: near objects appear white (high Z) and far objects appear black (low Z).
The cleared background (0x0000) naturally renders as black.
With floating-point Z-buffers, reverse-Z also improves precision distribution, though this benefit does not apply to integer formats.

**Convention summary:** The perspective projection matrix maps `near → 1` and `far → 0`.
Nearer fragments have *higher* Z values and pass the GEQUAL test against farther (lower Z) fragments or the cleared background (0).

## Test Approaches

### Unit Testbenches

- **Description:** Each RTL module or subsystem is exercised in isolation with a dedicated C++ or SV testbench that drives inputs and checks outputs cycle-by-cycle.
  Test vectors are embedded in the testbench source or loaded from CSV files in `integration/scripts/`.
- **Applicable to:** VER-001 (rasterizer), VER-002 (early Z), VER-003 (register file), VER-004 (color combiner), VER-005 (texture palette LUT), VER-006 (color tile cache — `tb_color_tile_cache.sv`, UNIT-013).

### Golden Image Approval Testing

- **Description:** The rendering pipeline is simulated end-to-end under Verilator.
  The simulation harness injects render commands at the command FIFO boundary (driving UNIT-003 register-file inputs directly), renders through the full pixel pipeline and SDRAM model, then reads back the simulated framebuffer and writes it as a `.ppm` file.
  The output `.ppm` is compared pixel-exactly against a checked-in golden image.
  Any pixel difference causes the test to fail.

  To approve a new or updated golden image:
  1. Run the simulation and inspect the rendered `.ppm` visually.
  2. Copy the `.ppm` to `integration/golden/<test_name>.ppm`, replacing the previous file.
  3. Commit the updated golden image with a message describing the intentional change.

- **Tool:** Pixel-exact binary diff (`diff -q` or equivalent).
  For cases where hardware rounding differs between RTL revisions, a tolerance of ±1 LSB per channel may be accepted; document any such tolerance in the relevant VER document.
- **Approved files location:** `integration/golden/`
- **Applicable to:** VER-010 (Gouraud triangle), VER-011 (depth-tested overlapping triangles), VER-012 (textured triangle), VER-013 (color-combined output), VER-014 (textured cube).
- **Re-approval triggers:** Any intentional change to rasterizer interpolation (UNIT-005), pixel pipeline orchestration (UNIT-006), color tile cache behavior (UNIT-013), texture sampling or cache behavior (UNIT-011), color combiner arithmetic (UNIT-010), `tex_format` encoding (INT-010), or texture format (collapsing to INDEXED8_2X2) requires re-running the affected tests, visually inspecting the output, and committing updated golden images.
  UNIT-013 integration (introducing the color tile cache between UNIT-006 and SDRAM arbiter port 1) triggers re-approval of all pixel-write golden image tests (VER-010, VER-011, VER-015, VER-024) once the RTL is integrated.
  The cache is pixel-exact transparent for write-only paths (blending disabled), so re-approval is expected to produce identical images; re-approval confirms this empirically.
  For VER-024 (alpha blend), the flush phase (FB_CACHE_CTRL.FLUSH_TRIGGER) must complete before framebuffer readback; the golden image comparison is not valid without the flush.
  The PR2 texture architecture change (INDEXED8_2X2 replacing all previous formats) triggers re-approval of all texture-sampling golden image tests (VER-012, VER-013, VER-014, VER-016); current golden images are expected to fail after PR2 lands.
  The commit message must describe the change that caused the image to update.

### Integration Simulation Harness

- **Description:** The golden image tests share a common C++ simulation harness (`rtl/tb/`) that:
  - Instantiates the full GPU RTL hierarchy under Verilator.
  - Provides a behavioral SDRAM model that implements the 4×4 block-tiled address layout (INT-011), the INDEXED8_2X2 index array layout (INT-014), the index-cache miss fill FSM (IDLE → FETCH → WRITE_INDEX → IDLE, burst_len=8 for 4×4 8-bit index blocks), and the palette load FSM (IDLE → PALETTE_LOAD → IDLE, up to 32-word bursts, ~128 bursts per 4096-byte palette slot).
    These FSMs are consumed by UNIT-011 (Texture Sampler — specifically UNIT-011.03 index cache and UNIT-011.06 palette LUT).
    A partial or stub SDRAM model that does not implement both FSMs is not sufficient for VER-012 through VER-014.
  - Accepts a command script (encoded as register-write sequences per INT-010 and INT-012) and drives UNIT-003 register-file inputs.
  - After simulation completes, reads back framebuffer contents from the SDRAM model and serializes them as a `.ppm` file.
    The framebuffer readback uses the WIDTH_LOG2 value written to FB_CONFIG in the test command script; each test must write an explicit FB_CONFIG that establishes the surface dimensions before rendering.
- **Cache coherency for blended primitives:** For tests that enable alpha blending (VER-024), the color tile cache (UNIT-013) performs a read-modify-write for every blended fragment: DST_COLOR is read from the cache, blended by UNIT-010, and written back.
  Self-overlapping blends (primitives that cover pixels already in the cache from earlier draw calls in the same frame) are transparent because the cache returns the most-recently-written value for the tile.
  No explicit coherency flushing is required between draw calls within a frame; a flush is only required before the SDRAM framebuffer is read externally (e.g., before FB_DISPLAY swap or before the test harness reads back the SDRAM model).
- **Post-integration re-approval:** All five golden image tests (VER-010 through VER-014) require golden image re-approval after the pixel pipeline integration change (UNIT-006 stub → functional, UNIT-005 incremental interpolation redesign).
  VER-010 and VER-011 require re-approval because the incremental interpolation redesign may shift interpolated color and Z values.
  VER-012, VER-013, and VER-014 additionally require re-approval after PR2 (INDEXED8_2X2 texture architecture), because all texture format, cache, and palette configuration changes directly alter sampled texel values.
  VER-016 requires re-approval after PR2 for the same reason (texture format changed from RGB565 to INDEXED8_2X2).
  The current golden images for VER-012 through VER-016 are expected to fail after PR2 RTL implementation lands and must not be passed as green until re-approved with INDEXED8_2X2 output.
- **Applicable to:** VER-010 through VER-014.

## Coverage Goals

### Texture Format and Filter Coverage

The supported texture format is exclusively INDEXED8_2X2 (FORMAT=4'd0, per INT-010).
The supported filter mode is exclusively NEAREST (FILTER=2'd0, per INT-010).
All texture-related golden image tests (VER-012, VER-013, VER-014, VER-016) use INDEXED8_2X2 format and NEAREST filtering only.
No BC-family, RGB565, RGBA8888, or R8 format coverage is required.
BILINEAR and TRILINEAR filter coverage is not required.

### Palette Lifecycle Coverage

VER-005 (Texture Palette LUT) provides dedicated coverage for the palette subsystem.
The following cases must be covered across VER-005 and the golden image tests:

| Coverage Item | Primary VER |
| --- | --- |
| Palette slot 0 load → sample (full 4096-byte SDRAM burst) | VER-005 |
| Palette slot 1 load → sample (independent of slot 0) | VER-005 |
| Reload palette slot 0 mid-frame (slot 0 updated while rendering) | VER-005 |
| Per-slot isolation (slot 0 reload does not alter slot 1) | VER-005 |
| Quadrant selection exhaustive (NW/NE/SW/SE for a single palette entry) | VER-005 |
| UNORM8→UQ1.8 promotion correctness on all RGBA channels | VER-005 |
| `{slot, idx, quadrant}` addressing to palette LUT | VER-005 |
| Index cache invalidation via TEXn_CFG write (does not clear palette) | VER-003 |
| Palette slot persists across TEXn_CFG write (index cache clear) | VER-003 |
| Palette-loaded texture renders correct pixel colors | VER-012 |

### Requirement Coverage

- **Target:** 100% of SHALL requirements have at least one VER-NNN document.
- **Measurement:** Traceability analysis via `.syskit/scripts/impl-check.sh`.

### RTL Unit Coverage

- **Target:** All RTL modules under `rtl/components/*/` and `integration/` are exercised by at least one VER document (unit or integration).
- **Measurement:** Manual traceability table in each VER document (`Verified Design Units` section).

### Branch Coverage

- **Target:** 90% branch coverage for unit-tested modules (VER-001 through VER-005).
- **Measurement:** Verilator coverage report (`--coverage` flag); HTML report written to `integration/sim_build/coverage/`.

## Test Environments

### Verilator Simulation (Local)

- **Description:** Verilator installed on the developer workstation or CI host.
- **Purpose:** All RTL unit and integration tests.
- **Setup:** Install Verilator 5.x; run `cd integration && make test`.

### CI (GitHub Actions or equivalent)

- **Description:** Automated build and test on every commit to `master`.
- **Purpose:** Runs lint, unit tests, and golden image approval tests.
- **Setup:** See `.github/workflows/` for CI configuration (to be added alongside VER implementation).

## Test Execution

### Running All RTL Tests

```
cd integration && make test
```

This target runs Verilator lint, compiles all testbenches, executes them, and compares golden images.

### Running a Single Test

```
cd integration && make test-<ver_name>
# e.g.: make test-rasterizer
```

### CI/CD Integration

- **Pipeline:** Runs on push to `master` and on pull requests targeting `master`.
- **Triggers:** Any change under `rtl/`, `twin/`, `integration/`, or `shared/` triggers the RTL test suite.
- **Reporting:** Test results are reported as CI check statuses; VCD traces are uploaded as artifacts on failure.

### Manual Testing

- **When Required:** Golden image approval after an intentional rendering change.
- **Procedure:** Follow the approve/update workflow described in the Golden Image Approval Testing section above.

## Test Data Management

- **Strategy:** Test vectors for unit tests are checked into `integration/scripts/` as plain-text CSV files.
  Golden images are checked into `integration/golden/` as `.ppm` files.
  Large binary assets (textures for VER-012 and VER-014) are generated programmatically by the test harness and are not committed.
- **Location:** `integration/`
