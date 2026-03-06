# REQ-010: GPU Interactive Simulator

## Classification

- **Priority:** Important
- **Stability:** Draft
- **Verification:** Inspection

## Requirement

When GPU RTL development or debugging requires exercising the hardware without an RP2350 or physical SPI host, the system SHALL provide a Verilator-based interactive simulator that accepts register-write command scripts and renders frames using the simulated GPU pipeline.

## Rationale

The interactive simulator enables GPU RTL development and verification without requiring physical hardware.
It drives the GPU model via the same 72-bit register-write protocol defined in INT-010, exercising the same code paths as real SPI traffic.

## Parent Requirements

None (top-level area)

## Notes

REQ-010.01 (PC Debug Host) and its implementation units (UNIT-035, UNIT-036) have moved to the pico-racer repository (https://github.com/londey/pico-racer), which provides the host application that drives the GPU over SPI from a PC via FT232H.
