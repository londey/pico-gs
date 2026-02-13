# REQ-051: Resource Constraints

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Analysis

## Requirement

The system SHALL meet the resource constraints defined in the specification.

## Rationale

These targets ensure the system meets performance, resource, and reliability expectations.

## Parent Requirements

None

## Allocated To

- All GPU hardware units (UNIT-001 through UNIT-009)

## Interfaces

- INT-010 (GPU Register Map)
- INT-011 (SRAM Memory Layout)

## Functional Requirements

### FR-051-1: FPGA Resource Budget

The GPU design SHALL fit within the following ECP5-25K resource budget:

| Resource | Budget | Allocation |
|----------|--------|------------|
| EBR (9kb blocks) | ≤18 of 56 (32.1%) | 16 texture cache + 1 dither matrix + 1 color grade LUT |
| DSP slices (18x18) | ≤16 of 28 (57%) | 10.8 multipliers for texture blend, Gouraud shade, alpha blend |
| SERDES channels | 4 of 4 | DVI TMDS (3 data + 1 clock) |

### FR-051-2: Pipeline Timing

All pixel pipeline stages SHALL be fully pipelined with no throughput reduction:

- Depth range clipping: combinational comparison (0 additional cycles, ~20-40 LUTs for two 16-bit comparators)
- Early Z-test: reuses existing Z-buffer read port (0 additional cycles when bypassed; ~0 additional LUTs, reorders existing Z-test logic)
- Texture format promotion: combinational (0 additional cycles)
- Ordered dithering: 1 cycle EBR read (pipelined, no stall)
- Color grading LUT: 2 cycle scanout latency (within pixel period at 100MHz)

## Verification Method

**Analysis:** Measure actual performance/resource usage against targets.

- [ ] EBR usage ≤18 blocks after synthesis
- [ ] DSP slice usage ≤16 after synthesis
- [ ] SERDES usage = 4 channels
- [ ] No pipeline throughput reduction from dithering or 10.8 math
- [ ] Color grading LUT latency ≤2 cycles at scanout

## Notes

Non-functional requirement. See specifications for specific numeric targets.

EBR budget increased from 16 to 18 blocks to accommodate ordered dithering matrix (1 EBR, REQ-132) and color grading LUT (1 EBR, REQ-133). DSP budget added for 10.8 fixed-point multipliers (REQ-134).
