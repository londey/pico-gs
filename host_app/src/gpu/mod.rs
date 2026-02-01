//! GPU SPI driver: initialization, register access, flow control.

pub mod registers;
pub mod vertex;

use embedded_hal::digital::{InputPin, OutputPin};
use embedded_hal::spi::SpiBus as _;
use rp235x_hal as hal;

/// Error type for GPU driver operations.
#[derive(Debug, defmt::Format)]
pub enum GpuError {
    /// GPU not detected: ID register returned unexpected value.
    GpuNotDetected,
    /// SPI bus error during communication.
    SpiBusError,
}

/// Pin type aliases for the GPU interface.
type SpiPins = (
    hal::gpio::Pin<hal::gpio::bank0::Gpio3, hal::gpio::FunctionSpi, hal::gpio::PullDown>,
    hal::gpio::Pin<hal::gpio::bank0::Gpio4, hal::gpio::FunctionSpi, hal::gpio::PullDown>,
    hal::gpio::Pin<hal::gpio::bank0::Gpio2, hal::gpio::FunctionSpi, hal::gpio::PullDown>,
);

type SpiBus = hal::spi::Spi<hal::spi::Enabled, hal::pac::SPI0, SpiPins, 8>;
type CsPin = hal::gpio::Pin<hal::gpio::bank0::Gpio5, hal::gpio::FunctionSioOutput, hal::gpio::PullDown>;
type CmdFullPin = hal::gpio::Pin<hal::gpio::bank0::Gpio6, hal::gpio::FunctionSioInput, hal::gpio::PullDown>;
type CmdEmptyPin = hal::gpio::Pin<hal::gpio::bank0::Gpio7, hal::gpio::FunctionSioInput, hal::gpio::PullDown>;
type VsyncPin = hal::gpio::Pin<hal::gpio::bank0::Gpio8, hal::gpio::FunctionSioInput, hal::gpio::PullDown>;

/// Opaque handle to the GPU hardware. Owns all SPI and GPIO resources.
pub struct GpuHandle {
    spi: SpiBus,
    cs: CsPin,
    cmd_full: CmdFullPin,
    cmd_empty: CmdEmptyPin,
    vsync: VsyncPin,
    /// Current draw framebuffer address.
    draw_fb: u32,
    /// Current display framebuffer address.
    display_fb: u32,
}

/// Initialize the GPU driver. Verifies GPU presence by reading the ID register.
pub fn gpu_init(
    spi: SpiBus,
    cs: CsPin,
    cmd_full: CmdFullPin,
    cmd_empty: CmdEmptyPin,
    vsync: VsyncPin,
) -> Result<GpuHandle, GpuError> {
    let mut handle = GpuHandle {
        spi,
        cs,
        cmd_full,
        cmd_empty,
        vsync,
        draw_fb: registers::FB_A_ADDR,
        display_fb: registers::FB_B_ADDR,
    };

    // Read GPU ID register and verify v2.0 device.
    let id = handle.read(registers::ID);
    let device_id = (id & 0xFFFF) as u16;
    if device_id != registers::EXPECTED_DEVICE_ID {
        defmt::error!("GPU ID mismatch: expected 0x{:04X}, got 0x{:04X}", registers::EXPECTED_DEVICE_ID, device_id);
        return Err(GpuError::GpuNotDetected);
    }

    // Configure initial framebuffer addresses.
    handle.write(registers::FB_DRAW, registers::FB_A_ADDR as u64);
    handle.write(registers::FB_DISPLAY, registers::FB_B_ADDR as u64);

    Ok(handle)
}

impl GpuHandle {
    /// Write a 64-bit value to a GPU register. Blocks until CMD_FULL is deasserted.
    pub fn write(&mut self, addr: u8, data: u64) {
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
    }

    /// Read a 64-bit value from a GPU register.
    pub fn read(&mut self, addr: u8) -> u64 {
        let tx: [u8; 9] = [0x80 | (addr & 0x7F), 0, 0, 0, 0, 0, 0, 0, 0];
        let mut rx: [u8; 9] = [0; 9];

        self.cs.set_low().unwrap();
        let _ = self.spi.transfer(&mut rx, &tx);
        self.cs.set_high().unwrap();

        let mut data: u64 = 0;
        for &byte in &rx[1..9] {
            data = (data << 8) | byte as u64;
        }
        data
    }

    /// Check if the GPU command FIFO is almost full.
    pub fn is_fifo_full(&mut self) -> bool {
        self.cmd_full.is_high().unwrap_or(false)
    }

    /// Check if the GPU command FIFO is empty.
    pub fn is_fifo_empty(&mut self) -> bool {
        self.cmd_empty.is_high().unwrap_or(false)
    }

    /// Block until VSYNC rising edge.
    pub fn wait_vsync(&mut self) {
        // Wait for VSYNC to go low (ensure we catch the next edge).
        while self.vsync.is_high().unwrap_or(false) {
            cortex_m::asm::nop();
        }
        // Wait for VSYNC rising edge.
        while self.vsync.is_low().unwrap_or(true) {
            cortex_m::asm::nop();
        }
    }

    /// Swap draw and display framebuffers.
    pub fn swap_buffers(&mut self) {
        core::mem::swap(&mut self.draw_fb, &mut self.display_fb);
        self.write(registers::FB_DISPLAY, self.display_fb as u64);
        self.write(registers::FB_DRAW, self.draw_fb as u64);
    }

    /// Upload a block of 32-bit words to GPU SRAM via MEM_ADDR/MEM_DATA.
    ///
    /// Current implementation: blocking register writes.
    ///
    /// ## DMA Optimization Strategy (T044/T047)
    ///
    /// For async GPU communication, the ideal approach is:
    /// 1. **Flash → SRAM pre-fetch (T044)**: Use RP2350 DMA channel to copy
    ///    texture/mesh data from flash (XIP) to an SRAM working buffer. The
    ///    RP2350 DMA controller can read from XIP address space (0x1000_0000+)
    ///    and write to SRAM (0x2000_0000+). Double-buffer the working buffers
    ///    so one is being filled while the other is being transmitted.
    /// 2. **SRAM → SPI DMA (T047)**: Configure a DMA channel to feed the SPI
    ///    TX FIFO from the SRAM buffer. Challenges:
    ///    - Each GPU command is 9 bytes with manual CS toggle between commands.
    ///    - CMD_FULL flow control requires GPIO polling between commands.
    ///    - Could batch multiple register writes into a contiguous buffer with
    ///      CS handled via PIO instead of GPIO for precise timing.
    ///    - Feasibility depends on whether CMD_FULL can be checked reliably
    ///      between DMA transfers (likely needs PIO or interrupt-driven CS).
    ///
    /// **Conclusion**: Flash → SRAM DMA is straightforward and should be
    /// implemented for texture uploads (4K+ words). Async SPI is complex due
    /// to per-command CS toggling and flow control; recommend PIO-based SPI
    /// as a future enhancement rather than DMA-to-SPI.
    pub fn upload_memory(&mut self, gpu_addr: u32, data: &[u32]) {
        self.write(registers::MEM_ADDR, gpu_addr as u64);
        for &word in data {
            self.write(registers::MEM_DATA, word as u64);
        }
    }

    /// Submit a single triangle (3 vertices) to the GPU.
    pub fn submit_triangle(
        &mut self,
        v0: &vertex::GpuVertex,
        v1: &vertex::GpuVertex,
        v2: &vertex::GpuVertex,
        textured: bool,
    ) {
        self.write(registers::COLOR, v0.color_packed);
        if textured {
            self.write(registers::UV0, v0.uv_packed);
        }
        self.write(registers::VERTEX, v0.position_packed);

        self.write(registers::COLOR, v1.color_packed);
        if textured {
            self.write(registers::UV0, v1.uv_packed);
        }
        self.write(registers::VERTEX, v1.position_packed);

        self.write(registers::COLOR, v2.color_packed);
        if textured {
            self.write(registers::UV0, v2.uv_packed);
        }
        self.write(registers::VERTEX, v2.position_packed);
    }
}
