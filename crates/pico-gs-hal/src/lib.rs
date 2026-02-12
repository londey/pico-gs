#![no_std]

/// Abstracts the 9-byte GPU register protocol over any SPI implementation.
///
/// Implementations handle CS toggling and flow control (CMD_FULL polling)
/// internally. See INT-040 for the full contract.
pub trait SpiTransport {
    type Error: core::fmt::Debug;

    /// Write a 64-bit value to a GPU register.
    /// Implementations MUST handle flow control (poll CMD_FULL before write).
    fn write_register(&mut self, addr: u8, data: u64) -> Result<(), Self::Error>;

    /// Read a 64-bit value from a GPU register.
    fn read_register(&mut self, addr: u8) -> Result<u64, Self::Error>;
}

/// Abstracts GPU status GPIO signals.
///
/// May be bundled into `SpiTransport` implementations or used independently.
pub trait FlowControl {
    /// Returns true if GPU command FIFO is almost full.
    fn is_cmd_full(&self) -> bool;

    /// Returns true if GPU command FIFO is empty.
    fn is_cmd_empty(&self) -> bool;

    /// Block until VSYNC rising edge is detected.
    fn wait_vsync(&mut self);
}

/// Abstracts user input across platforms.
pub trait InputSource {
    /// Initialize the input subsystem.
    fn init(&mut self);

    /// Poll for input events. Non-blocking.
    fn poll(&mut self) -> Option<InputEvent>;
}

/// Platform-agnostic input events.
///
/// Uses `u8` demo index rather than importing the `Demo` enum from pico-gs-core
/// to avoid a circular dependency (core depends on hal).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputEvent {
    /// Select a demo scene by index (0, 1, 2, ...).
    SelectDemo(u8),
}
