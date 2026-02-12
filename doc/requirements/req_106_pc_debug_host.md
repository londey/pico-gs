# REQ-106: PC Debug Host

## Classification

- **Priority:** Important
- **Stability:** Draft
- **Verification:** Test

## Requirement

When running on a PC platform connected to the spi_gpu via an Adafruit FT232H breakout board, the system SHALL provide enhanced debugging capabilities including: structured logging of all GPU register writes with timestamps, command-level tracing of the full render pipeline, and terminal-based keyboard input for demo selection. The PC host SHALL use the same GPU driver API (INT-020) and render command types (INT-021) as the RP2350 platform, communicating over SPI via the FT232H adapter conforming to INT-040.

## Rationale

The primary purpose of the PC debug host is to simplify spi_gpu FPGA debugging by providing full visibility into the host-GPU communication protocol. The RP2350's limited logging (defmt over RTT) makes it difficult to diagnose GPU protocol issues, timing problems, or rendering artifacts. A PC host with full logging and tracing capabilities enables rapid iteration during GPU development.

## Parent Requirements

- REQ-100 (Host Firmware Architecture)

## Allocated To

- UNIT-035 (PC SPI Driver)
- UNIT-036 (PC Input Handler)

## Interfaces

- INT-020 (GPU Driver API)
- INT-040 (Host Platform HAL)

## Verification Method

**Test:** Verify that the PC host successfully initializes the FT232H adapter, reads the GPU ID register (expected 0x6702), and produces structured log output. Verify that keyboard input maps to demo selection events. Verify that the same rendering demo (e.g., GouraudTriangle) produces identical GPU register write sequences on both PC and RP2350 platforms.

## Notes

Future enhancements may include: frame capture (recording all register writes per frame to a file), command replay (re-sending captured register write sequences), and a GUI for real-time GPU state visualization. These are not required for the initial implementation.
