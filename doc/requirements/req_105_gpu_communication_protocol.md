# REQ-105: GPU Communication Protocol

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement SPI-based communication with the GPU using a 9-byte transaction format where the first byte encodes the register address (bit 7 = read/write flag, bits 6:0 = 7-bit register address) and the remaining 8 bytes carry a 64-bit data payload in MSB-first order. Register writes SHALL block until the GPU command FIFO has space, as indicated by the CMD_FULL GPIO input being deasserted. The system SHALL support register read, register write, bulk memory upload via MEM_ADDR/MEM_DATA auto-increment, triangle submission via sequential COLOR/UV0/VERTEX register writes, vsync synchronization via VSYNC GPIO edge detection, and double-buffered framebuffer swap via FB_DRAW/FB_DISPLAY register updates.

## Rationale

The SPI register interface is the sole communication channel between the host MCU and the FPGA-based GPU. Correct framing, flow control, and register sequencing are critical to reliable rendering.

## Parent Requirements

None

## Allocated To

- UNIT-022 (GPU Driver Layer)

## Interfaces

- INT-010 (GPU Register Map)
- INT-012 (SPI Transaction Format)
- INT-020 (GPU Driver API)

## Verification Method

**Test:** Verify that register writes produce correctly framed 9-byte SPI transactions with the write flag clear (bit 7 = 0) and register reads set bit 7 = 1. Verify that write operations block when CMD_FULL is asserted. Verify GPU initialization reads the ID register and rejects unexpected device IDs. Verify that framebuffer swap alternates draw and display addresses correctly.

## Notes

The GPU driver owns all SPI and GPIO resources (SPI0 bus, CS on GPIO5, CMD_FULL on GPIO6, CMD_EMPTY on GPIO7, VSYNC on GPIO8). SPI runs at 25 MHz in Mode 0. CS is manually toggled per transaction. GPU identity is verified at startup by reading the ID register (expected device ID 0x6702).
