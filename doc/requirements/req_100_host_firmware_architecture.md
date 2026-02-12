# REQ-100: Host Firmware Architecture

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement a multi-platform host architecture where platform-agnostic rendering logic (scene management, geometry transformation, lighting, render command generation) is shared across host platforms via a common core library, and platform-specific concerns (SPI transport, GPIO access, user input, application threading) are isolated behind hardware abstraction traits defined in INT-040.

When running on the RP2350 platform, the system SHALL use a dual-core architecture where Core 0 handles scene management and render command generation, and Core 1 handles render command execution and GPU communication via SPI, with a lock-free SPSC command queue providing inter-core communication with backpressure.

When running on the PC platform, the system SHALL use a single-threaded architecture where scene management, render command generation, and GPU communication (via FT232H SPI adapter) execute sequentially, with enhanced debug capabilities including structured logging and command tracing.

## Rationale

Separating platform-agnostic rendering logic from platform-specific hardware access enables the same GPU driver and rendering code to run on both the RP2350 embedded target and a PC connected via FT232H SPI adapter. The PC platform provides full logging, frame capture, and command replay capabilities essential for debugging the spi_gpu FPGA, while the RP2350 platform optimizes for real-time performance via dual-core pipelining.

## Parent Requirements

None

## Allocated To

- UNIT-020 (Core 0 Scene Manager)
- UNIT-021 (Core 1 Render Executor)
- UNIT-022 (GPU Driver Layer)
- UNIT-035 (PC SPI Driver)

## Interfaces

- INT-020 (GPU Driver API)
- INT-040 (Host Platform HAL)

## Verification Method

**Test (RP2350):** Verify that Core 0 produces render commands into the SPSC queue and Core 1 consumes and executes them against the GPU driver, with correct backpressure behavior when the queue is full.

**Test (PC):** Verify that the PC host initializes the FT232H SPI adapter, communicates with the GPU via the same driver API, and produces structured log output for each GPU register write.

## Notes

The shared core library (pico-gs-core) contains: GPU register protocol, render command types, scene state machine, transformation pipeline, lighting calculator, and demo state machine. Platform-specific crates contain: SPI transport implementation, GPIO access, input handling, application entry point, and threading/orchestration.

The RP2350 platform uses a 64-entry SPSC queue (~5 KB SRAM) for inter-core communication. The PC platform executes commands synchronously (no queue needed).
