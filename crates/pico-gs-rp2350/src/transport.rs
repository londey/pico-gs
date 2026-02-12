//! RP2350 SPI transport: implements SpiTransport + FlowControl for rp235x-hal.

use embedded_hal::digital::{InputPin, OutputPin};
use embedded_hal::spi::SpiBus as _;
use pico_gs_hal::{FlowControl, SpiTransport};
use rp235x_hal as hal;

/// SPI transport error for the RP2350 platform.
#[derive(Debug, defmt::Format)]
pub enum TransportError {
    /// SPI bus error during communication.
    SpiBusError,
}

/// Pin type aliases for the GPU interface.
type SpiPins = (
    hal::gpio::Pin<hal::gpio::bank0::Gpio3, hal::gpio::FunctionSpi, hal::gpio::PullDown>,
    hal::gpio::Pin<hal::gpio::bank0::Gpio4, hal::gpio::FunctionSpi, hal::gpio::PullDown>,
    hal::gpio::Pin<hal::gpio::bank0::Gpio2, hal::gpio::FunctionSpi, hal::gpio::PullDown>,
);

pub type SpiBus = hal::spi::Spi<hal::spi::Enabled, hal::pac::SPI0, SpiPins, 8>;
pub type CsPin = hal::gpio::Pin<hal::gpio::bank0::Gpio5, hal::gpio::FunctionSioOutput, hal::gpio::PullDown>;
pub type CmdFullPin = hal::gpio::Pin<hal::gpio::bank0::Gpio6, hal::gpio::FunctionSioInput, hal::gpio::PullDown>;
pub type CmdEmptyPin = hal::gpio::Pin<hal::gpio::bank0::Gpio7, hal::gpio::FunctionSioInput, hal::gpio::PullDown>;
pub type VsyncPin = hal::gpio::Pin<hal::gpio::bank0::Gpio8, hal::gpio::FunctionSioInput, hal::gpio::PullDown>;

/// RP2350 hardware transport for GPU SPI communication.
pub struct Rp2350Transport {
    spi: SpiBus,
    cs: CsPin,
    cmd_full: CmdFullPin,
    cmd_empty: CmdEmptyPin,
    vsync: VsyncPin,
}

impl Rp2350Transport {
    /// Create a new transport from hardware peripherals.
    pub fn new(
        spi: SpiBus,
        cs: CsPin,
        cmd_full: CmdFullPin,
        cmd_empty: CmdEmptyPin,
        vsync: VsyncPin,
    ) -> Self {
        Self {
            spi,
            cs,
            cmd_full,
            cmd_empty,
            vsync,
        }
    }
}

impl SpiTransport for Rp2350Transport {
    type Error = TransportError;

    fn write_register(&mut self, addr: u8, data: u64) -> Result<(), Self::Error> {
        // Flow control: wait for FIFO space.
        while self.cmd_full.is_high().unwrap_or(false) {
            cortex_m::asm::nop();
        }

        // Pack 9-byte SPI transaction: [0|addr(7)] [data(64) MSB-first]
        let buf: [u8; 9] = [
            addr & 0x7F,
            (data >> 56) as u8,
            (data >> 48) as u8,
            (data >> 40) as u8,
            (data >> 32) as u8,
            (data >> 24) as u8,
            (data >> 16) as u8,
            (data >> 8) as u8,
            data as u8,
        ];

        self.cs.set_low().unwrap();
        let _ = self.spi.write(&buf);
        self.cs.set_high().unwrap();

        Ok(())
    }

    fn read_register(&mut self, addr: u8) -> Result<u64, Self::Error> {
        let tx: [u8; 9] = [0x80 | (addr & 0x7F), 0, 0, 0, 0, 0, 0, 0, 0];
        let mut rx: [u8; 9] = [0; 9];

        self.cs.set_low().unwrap();
        let _ = self.spi.transfer(&mut rx, &tx);
        self.cs.set_high().unwrap();

        let mut data: u64 = 0;
        for &byte in &rx[1..9] {
            data = (data << 8) | byte as u64;
        }

        Ok(data)
    }
}

impl FlowControl for Rp2350Transport {
    fn is_cmd_full(&self) -> bool {
        self.cmd_full.is_high().unwrap_or(false)
    }

    fn is_cmd_empty(&self) -> bool {
        self.cmd_empty.is_high().unwrap_or(false)
    }

    fn wait_vsync(&mut self) {
        // Wait for VSYNC to go low (ensure we catch the next edge).
        while self.vsync.is_high().unwrap_or(false) {
            cortex_m::asm::nop();
        }
        // Wait for VSYNC rising edge.
        while self.vsync.is_low().unwrap_or(true) {
            cortex_m::asm::nop();
        }
    }
}
