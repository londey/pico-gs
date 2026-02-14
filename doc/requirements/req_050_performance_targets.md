# REQ-050: Performance Targets

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Analysis

## Requirement

When rendering typical scene content, the system SHALL achieve frame rates and throughput sufficient for interactive rendering as measured by the performance observations defined in quality_metrics.md.

## Rationale

Performance is highly content-dependent (triangle count, overdraw, texture cache hit rate). Rather than setting arbitrary numeric targets, this requirement establishes that the system must support interactive rendering for typical scenes.

**Target Use Case:** Low-poly textured and lit animated models (e.g., skeletal animated T-Rex) at interactive frame rates (≥15 FPS).

**Hardware Constraints:**
- 100 MHz unified GPU core and SRAM clock (single clock domain for rendering pipeline and memory)
- 16-bit SRAM bus at 100 MHz (200 MB/s theoretical)
- 25 MHz pixel clock derived as a synchronous 4:1 divisor from the 100 MHz core clock
- 25 MHz QSPI command interface (72-bit transactions = ~3 MB/s command bandwidth)

**Actual Performance Observations** (tracked in quality_metrics.md):
- Triangle throughput: ~17,000 triangles/second @ 60 fps (SpinningTeapot: 288 tri/frame)
- Fill rate: ~25 Mpixels/second theoretical maximum (one pixel per core clock cycle at 100 MHz, limited by SRAM bandwidth)
- Frame time: Content-dependent (simple scenes may exceed 60 FPS, complex scenes may drop below)
- Early Z rejection: Reduces effective fill cost for overdraw-heavy scenes by skipping texture and blending stages for occluded fragments (see REQ-014). Benefit scales with overdraw ratio; scenes with 2-3x overdraw may see 30-50% reduction in SRAM texture bandwidth.

These performance characteristics place the system in the PSX-to-N64 capability range given the hardware constraints.

## Parent Requirements

None

## Allocated To

- All hardware and firmware units (system-wide)

## Interfaces

- INT-010 (GPU Register Map)
- INT-011 (SRAM Memory Layout)

## Verification Method

**Analysis:** Measure actual performance/resource usage against observations defined in quality_metrics.md:

- [ ] Measure triangle throughput for typical test scenes (flat, Gouraud, textured)
- [ ] Measure fill rate for typical pixel workloads (cache hit vs cache miss)
- [ ] Measure frame time for reference scenes (SpinningTeapot, low-poly animated model)
- [ ] Verify interactive frame rate (≥15 FPS) for target use case content
- [ ] Document actual performance observations in quality_metrics.md

## Notes

Performance targets are **content-dependent observations**, not fixed requirements. See [quality_metrics.md](quality_metrics.md) for detailed performance measurements and analysis.

Specific resource constraints (FPGA LUT/EBR usage, SRAM/Flash budgets) are defined in REQ-051.
Reliability and timing constraints are defined in REQ-052 and quality_metrics.md.
