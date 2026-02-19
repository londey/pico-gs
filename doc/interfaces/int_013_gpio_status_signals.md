# INT-013: GPIO Status Signals

## Type

External Standard

## External Specification

- **Standard:** GPIO Status Signals
- **Reference:** GPIO signals for flow control (CMD_FULL, CMD_EMPTY, VSYNC).

## Serves Requirement Areas

- Area 12: Target Hardware Devices (GPIO status signals are a target hardware interface)

## Parties

- **Provider:** External
- **Consumer:** UNIT-020 (Core 0 Scene Manager), Host firmware
- **Consumer:** UNIT-022 (GPU Driver Layer)
- **Consumer:** UNIT-035 (PC SPI Driver (FT232H))

## Referenced By

- REQ-001.04 (Command Buffer FIFO) — Area 1: GPU SPI Controller
- REQ-011.03 (Reliability Requirements) — Area 11: System Constraints
- REQ-013.03 (VSync Synchronization) — Area 6: Screen Scan Out
- REQ-001.06 (GPU Flow Control) — Area 1: GPU SPI Controller

## Specification

### Overview

This project uses a subset of the GPIO Status Signals standard.

### Usage

GPIO signals for flow control (CMD_FULL, CMD_EMPTY, VSYNC).

## Constraints

See external specification for full details.

## Notes

This is an external standard. Refer to the official specification for complete details.
