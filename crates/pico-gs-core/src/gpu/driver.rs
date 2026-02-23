//! Platform-agnostic GPU driver, generic over SpiTransport.
//!
//! Replaces the RP2350-specific `GpuHandle` with `GpuDriver<S>` that delegates
//! all SPI and flow control to the transport implementation.

use pico_gs_hal::{FlowControl, SpiTransport};

use super::registers::{self, AlphaBlend, CullMode, ZCompare};
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

        // Configure initial render target via FB_CONFIG.
        driver.write(
            registers::FB_CONFIG,
            (registers::FB_A_BASE_512 as u64) << registers::FB_CONFIG_COLOR_BASE_SHIFT
                | (registers::ZBUFFER_BASE_512 as u64) << registers::FB_CONFIG_Z_BASE_SHIFT
                | (9u64 << registers::FB_CONFIG_WIDTH_LOG2_SHIFT)
                | (9u64 << registers::FB_CONFIG_HEIGHT_LOG2_SHIFT),
        )?;
        driver.write(
            registers::FB_DISPLAY,
            (registers::FB_B_BASE_512 as u64) << registers::FB_DISPLAY_FB_ADDR_SHIFT
                | (9u64 << registers::FB_DISPLAY_WIDTH_LOG2_SHIFT),
        )?;

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

    /// Upload a block of 64-bit dwords to GPU SDRAM via MEM_ADDR/MEM_DATA.
    ///
    /// `dword_addr` is a 22-bit dword address (byte address >> 3).
    pub fn upload_memory(
        &mut self,
        dword_addr: u32,
        data: &[u64],
    ) -> Result<(), GpuError<S::Error>> {
        self.write(registers::MEM_ADDR, dword_addr as u64)?;
        for &dword in data {
            self.write(registers::MEM_DATA, dword)?;
        }
        Ok(())
    }

    /// Read a block of 64-bit dwords from GPU SDRAM via MEM_ADDR/MEM_DATA.
    ///
    /// Writing MEM_ADDR triggers a prefetch; each subsequent MEM_DATA read
    /// returns the prefetched dword and pipelines the next.
    /// `dword_addr` is a 22-bit dword address (byte address >> 3).
    pub fn read_memory(
        &mut self,
        dword_addr: u32,
        buf: &mut [u64],
    ) -> Result<(), GpuError<S::Error>> {
        self.write(registers::MEM_ADDR, dword_addr as u64)?;
        for slot in buf.iter_mut() {
            *slot = self.read(registers::MEM_DATA)?;
        }
        Ok(())
    }

    /// Submit a single triangle (3 vertices) to the GPU.
    ///
    /// First two vertices use VERTEX_NOKICK; the third uses VERTEX_KICK_012
    /// to trigger rasterization with standard winding order.
    pub fn submit_triangle(
        &mut self,
        v0: &GpuVertex,
        v1: &GpuVertex,
        v2: &GpuVertex,
        textured: bool,
    ) -> Result<(), GpuError<S::Error>> {
        self.write(registers::COLOR, v0.color_packed)?;
        if textured {
            self.write(registers::UV0_UV1, v0.uv_packed)?;
        }
        self.write(registers::VERTEX_NOKICK, v0.position_packed)?;

        self.write(registers::COLOR, v1.color_packed)?;
        if textured {
            self.write(registers::UV0_UV1, v1.uv_packed)?;
        }
        self.write(registers::VERTEX_NOKICK, v1.position_packed)?;

        self.write(registers::COLOR, v2.color_packed)?;
        if textured {
            self.write(registers::UV0_UV1, v2.uv_packed)?;
        }
        self.write(registers::VERTEX_KICK_012, v2.position_packed)?;

        Ok(())
    }

    /// Configure per-material rendering state in a single RENDER_MODE register write.
    ///
    /// Packs all parameters into the unified RENDER_MODE register (0x30) per INT-010.
    #[allow(clippy::too_many_arguments)]
    pub fn set_render_mode(
        &mut self,
        gouraud: bool,
        z_test: bool,
        z_write: bool,
        color_write: bool,
        z_compare: ZCompare,
        alpha_blend: AlphaBlend,
        cull_mode: CullMode,
        dither: bool,
    ) -> Result<(), GpuError<S::Error>> {
        let value = ((z_compare as u64) << 13)
            | ((dither as u64) << 10)
            | ((alpha_blend as u64) << 7)
            | ((cull_mode as u64) << 5)
            | ((color_write as u64) << 4)
            | ((z_write as u64) << 3)
            | ((z_test as u64) << 2)
            | (gouraud as u64);
        self.write(registers::RENDER_MODE, value)
    }

    /// Configure depth range clipping (Z scissor).
    ///
    /// Fragments with Z outside [z_min, z_max] are discarded before any SRAM access.
    /// Default (disabled): z_min=0x0000, z_max=0xFFFF.
    pub fn set_z_range(&mut self, z_min: u16, z_max: u16) -> Result<(), GpuError<S::Error>> {
        let value = ((z_max as u64) << 16) | (z_min as u64);
        self.write(registers::Z_RANGE, value)
    }

    /// Swap draw and display framebuffers.
    ///
    /// Writes FB_DISPLAY with the new display target (blocking until vsync),
    /// then writes FB_CONFIG with the new draw target.
    pub fn swap_buffers(&mut self) -> Result<(), GpuError<S::Error>> {
        core::mem::swap(&mut self.draw_fb, &mut self.display_fb);
        self.write(
            registers::FB_DISPLAY,
            (self.display_fb as u64 >> 9) << registers::FB_DISPLAY_FB_ADDR_SHIFT
                | (9u64 << registers::FB_DISPLAY_WIDTH_LOG2_SHIFT),
        )?;
        self.write(
            registers::FB_CONFIG,
            (self.draw_fb as u64 >> 9) << registers::FB_CONFIG_COLOR_BASE_SHIFT
                | (registers::ZBUFFER_BASE_512 as u64) << registers::FB_CONFIG_Z_BASE_SHIFT
                | (9u64 << registers::FB_CONFIG_WIDTH_LOG2_SHIFT)
                | (9u64 << registers::FB_CONFIG_HEIGHT_LOG2_SHIFT),
        )?;
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

    /// Insert a timestamp marker into the command stream.
    ///
    /// When this command is processed by the GPU, the current frame-relative
    /// cycle counter (100 MHz, 10 ns resolution, saturating) is written as a
    /// 32-bit word to the specified SDRAM address.
    ///
    /// # Arguments
    ///
    /// * `sdram_word_addr` - 23-bit SDRAM word address (32-bit word granularity,
    ///   32 MiB addressable). Only bits \[22:0\] are used.
    pub fn timestamp(&mut self, sdram_word_addr: u32) -> Result<(), GpuError<S::Error>> {
        self.write(registers::PERF_TIMESTAMP, sdram_word_addr as u64)
    }

    /// Read the GPU's current cycle counter value (instantaneous, not FIFO-ordered).
    ///
    /// # Returns
    ///
    /// Frame-relative cycle count (32-bit, 100 MHz, saturating, resets at vsync).
    pub fn read_cycle_counter(&mut self) -> Result<u32, GpuError<S::Error>> {
        let val = self.read(registers::PERF_TIMESTAMP)?;
        Ok(val as u32)
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
