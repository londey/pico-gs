# UNIT-035: PC SPI Driver (FT232H)

## Parent Area

10. GPU Debug GUI (Pico Software)

## Purpose

SPI transport implementation for PC platform via Adafruit FT232H breakout board

## Implements Requirements

- REQ-013.01 (GPU Communication Protocol) — parent area 1 (GPU SPI Controller)
- REQ-010.01 (PC Debug Host) — parent area 10 (GPU Debug GUI)
- ~~REQ-100 (Host Firmware Architecture)~~ — retired (premature for single-threaded approach)
- REQ-013 (Host SPI Driver)
- REQ-010 (GPU Debug GUI)

## Interfaces

### Provides

- INT-040 (Host Platform HAL) -- `SpiTransport` and `FlowControl` implementations

### Consumes

- INT-001 (SPI Mode 0 Protocol)
- INT-012 (SPI Transaction Format)
- INT-013 (GPIO Status Signals)

### Internal Interfaces

- **UNIT-022 (GPU Driver Layer)**: `GpuDriver<Ft232hTransport>` uses this transport for all GPU communication on the PC platform.

## Design Description

### Inputs

- FT232H USB device (via `ftdi` or `libftdi` crate)
- SPI configuration: Mode 0, MSB first, clock speed configurable (default 25 MHz, adjustable for debugging)

### Outputs

- `SpiTransport` trait implementation for FT232H
- Structured log output for every SPI transaction (address, data, direction, timestamp)

### Internal State

- **`Ft232hTransport`** struct:
  - `device: ftdi::Device` -- FT232H USB device handle
  - `log_enabled: bool` -- enable per-transaction logging
  - `transaction_count: u64` -- running counter for debug correlation

### Algorithm / Behavior

1. **Initialization**: Open FT232H USB device, configure MPSSE mode for SPI Mode 0, set clock divisor, configure GPIO pins for CS, CMD_FULL, CMD_EMPTY, VSYNC.
2. **write_register()**: Log transaction, poll CMD_FULL GPIO, assert CS, send 9 bytes via MPSSE SPI write, deassert CS.
3. **read_register()**: Log transaction, assert CS, send 9 bytes via MPSSE SPI transfer (full-duplex), deassert CS, reconstruct u64.
4. **wait_vsync()**: Poll VSYNC GPIO for rising edge (with configurable timeout for PC environments).
5. **Logging**: Every SPI transaction is logged with: timestamp, direction (R/W), register name (resolved from address), data value, transaction number.

### SPI Clock Speed

The FT232H supports SPI clocks up to 30 MHz. Default is 25 MHz (matching RP2350). For debugging, slower speeds (1-10 MHz) can be used to reduce timing sensitivity.

## Implementation

- `crates/pico-gs-pc/src/transport.rs`: FT232H SPI transport and GPIO flow control

## Verification

- **Loopback test**: Verify SPI MOSI/MISO loopback produces expected data
- **GPU ID read**: Verify GPU ID register returns 0x6702 when connected to spi_gpu hardware
- **Transaction logging**: Verify every write/read produces a structured log entry with correct fields
- **Flow control**: Verify CMD_FULL polling prevents writes when GPU FIFO is full

## Design Notes

FT232H pin mapping must match the iCEBreaker/ECP5 SPI connection.
The exact GPIO pin assignments for CS, CMD_FULL, CMD_EMPTY, and VSYNC depend on the physical wiring and should be configurable via command-line arguments or config file.

**Distinction from Verilator interactive simulator:** This unit drives real FPGA hardware over the FT232H USB-SPI bridge.
The Verilator interactive simulator (REQ-010.02) is a separate, parallel PC-side tool that drives the Verilator GPU RTL model via direct C++ FIFO injection without using FT232H hardware or the `SpiTransport` / `FlowControl` traits this unit provides.
The two tools are complementary: this unit is used with physical FPGA hardware; the simulator requires no hardware.
