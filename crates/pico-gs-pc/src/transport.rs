// Spec-ref: unit_035_pc_spi_driver.md `6ee2a1d14eeb9355` 2026-02-12
//! FT232H SPI transport for PC debug host (stub).
//!
//! This module will implement SpiTransport + FlowControl using an FT232H
//! USB-to-SPI adapter in MPSSE mode. Currently contains stub implementations
//! with todo!() markers for the actual hardware integration.

use pico_gs_hal::{FlowControl, SpiTransport};

/// FT232H transport error types.
#[derive(Debug)]
pub enum Ft232hError {
    /// FT232H device not found on USB bus.
    DeviceNotFound,
    /// USB communication error.
    UsbError,
    /// SPI protocol error.
    SpiError,
}

/// FT232H SPI transport for GPU communication.
pub struct Ft232hTransport {
    // TODO: ftdi::Device field
    log_enabled: bool,
    transaction_count: u64,
}

impl Ft232hTransport {
    /// Open FT232H device and configure MPSSE mode for SPI.
    pub fn new() -> Result<Self, Ft232hError> {
        // TODO: Open FT232H device, configure MPSSE mode for SPI
        // - Find FT232H by VID/PID
        // - Set MPSSE mode
        // - Configure SPI clock rate (25 MHz target, may need lower)
        // - Configure GPIO pins for CS, CMD_FULL, CMD_EMPTY, VSYNC
        todo!("FT232H initialization requires ftdi crate and hardware")
    }
}

impl SpiTransport for Ft232hTransport {
    type Error = Ft232hError;

    fn write_register(&mut self, addr: u8, data: u64) -> Result<(), Self::Error> {
        // TODO: MPSSE SPI write with flow control
        // 1. Poll CMD_FULL GPIO until deasserted
        // 2. Assert CS (GPIO low)
        // 3. Send 9 bytes: [addr & 0x7F, data MSB-first]
        // 4. Deassert CS (GPIO high)
        let _ = (addr, data);
        todo!("FT232H SPI write_register")
    }

    fn read_register(&mut self, addr: u8) -> Result<u64, Self::Error> {
        // TODO: MPSSE SPI transfer (simultaneous write/read)
        // 1. Assert CS
        // 2. Send [0x80 | (addr & 0x7F), 0, 0, 0, 0, 0, 0, 0, 0]
        // 3. Read 9 bytes response
        // 4. Deassert CS
        // 5. Reconstruct u64 from bytes 1..8
        let _ = addr;
        todo!("FT232H SPI read_register")
    }
}

impl FlowControl for Ft232hTransport {
    fn is_cmd_full(&mut self) -> bool {
        // TODO: Read FT232H GPIO pin for CMD_FULL signal
        todo!("FT232H GPIO read CMD_FULL")
    }

    fn is_cmd_empty(&mut self) -> bool {
        // TODO: Read FT232H GPIO pin for CMD_EMPTY signal
        todo!("FT232H GPIO read CMD_EMPTY")
    }

    fn wait_vsync(&mut self) {
        // TODO: Poll FT232H GPIO pin for VSYNC edge
        // 1. Wait for VSYNC low (ensure we catch next edge)
        // 2. Wait for VSYNC high (rising edge)
        todo!("FT232H GPIO poll VSYNC")
    }
}
