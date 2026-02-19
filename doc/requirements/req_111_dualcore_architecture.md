# REQ-111: Dual-Core Architecture

## Classification

- **Priority:** Essential
- **Stability:** Retired
- **Verification:** Test

## Requirement

When running on the RP2350 platform, the system SHALL implement dual-core architecture where Core 0 manages scene state and performs spatial culling to generate mesh patch render commands, and Core 1 consumes mesh patch commands, performs vertex transformation and lighting, and drives the GPU via a DMA-pipelined SPI output, as specified in REQ-100.

## Rationale

This requirement defines the functional behavior of the dual-core architecture subsystem on the RP2350 platform. Separating scene logic from GPU communication across the two Cortex-M33 cores allows overlap between CPU-intensive transforms and I/O-bound SPI transmission.

## Parent Requirements

- REQ-100 (Host Firmware Architecture)

## Allocated To

- UNIT-020 (Core 0 Scene Manager)
- UNIT-021 (Core 1 Render Executor)

## Interfaces

- INT-021 (Render Command Format)

## Verification Method

**Test:** Verify that Core 0 produces render commands and Core 1 consumes them, with correct SPSC queue backpressure behavior.

## Retirement Note

**Retired:** This requirement is premature for the current single-threaded approach.
The Core 0 / Core 1 split with DMA-pipelined SPI output described here was never implemented.
The system currently uses a single-threaded execution model on all platforms; the PC platform has always been single-threaded, and the RP2350 port has not yet adopted dual-core execution.
This requirement's parent, REQ-100, has also been retired.
If dual-core execution is adopted in the future, a new requirement should be drafted reflecting the actual implementation.

## Notes

The dual-core architecture is specific to the RP2350 platform. The PC platform uses a single-threaded execution model where scene management and GPU communication execute sequentially. See REQ-100 for the multi-platform architecture overview.
