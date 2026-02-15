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
- INT-011 (SDRAM Memory Layout)

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
- Color grading LUT: 2 core clock cycle scanout latency (20 ns at 100 MHz, within the 40 ns pixel period)

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

The command FIFO (UNIT-002) uses distributed RAM (LUTs) rather than EBR, so its depth increase from 16 to 32 entries does not affect the EBR budget.
The 72-bit x 32-deep command FIFO consumes approximately 2,304 bits of distributed RAM, which is accounted for in the LUT budget rather than the EBR budget.

**SDRAM controller resource estimate (UNIT-007, SDRAM controller):** The SDRAM controller (sdram_controller.sv) requires approximately 200-300 LUTs and 100-150 FFs for the 8-state FSM (INIT, IDLE, ACTIVATE, READ, WRITE, PRECHARGE, REFRESH, DONE), address decomposition (byte address to bank/row/column), CAS latency pipeline (3-stage shift register), refresh timer (14-bit counter for 781-cycle interval), initialization sequence counter (15-bit for 200 us wait), burst counter (8-bit burst_remaining), preemption logic, and data routing.
This is larger than the original ~150 LUT async SRAM controller because SDRAM requires initialization, auto-refresh, and explicit row activation/precharge management.
No additional EBR or DSP resources are required.

**PLL resource note:** The SDRAM controller requires a 90-degree phase-shifted 100 MHz clock output from the ECP5 PLL.
The ECP5 EHXPLLL primitive supports up to 4 clock outputs with configurable phase shift.
The existing PLL already uses 3 outputs (clk_core 100 MHz, clk_pixel 25 MHz, clk_tmds 250 MHz).
Adding the SDRAM clock as the 4th output consumes the last available PLL output but requires no additional PLL primitives.
