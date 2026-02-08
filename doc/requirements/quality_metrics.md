# Quality Metrics

This document defines quality attributes and metrics for the pico-gs system, focusing on **controllable design decisions** relevant to a home project.

**Scope:** Metrics that can be influenced by design choices (FPGA resource usage, code quality, test coverage). Excludes fixed hardware constraints (clock frequencies, external SRAM bandwidth) and industrial reliability requirements.

---

## Resource Utilization

### FPGA Resources (ECP5-25k)

#### Logic Utilization (LUTs)

- **Budget:** 24,000 LUTs available
- **Target:** ≤ 18,000 LUTs (75% utilization)
- **Critical Threshold:** ≤ 21,600 LUTs (90% - routing difficulty increases beyond this)
- **Measurement Method:** Yosys synthesis report + nextpnr-ecp5 utilization report
- **References:** REQ-051 (Resource Constraints)
- **Rationale:** Leaves headroom for future features and ensures reliable place-and-route

#### Flip-Flop Utilization

- **Budget:** 12,000 flip-flops available
- **Target:** ≤ 9,000 flip-flops (75% utilization)
- **Critical Threshold:** ≤ 10,800 flip-flops (90%)
- **Measurement Method:** nextpnr-ecp5 utilization report
- **References:** REQ-051
- **Rationale:** Adequate headroom for design changes

#### Embedded Memory (BRAM)

- **Budget:** 1,008 Kbits (126 KB) available
- **Target:** ≤ 756 Kbits (95 KB, 75% utilization)
- **Critical Threshold:** ≤ 907 Kbits (113 KB, 90%)
- **Current Allocation:**
  - Display scanline FIFO: ~32 Kbits (4 KB, 1024 words × 32 bits)
  - Async FIFOs (SPI, command): ~16 Kbits (2 KB)
  - **Headroom:** ~720 Kbits (~90 KB) for future features (texture cache, etc.)
- **Measurement Method:** nextpnr-ecp5 BRAM utilization report
- **References:** REQ-051, UNIT-008 (Display Controller)
- **Rationale:** Reserve space for performance optimizations (texture caching, larger FIFOs)

### Host Firmware Resources (RP2350)

#### SRAM Usage

- **Budget:** 520 KB available
- **Target:** ≤ 400 KB (77% utilization)
- **Critical Threshold:** ≤ 468 KB (90%)
- **Estimated Allocation:**
  - Stack (both cores): ~64 KB
  - Scene graph + assets: ~200 KB
  - Command queue: ~16 KB
  - Runtime data: ~100 KB
  - **Headroom:** ~140 KB
- **Measurement Method:** `cargo size` output, linker memory map analysis
- **References:** REQ-051, REQ-111 (Dual-Core Architecture)
- **Rationale:** Sufficient space for larger scenes and asset data

#### Flash Usage

- **Budget:** 4 MB (typical RP2350 flash)
- **Target:** ≤ 3 MB (75% utilization)
- **Critical Threshold:** ≤ 3.6 MB (90%)
- **Estimated Allocation:**
  - Firmware binary: ~500 KB
  - Compiled assets (meshes, textures): ~2 MB
  - **Headroom:** ~1.5 MB
- **Measurement Method:** Binary size after linking + compiled asset data size
- **References:** REQ-051, UNIT-030 through UNIT-034 (Asset Build Tool)
- **Rationale:** Space for additional demos and assets

---

## Timing Closure

### Static Timing Analysis

- **Requirement:** All logic paths meet 100 MHz system clock constraint (10 ns period)
- **Target:** ≥ 0.5 ns positive slack on critical paths
- **Minimum Acceptable:** ≥ 0.0 ns (no negative slack)
- **Analysis Method:** nextpnr-ecp5 static timing analysis report
- **References:** REQ-050 (Performance Targets), INT-011 (SRAM Memory Layout)
- **Rationale:** Ensures reliable operation at target frequency; 0.5 ns margin provides safety buffer for PVT variations
- **Note:** This is verification that the design meets the fixed 100 MHz clock requirement, not a metric to optimize

### Critical Path Delay

- **Target:** ≤ 9.5 ns (allows 0.5 ns slack @ 100 MHz)
- **Measurement Method:** Longest combinational path delay from nextpnr timing report
- **References:** REQ-050
- **Rationale:** Identifies bottlenecks for optimization if timing fails

---

## Code Quality

### Test Coverage (Rust)

- **Target:** ≥ 70% line coverage for core modules
- **Minimum Acceptable:** ≥ 50%
- **Measurement Method:** `cargo tarpaulin` or `cargo llvm-cov`
- **Scope:** `host_app/src` core modules (gpu, render, scene)
- **References:** Internal quality goal
- **Rationale:** Balance between test thoroughness and development effort for hobby project

### RTL Testbench Coverage

- **Target:** ≥ 80% toggle coverage, ≥ 60% FSM state coverage
- **Minimum Acceptable:** ≥ 60% toggle, ≥ 40% FSM state
- **Measurement Method:** Verilator coverage analysis
- **Scope:** Critical modules (rasterizer, SRAM controller, display controller)
- **References:** Internal quality goal
- **Rationale:** Focus coverage efforts on complex state machines and critical data paths

### Cyclomatic Complexity

- **Target:** ≤ 10 per function (Rust), ≤ 20 per module (SystemVerilog)
- **Minimum Acceptable:** ≤ 15 per function (Rust), ≤ 30 per module (SystemVerilog)
- **Measurement Method:** `cargo clippy` (Rust), static analysis tools (SystemVerilog)
- **References:** Internal quality goal
- **Rationale:** Keeps code maintainable for a hobby project; easier to understand and debug

### Documentation Coverage

- **Target:** All public APIs documented with rustdoc/inline comments
- **Measurement Method:** `cargo doc` warnings, manual review
- **Scope:** Public functions in `host_app/src/gpu`, `host_app/src/render`
- **References:** Internal quality goal
- **Rationale:** Helps with future development and onboarding

---

## Performance Observations

**Note:** These are measurements to track, not targets to optimize against. Performance is content-dependent (scene complexity, triangle count, overdraw).

### Triangle Throughput

- **Typical Observation:** ~17,000 triangles/second @ 60 fps (SpinningTeapot demo: 288 triangles/frame)
- **Measurement Method:** Count tri_valid pulses in rasterizer over time
- **References:** UNIT-005 (Rasterizer)
- **Note:** Varies with triangle size, depth complexity, and scene content

### Fill Rate

- **Theoretical Maximum:** 12.5 Mpixels/second (derived from 50 MB/s framebuffer write bandwidth ÷ 4 bytes/pixel)
- **Actual:** Content-dependent (varies with scene complexity, Z-buffer rejection rate)
- **Measurement Method:** Count pixels written to framebuffer per frame
- **References:** INT-011 (SRAM Memory Layout, bandwidth budget)
- **Note:** Real-world fill rate typically lower due to triangle setup overhead and memory contention

### Frame Time

- **Observation:** Track actual frame times via frame_count logging
- **Measurement Method:** Already implemented in [host_app/src/core1.rs:28-40](../../host_app/src/core1.rs#L28-L40) (logs every 120 frames)
- **References:** UNIT-021 (Core 1 Render Executor)
- **Note:** Content-dependent; simple scenes may run much faster than 60 fps, complex scenes may drop below

---

## Verification Metrics

### Requirements Coverage

- **Target:** 100% of SHALL requirements have defined verification method
- **Minimum Acceptable:** 95%
- **Measurement Method:** Traceability matrix analysis (REQ → UNIT → Test mapping)
- **References:** All REQ-NNN documents
- **Rationale:** Ensures all critical functionality is testable and verified

### Test Pass Rate

- **Target:** 100% of tests passing before any milestone or release
- **Minimum Acceptable:** 100% (no failing tests allowed)
- **Measurement Method:**
  - Rust: `cargo test` exit code
  - RTL: Verilator testbench pass/fail status
- **References:** Internal quality goal
- **Rationale:** Maintains code stability and prevents regressions

---

## Summary: Controllable Metrics

| Category | Metric | Target | Threshold | Why It Matters |
|----------|--------|--------|-----------|----------------|
| **FPGA Resources** | LUT Usage | ≤ 18,000 (75%) | ≤ 21,600 (90%) | Design complexity, future headroom |
| | BRAM Usage | ≤ 95 KB (75%) | ≤ 113 KB (90%) | Memory for FIFOs, caches |
| | Flip-Flops | ≤ 9,000 (75%) | ≤ 10,800 (90%) | Sequential logic budget |
| **Host Memory** | SRAM Usage | ≤ 400 KB (77%) | ≤ 468 KB (90%) | Scene/asset complexity |
| | Flash Usage | ≤ 3 MB (75%) | ≤ 3.6 MB (90%) | Firmware + asset budget |
| **Timing** | Setup Slack | ≥ 0.5 ns | ≥ 0.0 ns | Meets 100 MHz clock |
| | Critical Path | ≤ 9.5 ns | ≤ 10 ns | Timing margin |
| **Code Quality** | Test Coverage (Rust) | ≥ 70% | ≥ 50% | Confidence in code |
| | RTL Coverage | ≥ 80% toggle | ≥ 60% toggle | Hardware verification |
| | Complexity | ≤ 10/fn (Rust) | ≤ 15/fn | Maintainability |
| **Verification** | Req Coverage | 100% | 95% | All features verified |
| | Test Pass Rate | 100% | 100% | No regressions |

**Performance Observations** (not targets): Triangle throughput ~17k/s, fill rate ~12.5 Mpix/s (theoretical), frame time varies with content.

---

## Measurement Tools

### FPGA Synthesis and Analysis
- **Yosys:** Logic synthesis, generates RTL utilization estimates
- **nextpnr-ecp5:** Place-and-route, final resource utilization and timing analysis
  - Command: `nextpnr-ecp5 --25k --package CABGA381 --freq 100 --timing-allow-fail`
- **Verilator:** RTL simulation and coverage analysis

### Host Firmware
- **cargo size:** Binary size analysis
- **cargo tarpaulin / cargo llvm-cov:** Code coverage
- **cargo clippy:** Linting and complexity analysis
- **cargo doc:** Documentation generation and verification

### Performance Profiling
- **defmt logging:** Frame time tracking (already implemented in core1.rs)
- **Manual instrumentation:** Triangle count, pixel count via debug signals

---

## References

- [REQ-050: Performance Targets](req_050_performance_targets.md)
- [REQ-051: Resource Constraints](req_051_resource_constraints.md)
- [REQ-052: Reliability Requirements](req_052_reliability_requirements.md)
- [INT-011: SRAM Memory Layout](../interfaces/int_011_sram_memory_layout.md) (bandwidth budget)
- [UNIT-005: Rasterizer](../design/unit_005_rasterizer.md)
- [UNIT-008: Display Controller](../design/unit_008_display_controller.md)
- [UNIT-021: Core 1 Render Executor](../design/unit_021_core_1_render_executor.md)
