//! Platform-agnostic GPU driver, generic over SpiTransport.
//!
//! Replaces the RP2350-specific `GpuHandle` with `GpuDriver<S>` that delegates
//! all SPI and flow control to the transport implementation.

use pico_gs_hal::{FlowControl, SpiTransport};

use super::registers;
use super::vertex::GpuVertex;

/// Error type for GPU driver operations, generic over transport errors.
#[derive(Debug)]
pub enum GpuError<E: core::fmt::Debug> {
    /// GPU not detected: ID register returned unexpected value.
    GpuNotDetected,
    /// SPI transport error.
    Transport(E),
}

impl<E: core::fmt::Debug> From<E> for GpuError<E> {
    fn from(e: E) -> Self {
        GpuError::Transport(e)
    }
}

/// Platform-agnostic GPU driver. Owns a transport that implements SPI
/// communication with the GPU hardware.
pub struct GpuDriver<S: SpiTransport> {
    spi: S,
    /// Current draw framebuffer address.
    draw_fb: u32,
    /// Current display framebuffer address.
    display_fb: u32,
}

impl<S: SpiTransport> GpuDriver<S> {
    /// Initialize the GPU driver. Verifies GPU presence by reading the ID register,
    /// then configures initial framebuffer addresses.
    pub fn new(spi: S) -> Result<Self, GpuError<S::Error>> {
        let mut driver = Self {
            spi,
            draw_fb: registers::FB_A_ADDR,
            display_fb: registers::FB_B_ADDR,
        };

        // Read GPU ID register and verify v2.0 device.
        let id = driver.read(registers::ID)?;
        let device_id = (id & 0xFFFF) as u16;
        if device_id != registers::EXPECTED_DEVICE_ID {
            return Err(GpuError::GpuNotDetected);
        }

        // Configure initial framebuffer addresses.
        driver.write(registers::FB_DRAW, registers::FB_A_ADDR as u64)?;
        driver.write(registers::FB_DISPLAY, registers::FB_B_ADDR as u64)?;

        Ok(driver)
    }

    /// Write a 64-bit value to a GPU register.
    pub fn write(&mut self, addr: u8, data: u64) -> Result<(), GpuError<S::Error>> {
        self.spi.write_register(addr, data)?;
        Ok(())
    }

    /// Read a 64-bit value from a GPU register.
    pub fn read(&mut self, addr: u8) -> Result<u64, GpuError<S::Error>> {
        let val = self.spi.read_register(addr)?;
        Ok(val)
    }

    /// Upload a block of 32-bit words to GPU SRAM via MEM_ADDR/MEM_DATA.
    pub fn upload_memory(&mut self, gpu_addr: u32, data: &[u32]) -> Result<(), GpuError<S::Error>> {
        self.write(registers::MEM_ADDR, gpu_addr as u64)?;
        for &word in data {
            self.write(registers::MEM_DATA, word as u64)?;
        }
        Ok(())
    }

    /// Submit a single triangle (3 vertices) to the GPU.
    pub fn submit_triangle(
        &mut self,
        v0: &GpuVertex,
        v1: &GpuVertex,
        v2: &GpuVertex,
        textured: bool,
    ) -> Result<(), GpuError<S::Error>> {
        self.write(registers::COLOR, v0.color_packed)?;
        if textured {
            self.write(registers::UV0, v0.uv_packed)?;
        }
        self.write(registers::VERTEX, v0.position_packed)?;

        self.write(registers::COLOR, v1.color_packed)?;
        if textured {
            self.write(registers::UV0, v1.uv_packed)?;
        }
        self.write(registers::VERTEX, v1.position_packed)?;

        self.write(registers::COLOR, v2.color_packed)?;
        if textured {
            self.write(registers::UV0, v2.uv_packed)?;
        }
        self.write(registers::VERTEX, v2.position_packed)?;

        Ok(())
    }

    /// Swap draw and display framebuffers.
    pub fn swap_buffers(&mut self) -> Result<(), GpuError<S::Error>> {
        core::mem::swap(&mut self.draw_fb, &mut self.display_fb);
        self.write(registers::FB_DISPLAY, self.display_fb as u64)?;
        self.write(registers::FB_DRAW, self.draw_fb as u64)?;
        Ok(())
    }

    /// Get the current draw framebuffer address.
    pub fn draw_fb(&self) -> u32 {
        self.draw_fb
    }

    /// Get the current display framebuffer address.
    pub fn display_fb(&self) -> u32 {
        self.display_fb
    }
}

/// Methods available when the transport also implements FlowControl.
impl<S: SpiTransport + FlowControl> GpuDriver<S> {
    /// Block until VSYNC rising edge.
    pub fn wait_vsync(&mut self) {
        self.spi.wait_vsync();
    }

    /// Check if the GPU command FIFO is almost full.
    pub fn is_fifo_full(&mut self) -> bool {
        self.spi.is_cmd_full()
    }

    /// Check if the GPU command FIFO is empty.
    pub fn is_fifo_empty(&mut self) -> bool {
        self.spi.is_cmd_empty()
    }
}
