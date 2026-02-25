// Spec-ref: unit_022_gpu_driver_layer.md `2e395d1315d4c2b1` 2026-02-25
//! Platform-agnostic GPU driver, generic over SpiTransport.
//!
//! Replaces the RP2350-specific `GpuHandle` with `GpuDriver<S>` that delegates
//! all SPI and flow control to the transport implementation.

use pico_gs_hal::{FlowControl, SpiTransport};

use super::registers::{self, AlphaBlend, AlphaTestFunc, CullMode, ZCompare};
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

/// Color combiner input source (4-bit, used for A/B/D slots and alpha A/B/C/D).
///
/// Per INT-020 `CcSource` enum.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum CcSource {
    /// Previous cycle output.
    Combined = 0x0,
    /// Texture unit 0 output.
    TexColor0 = 0x1,
    /// Texture unit 1 output.
    TexColor1 = 0x2,
    /// Vertex color 0 (diffuse).
    Shade0 = 0x3,
    /// Constant color 0.
    Const0 = 0x4,
    /// Constant color 1 / fog color.
    Const1 = 0x5,
    /// Constant 1.0.
    One = 0x6,
    /// Constant 0.0.
    Zero = 0x7,
    /// Vertex color 1 (specular).
    Shade1 = 0x8,
}

/// Color combiner RGB C-slot source (4-bit, extended set for blend factor).
///
/// Per INT-020 `CcRgbCSource` enum.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum CcRgbCSource {
    /// Previous cycle output.
    Combined = 0x0,
    /// Texture unit 0 output.
    TexColor0 = 0x1,
    /// Texture unit 1 output.
    TexColor1 = 0x2,
    /// Vertex color 0 (diffuse).
    Shade0 = 0x3,
    /// Constant color 0.
    Const0 = 0x4,
    /// Constant color 1 / fog color.
    Const1 = 0x5,
    /// Constant 1.0.
    One = 0x6,
    /// Constant 0.0.
    Zero = 0x7,
    /// TEX0 alpha broadcast to RGB.
    TexColor0Alpha = 0x8,
    /// TEX1 alpha broadcast to RGB.
    TexColor1Alpha = 0x9,
    /// Shade0 alpha broadcast to RGB.
    Shade0Alpha = 0xA,
    /// Const0 alpha broadcast to RGB.
    Const0Alpha = 0xB,
    /// Combined alpha broadcast to RGB.
    CombinedAlpha = 0xC,
    /// Shade1 RGB.
    Shade1 = 0xD,
    /// Shade1 alpha broadcast to RGB.
    Shade1Alpha = 0xE,
}

/// One cycle of the two-stage color combiner equation `(A - B) * C + D`.
///
/// Per INT-020 `CombinerCycle` struct.
#[derive(Clone, Copy, Debug)]
pub struct CombinerCycle {
    /// RGB A source.
    pub rgb_a: CcSource,
    /// RGB B source.
    pub rgb_b: CcSource,
    /// RGB C source (extended set for blend factor).
    pub rgb_c: CcRgbCSource,
    /// RGB D source.
    pub rgb_d: CcSource,
    /// Alpha A source.
    pub alpha_a: CcSource,
    /// Alpha B source.
    pub alpha_b: CcSource,
    /// Alpha C source.
    pub alpha_c: CcSource,
    /// Alpha D source.
    pub alpha_d: CcSource,
}

/// Vertex kick mode for `submit_vertex_kicked()`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VertexKick {
    /// No triangle emitted.
    NoKick,
    /// Emit triangle (v\[0\], v\[1\], v\[2\]).
    Kick012,
    /// Emit triangle (v\[0\], v\[2\], v\[1\]).
    Kick021,
}

/// Framebuffer configuration tuple: (color_base, z_base, width_log2, height_log2).
///
/// `color_base` and `z_base` are in 512-byte granularity units (byte address / 512).
/// `width_log2` and `height_log2` are power-of-two exponents (e.g. 9 = 512 pixels).
pub type FbConfig = (u16, u16, u8, u8);

/// Platform-agnostic GPU driver. Owns a transport that implements SPI
/// communication with the GPU hardware.
pub struct GpuDriver<S: SpiTransport> {
    spi: S,
    /// Current draw framebuffer (color_base, z_base, width_log2, height_log2).
    draw_fb: FbConfig,
    /// Current display framebuffer (color_base, z_base, width_log2, height_log2).
    display_fb: FbConfig,
}

/// Pack FB_CONFIG register value from its component fields.
///
/// Per INT-010: \[15:0\] COLOR_BASE, \[31:16\] Z_BASE,
/// \[35:32\] WIDTH_LOG2, \[39:36\] HEIGHT_LOG2.
fn pack_fb_config(color_base: u16, z_base: u16, width_log2: u8, height_log2: u8) -> u64 {
    (color_base as u64)
        | ((z_base as u64) << registers::FB_CONFIG_Z_BASE_SHIFT)
        | ((width_log2 as u64) << registers::FB_CONFIG_WIDTH_LOG2_SHIFT)
        | ((height_log2 as u64) << registers::FB_CONFIG_HEIGHT_LOG2_SHIFT)
}

/// Pack FB_DISPLAY register value for display scanout.
///
/// Per INT-010: \[0\] COLOR_GRADE_ENABLE, \[1\] LINE_DOUBLE,
/// \[31:16\] LUT_ADDR, \[47:32\] FB_ADDR, \[51:48\] WIDTH_LOG2.
fn pack_fb_display(fb_addr: u16, width_log2: u8) -> u64 {
    ((fb_addr as u64) << registers::FB_DISPLAY_FB_ADDR_SHIFT)
        | ((width_log2 as u64) << registers::FB_DISPLAY_WIDTH_LOG2_SHIFT)
}

/// Pack one combiner cycle into 32 bits per INT-010 CC_MODE layout.
///
/// Cycle layout (32 bits):
/// \[3:0\] ALPHA_A, \[7:4\] ALPHA_B, \[11:8\] ALPHA_C, \[15:12\] ALPHA_D,
/// \[19:16\] RGB_A, \[23:20\] RGB_B, \[27:24\] RGB_C, \[31:28\] RGB_D.
fn pack_combiner_cycle(cycle: &CombinerCycle) -> u64 {
    ((cycle.alpha_a as u64) & 0xF)
        | (((cycle.alpha_b as u64) & 0xF) << 4)
        | (((cycle.alpha_c as u64) & 0xF) << 8)
        | (((cycle.alpha_d as u64) & 0xF) << 12)
        | (((cycle.rgb_a as u64) & 0xF) << 16)
        | (((cycle.rgb_b as u64) & 0xF) << 20)
        | (((cycle.rgb_c as u64) & 0xF) << 24)
        | (((cycle.rgb_d as u64) & 0xF) << 28)
}

impl<S: SpiTransport> GpuDriver<S> {
    /// Initialize the GPU driver. Verifies GPU presence by reading the ID register,
    /// then configures initial framebuffer addresses.
    ///
    /// # Arguments
    ///
    /// * `spi` - Platform-specific SPI transport implementing `SpiTransport`.
    ///
    /// # Returns
    ///
    /// `Ok(GpuDriver)` on success, `Err(GpuNotDetected)` if the ID register
    /// returns an unexpected value.
    ///
    /// # Errors
    ///
    /// Returns `GpuError::GpuNotDetected` if the device ID does not match,
    /// or `GpuError::Transport` on SPI bus failure.
    pub fn new(spi: S) -> Result<Self, GpuError<S::Error>> {
        let mut driver = Self {
            spi,
            draw_fb: (registers::FB_A_BASE_512, registers::ZBUFFER_BASE_512, 9, 9),
            display_fb: (registers::FB_B_BASE_512, 0, 9, 9),
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
            pack_fb_config(
                driver.draw_fb.0,
                driver.draw_fb.1,
                driver.draw_fb.2,
                driver.draw_fb.3,
            ),
        )?;

        // Configure initial display scanout via FB_DISPLAY.
        driver.write(
            registers::FB_DISPLAY,
            pack_fb_display(driver.display_fb.0, driver.display_fb.2),
        )?;

        Ok(driver)
    }

    /// Write a 64-bit value to a GPU register.
    ///
    /// # Arguments
    ///
    /// * `addr` - 7-bit register address (0x00-0x7F).
    /// * `data` - 64-bit register value.
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn write(&mut self, addr: u8, data: u64) -> Result<(), GpuError<S::Error>> {
        self.spi.write_register(addr, data)?;
        Ok(())
    }

    /// Read a 64-bit value from a GPU register.
    ///
    /// # Arguments
    ///
    /// * `addr` - 7-bit register address with bit 7 set for read.
    ///
    /// # Returns
    ///
    /// The 64-bit register value.
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn read(&mut self, addr: u8) -> Result<u64, GpuError<S::Error>> {
        let val = self.spi.read_register(addr)?;
        Ok(val)
    }

    /// Upload a block of 64-bit dwords to GPU SDRAM via MEM_ADDR/MEM_DATA.
    ///
    /// # Arguments
    ///
    /// * `dword_addr` - 22-bit dword address (byte address >> 3).
    /// * `data` - Slice of 64-bit dwords to upload.
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
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
    ///
    /// # Arguments
    ///
    /// * `dword_addr` - 22-bit dword address (byte address >> 3).
    /// * `buf` - Mutable buffer to fill with read dwords.
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
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
    ///
    /// # Arguments
    ///
    /// * `v0`, `v1`, `v2` - Pre-packed vertices.
    /// * `textured` - If true, UV0_UV1 registers are written for each vertex.
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
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

    /// Submit a single vertex with explicit kick mode.
    ///
    /// Writes COLOR (0x00), optionally UV0_UV1 (0x01), then the appropriate
    /// VERTEX register based on the kick mode.
    ///
    /// # Arguments
    ///
    /// * `vertex` - Pre-packed vertex data.
    /// * `kick` - Kick mode: NoKick, Kick012, or Kick021.
    /// * `textured` - If true, UV0_UV1 is written.
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn submit_vertex_kicked(
        &mut self,
        vertex: &GpuVertex,
        kick: VertexKick,
        textured: bool,
    ) -> Result<(), GpuError<S::Error>> {
        self.write(registers::COLOR, vertex.color_packed)?;
        if textured {
            self.write(registers::UV0_UV1, vertex.uv_packed)?;
        }
        let reg = match kick {
            VertexKick::NoKick => registers::VERTEX_NOKICK,
            VertexKick::Kick012 => registers::VERTEX_KICK_012,
            VertexKick::Kick021 => registers::VERTEX_KICK_021,
        };
        self.write(reg, vertex.position_packed)?;
        Ok(())
    }

    /// Configure per-material rendering state in a single RENDER_MODE register write.
    ///
    /// Packs all parameters into the unified RENDER_MODE register (0x30) per INT-010.
    ///
    /// # Arguments
    ///
    /// * `gouraud` - Enable Gouraud shading (true) or flat shading (false).
    /// * `z_test` - Enable depth testing.
    /// * `z_write` - Enable Z-buffer writes on depth test pass.
    /// * `color_write` - Enable color buffer writes (false = Z-only prepass).
    /// * `z_compare` - Depth comparison function.
    /// * `alpha_blend` - Alpha blending mode.
    /// * `cull_mode` - Backface culling mode.
    /// * `dither` - Enable ordered dithering before RGB565 framebuffer write.
    /// * `stipple_en` - Enable 8x8 stipple pattern fragment discard.
    /// * `alpha_test` - Alpha test comparison function.
    /// * `alpha_ref` - Alpha reference value (UNORM8, compared against fragment alpha).
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
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
        stipple_en: bool,
        alpha_test: AlphaTestFunc,
        alpha_ref: u8,
    ) -> Result<(), GpuError<S::Error>> {
        let value = (gouraud as u64)
            | ((z_test as u64) << 2)
            | ((z_write as u64) << 3)
            | ((color_write as u64) << 4)
            | ((cull_mode as u64) << 5)
            | ((alpha_blend as u64) << 7)
            | ((dither as u64) << 10)
            | ((z_compare as u64) << 13)
            | ((stipple_en as u64) << 16)
            | ((alpha_test as u64) << 17)
            | ((alpha_ref as u64) << 19);
        self.write(registers::RENDER_MODE, value)
    }

    /// Configure depth range clipping (Z scissor).
    ///
    /// Fragments with Z outside \[z_min, z_max\] are discarded before any SDRAM access.
    /// Default (disabled): z_min=0x0000, z_max=0xFFFF.
    ///
    /// # Arguments
    ///
    /// * `z_min` - Minimum Z value (inclusive).
    /// * `z_max` - Maximum Z value (inclusive).
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn set_z_range(&mut self, z_min: u16, z_max: u16) -> Result<(), GpuError<S::Error>> {
        let value = ((z_max as u64) << 16) | (z_min as u64);
        self.write(registers::Z_RANGE, value)
    }

    /// Configure the render target (color buffer + Z-buffer) for subsequent rendering.
    ///
    /// Packs fields into FB_CONFIG (0x40) per INT-010.
    ///
    /// # Arguments
    ///
    /// * `color_base` - Byte address of color buffer / 512 (512-byte granularity).
    /// * `z_base` - Byte address of Z-buffer / 512.
    /// * `width_log2` - Surface width as power-of-two exponent (e.g. 9 = 512 pixels).
    /// * `height_log2` - Surface height as power-of-two exponent.
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn gpu_set_fb_config(
        &mut self,
        color_base: u16,
        z_base: u16,
        width_log2: u8,
        height_log2: u8,
    ) -> Result<(), GpuError<S::Error>> {
        self.draw_fb = (color_base, z_base, width_log2, height_log2);
        self.write(
            registers::FB_CONFIG,
            pack_fb_config(color_base, z_base, width_log2, height_log2),
        )
    }

    /// Set the pixel-precision scissor rectangle.
    ///
    /// Fragments outside the rectangle are discarded.
    /// Packs fields into FB_CONTROL (0x43) per INT-010.
    ///
    /// # Arguments
    ///
    /// * `x` - Scissor rectangle top-left X (10 bits, 0-1023).
    /// * `y` - Scissor rectangle top-left Y (10 bits, 0-1023).
    /// * `width` - Scissor rectangle width (10 bits, 1-1024).
    /// * `height` - Scissor rectangle height (10 bits, 1-1024).
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn gpu_set_scissor(
        &mut self,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    ) -> Result<(), GpuError<S::Error>> {
        let value = ((x as u64) & 0x3FF)
            | (((y as u64) & 0x3FF) << 10)
            | (((width as u64) & 0x3FF) << 20)
            | (((height as u64) & 0x3FF) << 30);
        self.write(registers::FB_CONTROL, value)
    }

    /// Fill a contiguous region of SDRAM with a 16-bit constant value.
    ///
    /// Uses the hardware MEM_FILL engine (register 0x44).
    /// GPU executes the fill synchronously within the command FIFO.
    ///
    /// # Arguments
    ///
    /// * `base` - Target base address (512-byte granularity, same encoding as
    ///   FB_CONFIG.COLOR_BASE). Byte address = base * 512.
    /// * `value` - 16-bit constant to write (RGB565 for color buffer, Z16 for Z-buffer).
    /// * `count` - Number of 16-bit words to write (up to 1,048,576).
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn gpu_mem_fill(
        &mut self,
        base: u16,
        value: u16,
        count: u32,
    ) -> Result<(), GpuError<S::Error>> {
        let reg_value = (base as u64)
            | ((value as u64) << registers::MEM_FILL_VALUE_SHIFT)
            | ((count as u64) << registers::MEM_FILL_COUNT_SHIFT);
        self.write(registers::MEM_FILL, reg_value)
    }

    /// Set the 8x8 stipple bitmask.
    ///
    /// Bit index = y\[2:0\] * 8 + x\[2:0\]. Fragment passes when bit = 1.
    /// Default: 0xFFFFFFFF_FFFFFFFF (all fragments pass).
    ///
    /// # Arguments
    ///
    /// * `pattern` - 64-bit stipple pattern.
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn gpu_set_stipple_pattern(&mut self, pattern: u64) -> Result<(), GpuError<S::Error>> {
        self.write(registers::STIPPLE_PATTERN, pattern)
    }

    /// Configure the two-stage color combiner equation `(A - B) * C + D`.
    ///
    /// Cycle 0 occupies CC_MODE\[31:0\], cycle 1 occupies CC_MODE\[63:32\].
    ///
    /// # Arguments
    ///
    /// * `c0` - Cycle 0 combiner equation selectors.
    /// * `c1` - Cycle 1 combiner equation selectors.
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn gpu_set_combiner_mode(
        &mut self,
        c0: &CombinerCycle,
        c1: &CombinerCycle,
    ) -> Result<(), GpuError<S::Error>> {
        let cycle0 = pack_combiner_cycle(c0);
        let cycle1 = pack_combiner_cycle(c1);
        let value = cycle0 | (cycle1 << 32);
        self.write(registers::CC_MODE, value)
    }

    /// Set single-stage combiner mode with automatic pass-through for cycle 1.
    ///
    /// Configures cycle 0 with the provided equation and cycle 1 as pass-through
    /// (A=COMBINED, B=ZERO, C=ONE, D=ZERO).
    ///
    /// # Arguments
    ///
    /// * `c0` - Cycle 0 combiner equation selectors.
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn gpu_set_combiner_simple(
        &mut self,
        c0: &CombinerCycle,
    ) -> Result<(), GpuError<S::Error>> {
        let passthrough = CombinerCycle {
            rgb_a: CcSource::Combined,
            rgb_b: CcSource::Zero,
            rgb_c: CcRgbCSource::One,
            rgb_d: CcSource::Zero,
            alpha_a: CcSource::Combined,
            alpha_b: CcSource::Zero,
            alpha_c: CcSource::One,
            alpha_d: CcSource::Zero,
        };
        self.gpu_set_combiner_mode(c0, &passthrough)
    }

    /// Set the two per-draw-call constant colors.
    ///
    /// CONST0 occupies CONST_COLOR\[31:0\], CONST1 (also fog color) occupies
    /// CONST_COLOR\[63:32\]. Both are RGBA8888.
    ///
    /// # Arguments
    ///
    /// * `const0` - Constant color 0 (RGBA8888 packed as u32).
    /// * `const1` - Constant color 1 / fog color (RGBA8888 packed as u32).
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn gpu_set_const_color(
        &mut self,
        const0: u32,
        const1: u32,
    ) -> Result<(), GpuError<S::Error>> {
        let value = (const0 as u64) | ((const1 as u64) << 32);
        self.write(registers::CONST_COLOR, value)
    }

    /// Upload color grading LUT data to SDRAM for later auto-load.
    ///
    /// Writes `lut_sdram_addr` to MEM_ADDR (0x70), then writes each dword
    /// to MEM_DATA (0x71) which auto-increments the address.
    /// The hardware auto-loads the LUT during vblank when FB_DISPLAY.LUT_ADDR
    /// is set.
    ///
    /// # Arguments
    ///
    /// * `lut_sdram_addr` - SDRAM dword address for LUT storage (must be
    ///   512-byte aligned, i.e. dword_addr must be a multiple of 64).
    /// * `lut_data` - LUT dword data (384 bytes = 48 dwords).
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn gpu_prepare_lut(
        &mut self,
        lut_sdram_addr: u32,
        lut_data: &[u64],
    ) -> Result<(), GpuError<S::Error>> {
        self.upload_memory(lut_sdram_addr, lut_data)
    }

    /// Swap draw and display framebuffers.
    ///
    /// Swaps the internal draw and display framebuffer state, then writes
    /// FB_CONFIG (0x40) for the new draw target and FB_DISPLAY (0x41) for
    /// the new display target.
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn swap_buffers(&mut self) -> Result<(), GpuError<S::Error>> {
        core::mem::swap(&mut self.draw_fb, &mut self.display_fb);

        // Write FB_CONFIG for the new draw target.
        self.write(
            registers::FB_CONFIG,
            pack_fb_config(
                self.draw_fb.0,
                self.draw_fb.1,
                self.draw_fb.2,
                self.draw_fb.3,
            ),
        )?;

        // Write FB_DISPLAY for the new display target.
        self.write(
            registers::FB_DISPLAY,
            pack_fb_display(self.display_fb.0, self.display_fb.2),
        )?;

        Ok(())
    }

    /// Get the current draw framebuffer configuration.
    ///
    /// # Returns
    ///
    /// Tuple of (color_base, z_base, width_log2, height_log2).
    pub fn draw_fb(&self) -> FbConfig {
        self.draw_fb
    }

    /// Get the current display framebuffer configuration.
    ///
    /// # Returns
    ///
    /// Tuple of (color_base, z_base, width_log2, height_log2).
    pub fn display_fb(&self) -> FbConfig {
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
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn timestamp(&mut self, sdram_word_addr: u32) -> Result<(), GpuError<S::Error>> {
        self.write(registers::PERF_TIMESTAMP, sdram_word_addr as u64)
    }

    /// Read the GPU's current cycle counter value (instantaneous, not FIFO-ordered).
    ///
    /// # Returns
    ///
    /// Frame-relative cycle count (32-bit, 100 MHz, saturating, resets at vsync).
    ///
    /// # Errors
    ///
    /// Returns `GpuError::Transport` on SPI bus failure.
    pub fn read_cycle_counter(&mut self) -> Result<u32, GpuError<S::Error>> {
        let val = self.read(registers::PERF_TIMESTAMP)?;
        Ok(val as u32)
    }

    /// Pack a 9-byte SPI register write frame into a SRAM buffer.
    ///
    /// For DMA/PIO-driven SPI output on RP2350.
    ///
    /// # Arguments
    ///
    /// * `buffer` - Destination buffer (must have at least `offset + 9` bytes).
    /// * `offset` - Start index in the buffer.
    /// * `addr` - 7-bit register address.
    /// * `data` - 64-bit register value.
    ///
    /// # Returns
    ///
    /// `offset + 9` (next free position in the buffer).
    pub fn pack_write(buffer: &mut [u8], offset: usize, addr: u8, data: u64) -> usize {
        buffer[offset] = addr & 0x7F;
        buffer[offset + 1] = ((data >> 56) & 0xFF) as u8;
        buffer[offset + 2] = ((data >> 48) & 0xFF) as u8;
        buffer[offset + 3] = ((data >> 40) & 0xFF) as u8;
        buffer[offset + 4] = ((data >> 32) & 0xFF) as u8;
        buffer[offset + 5] = ((data >> 24) & 0xFF) as u8;
        buffer[offset + 6] = ((data >> 16) & 0xFF) as u8;
        buffer[offset + 7] = ((data >> 8) & 0xFF) as u8;
        buffer[offset + 8] = (data & 0xFF) as u8;
        offset + 9
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
