# REQ-011: System Constraints

## Requirement

The system SHALL run on an ICEpi Zero (ECP5-25K FPGA), meeting cross-cutting performance targets, FPGA resource budgets, and reliability requirements that apply across all GPU subsystems.

## Rationale

The system constraints area groups non-functional requirements and platform constraints that span multiple GPU subsystems.
The GPU must fit within the resource and performance envelope of the ECP5-25K FPGA on the ICEpi Zero board.
Host application resource constraints (RP2350 SRAM, Flash, USB stack sizing) are defined in the pico-racer repository (https://github.com/londey/pico-racer).

## Parent Requirements

None (top-level area)

## Sub-Requirements

- REQ-011.01 (Performance Targets)
- REQ-011.02 (Resource Constraints)
- REQ-011.03 (Reliability Requirements)
