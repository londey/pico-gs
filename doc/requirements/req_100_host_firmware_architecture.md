# REQ-100: Host Firmware Architecture

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement a dual-core firmware architecture on the RP2350 microcontroller where Core 0 is responsible for scene management, USB keyboard input polling, and render command generation, and Core 1 is responsible for render command execution and GPU communication via SPI. The two cores SHALL communicate through a lock-free single-producer single-consumer (SPSC) command queue with backpressure, where Core 0 is the producer and Core 1 is the consumer.

## Rationale

Separating scene logic from GPU communication across the two Cortex-M33 cores allows the CPU-intensive transform and lighting computations on Core 0 to overlap with the I/O-bound SPI transmission on Core 1, maximizing throughput and maintaining a stable frame rate.

## Parent Requirements

None

## Allocated To

- UNIT-020 (Core 0 Scene Manager)
- UNIT-021 (Core 1 Render Executor)
- UNIT-022 (GPU Driver Layer)

## Interfaces

- INT-020 (GPU Driver API)

## Verification Method

**Test:** Verify that Core 0 produces render commands into the SPSC queue and Core 1 consumes and executes them against the GPU driver, with correct backpressure behavior when the queue is full.

## Notes

Core 0 initializes all hardware peripherals (clocks, SPI, GPIO), creates the GPU handle, splits the SPSC queue, and spawns Core 1 before entering its main loop. Core 1 receives ownership of the GPU handle and consumer queue end at spawn time. The command queue capacity is 64 entries (~5 KB SRAM).
