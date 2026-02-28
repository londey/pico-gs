# Test Strategy

This document records the cross-cutting verification strategy: frameworks, tools, approaches, and coverage goals that apply across all verification documents.
The scope of RTL verification is Verilator-based simulation of the `spi_gpu/` SystemVerilog sources.
Rust-side verification (host firmware, asset tools) is out of scope for this document.

## Test Frameworks and Tools

### Verilator

- **Type:** Unit Test, Integration Test
- **Language/Platform:** SystemVerilog → C++ simulation (compiled with Verilator)
- **Usage:** All RTL unit testbenches (VER-001 through VER-005) and pipeline integration tests (VER-010 through VER-014) run under Verilator.
  Testbenches are written in C++ (or SystemVerilog with a DPI-C harness) and linked against the Verilated model.
- **Configuration:** `spi_gpu/Makefile` drives Verilator invocation.
  Lint flags: `--lint-only -Wall` for static checks; simulation builds use `--trace` for VCD output.
  Verilator version: 5.x (see `spi_gpu/Makefile` for the pinned version).

### Verilator Lint (Static Analysis)

- **Type:** Static Analysis
- **Language/Platform:** SystemVerilog
- **Usage:** `verilator --lint-only -Wall` is run on every RTL source file before simulation.
  All warnings are treated as errors; no pragma suppressions are permitted per the project SystemVerilog style rules.
- **Configuration:** Invoked via `cd spi_gpu && make lint`.

## Test Approaches

### Unit Testbenches

- **Description:** Each RTL module or subsystem is exercised in isolation with a dedicated C++ or SV testbench that drives inputs and checks outputs cycle-by-cycle.
  Test vectors are embedded in the testbench source or loaded from CSV files in `spi_gpu/tests/vectors/`.
- **Applicable to:** VER-001 (rasterizer), VER-002 (early Z), VER-003 (register file), VER-004 (color combiner), VER-005 (texture decoder).

### Golden Image Approval Testing

- **Description:** The rendering pipeline is simulated end-to-end under Verilator.
  The simulation harness injects render commands at the command FIFO boundary (driving UNIT-003 register-file inputs directly), renders through the full pixel pipeline and SDRAM model, then reads back the simulated framebuffer and writes it as a `.ppm` file.
  The output `.ppm` is compared pixel-exactly against a checked-in golden image.
  Any pixel difference causes the test to fail.

  To approve a new or updated golden image:
  1. Run the simulation and inspect the rendered `.ppm` visually.
  2. Copy the `.ppm` to `spi_gpu/tests/golden/<test_name>.ppm`, replacing the previous file.
  3. Commit the updated golden image with a message describing the intentional change.

- **Tool:** Pixel-exact binary diff (`diff -q` or equivalent).
  For cases where hardware rounding differs between RTL revisions, a tolerance of ±1 LSB per channel may be accepted; document any such tolerance in the relevant VER document.
- **Approved files location:** `spi_gpu/tests/golden/`
- **Applicable to:** VER-010 (Gouraud triangle), VER-011 (depth-tested overlapping triangles), VER-012 (textured triangle), VER-013 (blended/color-combined output), VER-014 (textured cube).

### Integration Simulation Harness

- **Description:** The golden image tests share a common C++ simulation harness (`spi_gpu/tests/harness/`) that:
  - Instantiates the full GPU RTL hierarchy under Verilator.
  - Provides a behavioral SDRAM model that implements the 4×4 block-tiled address layout (INT-011) and texture layout (INT-014).
  - Accepts a command script (encoded per INT-021 register-write sequences) and drives UNIT-003 register-file inputs.
  - After simulation completes, reads back framebuffer contents from the SDRAM model and serializes them as a `.ppm` file.
    The framebuffer readback uses the WIDTH_LOG2 value written to FB_CONFIG in the test command script; each test must write an explicit FB_CONFIG that establishes the surface dimensions before rendering.
- **Applicable to:** VER-010 through VER-014.

### Verilator Interactive Simulator (Development Tool)

- **Description:** A standalone Verilator application (REQ-010.02, `make sim-interactive`) that drives the GPU RTL via the same `SIM_DIRECT_CMD` injection path used by the integration harness, but renders the display controller's live pixel output to an SDL3 window rather than reading back a static framebuffer.
  Command sequences are driven by Lua scripts loaded at runtime; the base register helper script (`spi_gpu/sim/lua/gpu_regs.lua`) provides documented per-register-type helper functions.
- **Role:** Development and exploratory debug tool — complements the golden image regression tests but does not replace them.
  The golden image tests (VER-010 through VER-014) remain the formal regression check; the interactive simulator provides live visual feedback during development.
- **Not applicable to:** Any VER-NNN document.
  The interactive simulator is not a regression verification method; it produces no artifact that can be automatically compared against a reference.

## Coverage Goals

### Requirement Coverage

- **Target:** 100% of SHALL requirements have at least one VER-NNN document.
- **Measurement:** Traceability analysis via `.syskit/scripts/impl-check.sh`.

### RTL Unit Coverage

- **Target:** All RTL modules listed in `spi_gpu/src/` are exercised by at least one VER document (unit or integration).
- **Measurement:** Manual traceability table in each VER document (`Verified Design Units` section).

### Branch Coverage

- **Target:** 90% branch coverage for unit-tested modules (VER-001 through VER-005).
- **Measurement:** Verilator coverage report (`--coverage` flag); HTML report written to `spi_gpu/sim_build/coverage/`.

## Test Environments

### Verilator Simulation (Local)

- **Description:** Verilator installed on the developer workstation or CI host.
- **Purpose:** All RTL unit and integration tests.
- **Setup:** Install Verilator 5.x; run `cd spi_gpu && make test`.

### CI (GitHub Actions or equivalent)

- **Description:** Automated build and test on every commit to `master`.
- **Purpose:** Runs lint, unit tests, and golden image approval tests.
- **Setup:** See `.github/workflows/` for CI configuration (to be added alongside VER implementation).

## Test Execution

### Running All RTL Tests

```
cd spi_gpu && make test
```

This target runs Verilator lint, compiles all testbenches, executes them, and compares golden images.

### Running a Single Test

```
cd spi_gpu && make test-<ver_name>
# e.g.: make test-rasterizer
```

### CI/CD Integration

- **Pipeline:** Runs on push to `master` and on pull requests targeting `master`.
- **Triggers:** Any change under `spi_gpu/` or `registers/` triggers the RTL test suite.
- **Reporting:** Test results are reported as CI check statuses; VCD traces are uploaded as artifacts on failure.

### Manual Testing

- **When Required:** Golden image approval after an intentional rendering change.
- **Procedure:** Follow the approve/update workflow described in the Golden Image Approval Testing section above.

## Test Data Management

- **Strategy:** Test vectors for unit tests are checked into `spi_gpu/tests/vectors/` as plain-text CSV files.
  Golden images are checked into `spi_gpu/tests/golden/` as `.ppm` files.
  Large binary assets (textures for VER-012 and VER-014) are generated programmatically by the test harness and are not committed.
- **Location:** `spi_gpu/tests/`
