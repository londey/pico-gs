# INT-040: Host Platform HAL

## Type

Internal

## Parties

- **Provider:** Platform-specific crates (pico-gs-rp2350, pico-gs-pc)
- **Consumer:** pico-gs-core (GPU driver, command execution)
- **Provider:** UNIT-036 (PC Input Handler)
- **Provider:** UNIT-035 (PC SPI Driver (FT232H))
- **Consumer:** UNIT-022 (GPU Driver Layer)

## Serves Requirement Areas

- Area 12: Target Hardware Devices (HAL abstracts target hardware differences)

## Referenced By

- REQ-103 (USB Keyboard Input) — Area 9: Keyboard and Controller Input
- REQ-105 (GPU Communication Protocol) — Area 1: GPU SPI Controller
- REQ-106 (PC Debug Host) — Area 10: GPU Debug GUI

Note: REQ-100 (Host Firmware Architecture) is retired; its reference has been removed.

## Specification

**Version**: 1.0
**Date**: 2026-02-12

---

## Overview

The Host Platform HAL defines the trait boundary between platform-agnostic GPU driver/rendering code (pico-gs-core) and platform-specific hardware access (pico-gs-rp2350, pico-gs-pc). It abstracts SPI communication, GPIO flow control, and user input behind traits that each platform implements.

---

## SPI Transport Trait

### `trait SpiTransport`

Abstracts the 9-byte GPU register protocol over any SPI implementation.

```rust
pub trait SpiTransport {
    type Error: core::fmt::Debug;

    /// Write a 64-bit value to a GPU register.
    /// Implementations MUST handle flow control (poll CMD_FULL before write).
    fn write_register(&mut self, addr: u8, data: u64) -> Result<(), Self::Error>;

    /// Read a 64-bit value from a GPU register.
    fn read_register(&mut self, addr: u8) -> Result<u64, Self::Error>;
}
```

**Contract:**
- `write_register` blocks until the GPU command FIFO has space (CMD_FULL deasserted), then sends a 9-byte SPI transaction: `[addr & 0x7F, data[63:56], ..., data[7:0]]`
- `read_register` sends a 9-byte SPI transaction: `[0x80 | (addr & 0x7F), 0, ..., 0]` and reconstructs the 64-bit response from bytes 1..8
- Both methods toggle chip-select (CS low before, CS high after)
- Error type is platform-specific (SPI bus errors, USB/FTDI errors)

### Platform Implementations

| Platform | SPI Hardware | Crate | Flow Control |
|----------|-------------|-------|--------------|
| RP2350 | SPI0 at 25 MHz via rp235x-hal | pico-gs-rp2350 | GPIO6 (CMD_FULL), GPIO7 (CMD_EMPTY) |
| PC | FT232H via ftdi crate | pico-gs-pc | FT232H GPIO pins (directly read) |

---

## GPIO Input Trait

### `trait FlowControl`

Abstracts GPU status GPIO signals.

```rust
pub trait FlowControl {
    /// Returns true if GPU command FIFO is almost full.
    fn is_cmd_full(&self) -> bool;

    /// Returns true if GPU command FIFO is empty.
    fn is_cmd_empty(&self) -> bool;

    /// Block until VSYNC rising edge is detected.
    fn wait_vsync(&mut self);
}
```

**Note:** `FlowControl` may be bundled into `SpiTransport` if implementations prefer (the RP2350 version polls CMD_FULL inside `write_register`). It is separated here for implementations that want independent access to flow control signals.

---

## DMA Memory Copy Trait

### `trait DmaMemcpy`

Abstracts asynchronous copy from flash (XIP) to SRAM. Used by Core 1 for double-buffered mesh patch prefetch.

```rust
pub trait DmaMemcpy {
    fn start_copy(&mut self, src: *const u8, dst: *mut u8, len: usize);
    fn is_complete(&self) -> bool;
    fn wait_complete(&self);
}
```

| Platform | Hardware | Notes |
|----------|----------|-------|
| RP2350 | DMA channel | True async DMA from XIP flash to SRAM |
| PC | memcpy | Synchronous; is_complete always returns true |

---

## Buffered SPI Output Trait

### `trait BufferedSpiTransport`

Abstracts double-buffered SPI output for DMA/PIO-driven GPU register writes.

```rust
pub trait BufferedSpiTransport {
    type Error: core::fmt::Debug;
    fn submit_buffer(&mut self, buffer: &[u8], len: usize) -> Result<(), Self::Error>;
    fn is_send_complete(&self) -> bool;
    fn wait_send_complete(&self);
}
```

| Platform | Hardware | Notes |
|----------|----------|-------|
| RP2350 (ideal) | PIO + DMA | PIO handles CS toggle and 9-byte framing |
| RP2350 (fallback) | DMA-chained SPI | Per-frame CS, software CMD_FULL check |
| PC | SPI thread | Thread reads ring buffer, sends via FT232H |

---

## Input Source Trait

### `trait InputSource`

Abstracts user input across platforms.

```rust
pub trait InputSource {
    /// Initialize the input subsystem.
    fn init(&mut self);

    /// Poll for input events. Non-blocking.
    fn poll(&mut self) -> Option<InputEvent>;
}

pub enum InputEvent {
    SelectDemo(Demo),
}
```

### Platform Implementations

| Platform | Input Method | Notes |
|----------|-------------|-------|
| RP2350 | TinyUSB HID keyboard | Feature-gated behind `usb-host` |
| PC | Terminal keyboard (crossterm) or GUI | Direct stdin or event loop |

---

## Logging Abstraction

No trait needed — each platform uses its native logging:

| Platform | Logging | Details |
|----------|---------|---------|
| RP2350 | `defmt` over RTT | Lightweight structured logging |
| PC | `tracing` or `log` + `env_logger` | Full structured logging with file output, filtering |

PC-specific debug features (frame capture, command replay) are implemented directly in pico-gs-pc and are not part of the shared HAL.

---

## Constraints

- All trait methods must be callable from `no_std` contexts (no `std::io`, no `String`)
- Traits use associated error types for platform-specific error handling
- `SpiTransport` and `FlowControl` are `!Send` (owned by a single execution context)

## Notes

The GPU driver in pico-gs-core is generic over `SpiTransport`:
```rust
pub struct GpuDriver<S: SpiTransport> {
    spi: S,
    draw_fb: u32,
    display_fb: u32,
}
```
This replaces the current `GpuHandle` which owns rp235x-hal types directly.
