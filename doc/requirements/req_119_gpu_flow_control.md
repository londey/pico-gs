# REQ-119: GPU Flow Control

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

When the GPU command FIFO is full, the system SHALL de-assert the ready signal on the GPIO status line (INT-013), and the host driver SHALL pause SPI command transmission and poll the ready signal until the GPU re-asserts it before resuming transmission.

## Rationale

The GPU's internal command FIFO has finite depth.
Without flow control, the host can overrun the FIFO, causing command loss, rendering corruption, or undefined GPU behavior.
A hardware-level ready/busy signal allows the host to stall at minimal latency without requiring round-trip register reads over SPI.

## Parent Requirements

- REQ-TBD-TARGET-HARDWARE (Target Hardware Devices)

## Allocated To

- UNIT-022 (GPU Driver Layer)

## Interfaces

- INT-020 (GPU Driver API)
- INT-013 (GPIO Status Signals)

## Verification Method

**Test:** Fill the GPU command FIFO to capacity and verify the ready signal is de-asserted.
Verify that the host halts SPI transmission while the ready signal is de-asserted.
Drain sufficient commands from the FIFO, verify the ready signal is re-asserted, and confirm the host resumes transmission without dropped commands.

## Notes

The GPIO pin used for the ready/busy signal is defined in INT-013 (GPIO Status Signals).
The flow control signal is an active-low output from the GPU to the host (pi_nirq in the ICEpi Zero pinout).
