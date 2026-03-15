# Quality Metrics

This document defines quality attributes and metrics for the pico-gs GPU, focusing on **controllable design decisions** relevant to a home project.

**Scope:** Metrics that can be influenced by design choices (FPGA resource usage, RTL code quality, Verilator test coverage). Excludes fixed hardware constraints (clock frequencies, external SDRAM bandwidth) and industrial reliability requirements.
Host application resource metrics (RP2350 SRAM/Flash usage, firmware code size) are tracked in the pico-racer repository (https://github.com/londey/pico-racer).

---

## Resource Utilization

### FPGA Resources (ECP5-25k)

#### Logic Utilization (LUTs)

- **Budget:** 24,000 LUTs available
- **Target:** ≤ 18,000 LUTs (75% utilization)
- **Critical Threshold:** ≤ 21,600 LUTs (90% - routing difficulty increases beyond this)
- **Measurement Method:** Yosys synthesis report + nextpnr-ecp5 utilization report
- **References:** REQ-011.02 (Resource Constraints)
- **Rationale:** Leaves headroom for future features and ensures reliable place-and-route

#### Flip-Flop Utilization

- **Budget:** 12,000 flip-flops available
- **Target:** ≤ 9,000 flip-flops (75% utilization)
- **Critical Threshold:** ≤ 10,800 flip-flops (90%)
- **Measurement Method:** nextpnr-ecp5 utilization report
- **References:** REQ-011.02
- **Rationale:** Adequate headroom for design changes

#### Embedded Memory (BRAM)

- **Budget:** 1,008 Kbits (126 KB) available
- **Target:** ≤ 756 Kbits (95 KB, 75% utilization)
- **Critical Threshold:** ≤ 907 Kbits (113 KB, 90%)
- **Current Allocation:**
  - Display scanline FIFO: ~32 Kbits (4 KB, 1024 words × 32 bits)
  - SPI receive FIFO: ~8 Kbits (1 KB, EBR)
  - Command FIFO: distributed RAM (~2.3 Kbits, 72 bits × 32 entries, not EBR)
  - Texture cache (4 samplers × 4 banks): ~288 Kbits (36 KB, 16 EBR blocks) (REQ-003.08)
  - **Total EBR allocated:** ~328 Kbits (~41 KB)
  - **Headroom:** ~428 Kbits (~54 KB) for future features
- **Measurement Method:** nextpnr-ecp5 BRAM utilization report
- **References:** REQ-011.02, REQ-003.08, UNIT-006, UNIT-008 (Display Controller)
- **Rationale:** Texture cache is the primary BRAM consumer; remaining headroom for larger FIFOs or additional caches.
  The command FIFO (UNIT-002) uses distributed RAM backed by a regular memory array (not EBR) to support bitstream-initialized boot commands (REQ-001.04).
  Its 32-entry depth is accounted for in LUT utilization rather than BRAM.

---

## Timing Closure

### Static Timing Analysis

- **Requirement:** All logic paths meet 100 MHz system clock constraint (10 ns period)
- **Target:** ≥ 0.5 ns positive slack on critical paths
- **Minimum Acceptable:** ≥ 0.0 ns (no negative slack)
- **Analysis Method:** nextpnr-ecp5 static timing analysis report
- **References:** REQ-011.01 (Performance Targets), INT-011 (SRAM Memory Layout)
- **Rationale:** Ensures reliable operation at target frequency; 0.5 ns margin provides safety buffer for PVT variations
- **Note:** This is verification that the design meets the fixed 100 MHz clock requirement, not a metric to optimize

### Critical Path Delay

- **Target:** ≤ 9.5 ns (allows 0.5 ns slack @ 100 MHz)
- **Measurement Method:** Longest combinational path delay from nextpnr timing report
- **References:** REQ-011.01
- **Rationale:** Identifies bottlenecks for optimization if timing fails

---

## Code Quality

### RTL Testbench Coverage

- **Target:** ≥ 80% toggle coverage, ≥ 60% FSM state coverage
- **Minimum Acceptable:** ≥ 60% toggle, ≥ 40% FSM state
- **Measurement Method:** Verilator coverage analysis
- **Scope:** Critical modules (rasterizer, SDRAM controller, display controller)
- **References:** Internal quality goal
- **Rationale:** Focus coverage efforts on complex state machines and critical data paths

### Cyclomatic Complexity

- **Target:** ≤ 20 per module (SystemVerilog)
- **Minimum Acceptable:** ≤ 30 per module (SystemVerilog)
- **Measurement Method:** Static analysis tools (SystemVerilog)
- **References:** Internal quality goal
- **Rationale:** Keeps RTL maintainable for a hobby project; easier to understand and debug

### Documentation Coverage

- **Target:** All public module ports and parameters documented with inline comments
- **Measurement Method:** Manual review of RTL source files
- **Scope:** All modules in `spi_gpu/src/`
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

- **Theoretical Maximum:** ~22.5 Mpixels/second (limited by SDRAM write bandwidth accounting for row activation overhead)
- **Actual:** Content-dependent (varies with scene complexity, Z-buffer rejection rate)
- **Measurement Method:** Count pixels written to framebuffer per frame
- **References:** INT-011 (SRAM Memory Layout, bandwidth budget)
- **Note:** Real-world fill rate typically lower due to triangle setup overhead and memory contention.
  SDRAM sequential access (see UNIT-007) improves effective fill rate by amortizing row activation overhead across multiple column writes; the degree of improvement depends on average sequential run length achievable during rasterization.

### Frame Time

- **Observation:** Track actual frame times via VSYNC timing
- **Measurement Method:** Count VSYNC pulses per unit time using the Verilator interactive simulator or logic analyzer on the physical board
- **References:** UNIT-008 (Display Controller)
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
| **Timing** | Setup Slack | ≥ 0.5 ns | ≥ 0.0 ns | Meets 100 MHz clock |
| | Critical Path | ≤ 9.5 ns | ≤ 10 ns | Timing margin |
| **Code Quality** | RTL Coverage | ≥ 80% toggle | ≥ 60% toggle | Hardware verification |
| | Complexity | ≤ 20/module (SV) | ≤ 30/module | Maintainability |
| **Verification** | Req Coverage | 100% | 95% | All features verified |
| | Test Pass Rate | 100% | 100% | No regressions |

**Performance Observations** (not targets): Triangle throughput ~17k/s, fill rate ~22.5 Mpix/s (theoretical), frame time varies with content.

---

## Measurement Tools

### FPGA Synthesis and Analysis
- **Yosys:** Logic synthesis, generates RTL utilization estimates
- **nextpnr-ecp5:** Place-and-route, final resource utilization and timing analysis
  - Command: `nextpnr-ecp5 --25k --package CABGA256 --freq 100 --timing-allow-fail`
- **Verilator:** RTL simulation and coverage analysis

### Performance Profiling
- **Verilator simulation:** Triangle count, pixel count via RTL debug signals
- **Logic analyzer / oscilloscope:** VSYNC period and SPI transaction timing on physical hardware

---

## References

- [REQ-011.01: Performance Targets](req_050_performance_targets.md)
- [REQ-011.02: Resource Constraints](req_011.02_resource_constraints.md)
- [REQ-011.03: Reliability Requirements](req_052_reliability_requirements.md)
- [INT-011: SDRAM Memory Layout](../interfaces/int_011_sram_memory_layout.md) (bandwidth budget)
- [UNIT-005: Rasterizer](../design/unit_005_rasterizer.md)
- [UNIT-008: Display Controller](../design/unit_008_display_controller.md)
