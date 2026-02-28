//! Addrmap: GPU Register Map

/// Named types defined within this component's body
pub mod named_types {
    pub mod area_setup_reg;
    pub mod cc_mode_reg;
    pub mod color_reg;
    pub mod const_color_reg;
    pub mod fb_config_reg;
    pub mod fb_control_reg;
    pub mod fb_display_reg;
    pub mod id_reg;
    pub mod mem_addr_reg;
    pub mod mem_data_reg;
    pub mod mem_fill_reg;
    pub mod perf_timestamp_reg;
    pub mod render_mode_reg;
    pub mod stipple_pattern_reg;
    pub mod tex_cfg_reg;
    pub mod uv0_uv1_reg;
    pub mod vertex_reg;
    pub mod z_range_reg;
}

// Instances of named component types
pub use crate::components::gpu_regs::named_types::area_setup_reg as area_setup;
pub use crate::components::gpu_regs::named_types::cc_mode_reg as cc_mode;
pub use crate::components::gpu_regs::named_types::color_reg as color;
pub use crate::components::gpu_regs::named_types::const_color_reg as const_color;
pub use crate::components::gpu_regs::named_types::fb_config_reg as fb_config;
pub use crate::components::gpu_regs::named_types::fb_control_reg as fb_control;
pub use crate::components::gpu_regs::named_types::fb_display_reg as fb_display;
pub use crate::components::gpu_regs::named_types::id_reg as id;
pub use crate::components::gpu_regs::named_types::mem_addr_reg as mem_addr;
pub use crate::components::gpu_regs::named_types::mem_data_reg as mem_data;
pub use crate::components::gpu_regs::named_types::mem_fill_reg as mem_fill;
pub use crate::components::gpu_regs::named_types::perf_timestamp_reg as perf_timestamp;
pub use crate::components::gpu_regs::named_types::render_mode_reg as render_mode;
pub use crate::components::gpu_regs::named_types::stipple_pattern_reg as stipple_pattern;
pub use crate::components::gpu_regs::named_types::tex_cfg_reg as tex0_cfg;
pub use crate::components::gpu_regs::named_types::tex_cfg_reg as tex1_cfg;
pub use crate::components::gpu_regs::named_types::uv0_uv1_reg as uv0_uv1;
pub use crate::components::gpu_regs::named_types::vertex_reg as vertex_nokick;
pub use crate::components::gpu_regs::named_types::vertex_reg as vertex_kick_012;
pub use crate::components::gpu_regs::named_types::vertex_reg as vertex_kick_021;
pub use crate::components::gpu_regs::named_types::vertex_reg as vertex_kick_rect;
pub use crate::components::gpu_regs::named_types::z_range_reg as z_range;

/// GPU Register Map
///
/// ICEpi SPI GPU register map v11.0
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct GpuRegs {
    ptr: *mut u8,
}

unsafe impl Send for GpuRegs {}
unsafe impl Sync for GpuRegs {}

impl GpuRegs {
    /// Size in bytes of the underlying memory
    pub const SIZE: usize = 0x400;

    /// # Safety
    ///
    /// The caller must guarantee that the provided address points to a
    /// hardware register block implementing this interface.
    #[inline(always)]
    #[must_use]
    pub const unsafe fn from_ptr(ptr: *mut ()) -> Self {
        Self {
            ptr: ptr.cast::<u8>(),
        }
    }

    #[inline(always)]
    #[must_use]
    pub const fn as_ptr(&self) -> *mut () {
        self.ptr.cast::<()>()
    }

    /// COLOR
    ///
    /// COLOR0[31:0] + COLOR1[63:32] vertex colors (RGBA8888 UNORM8 each)
    #[inline(always)]
    #[must_use]
    pub const fn color(&self) -> crate::reg::Reg<color::ColorReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x0).cast()) }
    }

    /// UV0_UV1
    ///
    /// Texture units 0+1 UV coordinates (Q4.12 fixed-point, range +/-8.0)
    #[inline(always)]
    #[must_use]
    pub const fn uv0_uv1(&self) -> crate::reg::Reg<uv0_uv1::Uv0Uv1Reg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x8).cast()) }
    }

    /// AREA_SETUP
    ///
    /// Barycentric interpolation area normalization.
    /// INV_AREA is the reciprocal of (2*triangle_area >> AREA_SHIFT)
    /// in UQ0.16 fixed point.  AREA_SHIFT is the barrel-shift count
    /// applied to edge function values before the 16x16 multiply.
    /// The host computes both values from the triangle vertex
    /// positions before each vertex kick.
    #[inline(always)]
    #[must_use]
    pub const fn area_setup(&self) -> crate::reg::Reg<area_setup::AreaSetupReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x28).cast()) }
    }

    /// VERTEX
    ///
    /// Vertex position + 1/W (write-only trigger).
    /// Origin (0,0) is the center of the top-left pixel,
    /// X+ right, Y+ down (S12.4). Integer coordinates
    /// address pixel centers directly. Coordinates extend
    /// beyond the framebuffer for guard-band clipping — the
    /// scissor rectangle (FB_CONTROL) defines the visible
    /// region; pixels outside are discarded per-fragment.
    /// KICK_RECT uses this vertex and the previous NOKICK
    /// vertex as opposite corners of an axis-aligned rectangle.
    #[inline(always)]
    #[must_use]
    pub const fn vertex_nokick(
        &self,
    ) -> crate::reg::Reg<vertex_nokick::VertexReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x30).cast()) }
    }

    /// VERTEX
    ///
    /// Vertex position + 1/W (write-only trigger).
    /// Origin (0,0) is the center of the top-left pixel,
    /// X+ right, Y+ down (S12.4). Integer coordinates
    /// address pixel centers directly. Coordinates extend
    /// beyond the framebuffer for guard-band clipping — the
    /// scissor rectangle (FB_CONTROL) defines the visible
    /// region; pixels outside are discarded per-fragment.
    /// KICK_RECT uses this vertex and the previous NOKICK
    /// vertex as opposite corners of an axis-aligned rectangle.
    #[inline(always)]
    #[must_use]
    pub const fn vertex_kick_012(
        &self,
    ) -> crate::reg::Reg<vertex_kick_012::VertexReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x38).cast()) }
    }

    /// VERTEX
    ///
    /// Vertex position + 1/W (write-only trigger).
    /// Origin (0,0) is the center of the top-left pixel,
    /// X+ right, Y+ down (S12.4). Integer coordinates
    /// address pixel centers directly. Coordinates extend
    /// beyond the framebuffer for guard-band clipping — the
    /// scissor rectangle (FB_CONTROL) defines the visible
    /// region; pixels outside are discarded per-fragment.
    /// KICK_RECT uses this vertex and the previous NOKICK
    /// vertex as opposite corners of an axis-aligned rectangle.
    #[inline(always)]
    #[must_use]
    pub const fn vertex_kick_021(
        &self,
    ) -> crate::reg::Reg<vertex_kick_021::VertexReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x40).cast()) }
    }

    /// VERTEX
    ///
    /// Vertex position + 1/W (write-only trigger).
    /// Origin (0,0) is the center of the top-left pixel,
    /// X+ right, Y+ down (S12.4). Integer coordinates
    /// address pixel centers directly. Coordinates extend
    /// beyond the framebuffer for guard-band clipping — the
    /// scissor rectangle (FB_CONTROL) defines the visible
    /// region; pixels outside are discarded per-fragment.
    /// KICK_RECT uses this vertex and the previous NOKICK
    /// vertex as opposite corners of an axis-aligned rectangle.
    #[inline(always)]
    #[must_use]
    pub const fn vertex_kick_rect(
        &self,
    ) -> crate::reg::Reg<vertex_kick_rect::VertexReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x48).cast()) }
    }

    /// TEXn_CFG
    ///
    /// Texture sampler configuration (single 64-bit register per unit).
    /// All pixel data uses 4x4 block-tiled layout in SDRAM.
    /// BASE_ADDR is a 16-bit value multiplied by 512 to form the
    /// byte address (512-byte granularity, 32 MiB addressable).
    /// Octahedral wrap mode implements coupled diagonal mirroring:
    /// crossing one axis edge flips the other axis coordinate.
    /// Any write to this register invalidates the texture cache
    /// for the corresponding texture unit.
    #[inline(always)]
    #[must_use]
    pub const fn tex0_cfg(&self) -> crate::reg::Reg<tex0_cfg::TexCfgReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x80).cast()) }
    }

    /// TEXn_CFG
    ///
    /// Texture sampler configuration (single 64-bit register per unit).
    /// All pixel data uses 4x4 block-tiled layout in SDRAM.
    /// BASE_ADDR is a 16-bit value multiplied by 512 to form the
    /// byte address (512-byte granularity, 32 MiB addressable).
    /// Octahedral wrap mode implements coupled diagonal mirroring:
    /// crossing one axis edge flips the other axis coordinate.
    /// Any write to this register invalidates the texture cache
    /// for the corresponding texture unit.
    #[inline(always)]
    #[must_use]
    pub const fn tex1_cfg(&self) -> crate::reg::Reg<tex1_cfg::TexCfgReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x88).cast()) }
    }

    /// CC_MODE
    ///
    /// Color combiner mode: equation (A-B)*C+D, independent RGB and Alpha.
    /// The hardware always pipelines two combiner stages at one pixel
    /// per clock.  Cycle 0 output feeds cycle 1 via the COMBINED source.
    /// For single-equation behavior, configure cycle 1 as a pass-through:
    /// A=COMBINED, B=ZERO, C=ONE, D=ZERO.
    /// The RGB C slot uses an extended source set (cc_rgb_c_source_e)
    /// that includes alpha-to-RGB broadcast sources for blend factors.
    /// All other slots use cc_source_e.
    #[inline(always)]
    #[must_use]
    pub const fn cc_mode(&self) -> crate::reg::Reg<cc_mode::CcModeReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0xC0).cast()) }
    }

    /// CONST_COLOR
    ///
    /// Two per-draw-call constant colors packed into one 64-bit register (RGBA8888 UNORM8 each).
    /// CONST1 (bits [63:32]) doubles as the fog color.
    #[inline(always)]
    #[must_use]
    pub const fn const_color(
        &self,
    ) -> crate::reg::Reg<const_color::ConstColorReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0xC8).cast()) }
    }

    /// RENDER_MODE
    ///
    /// Unified rendering state (Gouraud, Z, alpha, culling, dithering, stipple)
    #[inline(always)]
    #[must_use]
    pub const fn render_mode(
        &self,
    ) -> crate::reg::Reg<render_mode::RenderModeReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x180).cast()) }
    }

    /// Z_RANGE
    ///
    /// Depth range clipping (Z scissor) min/max
    #[inline(always)]
    #[must_use]
    pub const fn z_range(&self) -> crate::reg::Reg<z_range::ZRangeReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x188).cast()) }
    }

    /// STIPPLE_PATTERN
    ///
    /// 8x8 stipple bitmask (row-major, bit 0 = pixel (0,0)).
    /// Bit index = y[2:0] * 8 + x[2:0].  Fragment passes if the
    /// corresponding bit is 1; discarded if 0.  Only active when
    /// RENDER_MODE.STIPPLE_EN = 1.  Screen coordinates are masked
    /// to 3 bits (x & 7, y & 7) to index into the pattern.
    #[inline(always)]
    #[must_use]
    pub const fn stipple_pattern(
        &self,
    ) -> crate::reg::Reg<stipple_pattern::StipplePatternReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x190).cast()) }
    }

    /// FB_CONFIG
    ///
    /// Render target configuration: color/Z-buffer base addresses and
    /// power-of-two surface dimensions.
    /// COLOR_BASE and Z_BASE are 16-bit values multiplied by 512
    /// to form the byte address (512-byte granularity, 32 MiB
    /// addressable), matching the texture BASE_ADDR encoding.
    /// WIDTH_LOG2 and HEIGHT_LOG2 define the surface dimensions in
    /// pixels as 1 << n; both the color buffer and Z-buffer use 4×4
    /// block-tiled layout at these dimensions.  A paired Z-buffer at
    /// Z_BASE always has the same dimensions as the color buffer.
    /// The host reprograms this register between render passes to
    /// switch between display framebuffer and off-screen render
    /// targets; the pixel writer uses WIDTH_LOG2 for tiled address
    /// calculation (shift-only, no multiply).
    #[inline(always)]
    #[must_use]
    pub const fn fb_config(&self) -> crate::reg::Reg<fb_config::FbConfigReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x200).cast()) }
    }

    /// FB_DISPLAY
    ///
    /// Display scanout configuration (write-blocks-until-vsync).
    /// Writing this register blocks the GPU pipeline until the next
    /// vertical blanking interval, then atomically switches the
    /// display scanout address and latches all display mode fields.
    /// The DVI output is always 640×480 at 60 Hz.  The display
    /// controller reads from a 4×4 block-tiled framebuffer and
    /// stretches the source image to 640×480 using nearest-neighbor
    /// horizontal scaling (Bresenham accumulator, no multiply HW).
    /// FB_WIDTH_LOG2 specifies the tiled surface width for scanout
    /// address calculation — latched independently from FB_CONFIG
    /// so that render-to-texture passes can reprogram FB_CONFIG
    /// mid-frame without affecting display scanout.
    /// When LINE_DOUBLE is set, only 240 source rows are read and
    /// each is output twice to fill 480 display lines; the line
    /// buffer is reused without re-reading SDRAM.
    /// Horizontal interpolation operates on UNORM8 values post
    /// color-grade LUT, ensuring tone mapping precedes any pixel
    /// blending.
    /// If COLOR_GRADE_ENABLE is set, the color grading LUT is
    /// loaded from LUT_ADDR during the blanking interval before
    /// the new frame begins scanout.
    /// FB_ADDR and LUT_ADDR are 16-bit values multiplied by 512
    /// to form the byte address (512-byte granularity, 32 MiB
    /// addressable), matching the texture BASE_ADDR encoding.
    #[inline(always)]
    #[must_use]
    pub const fn fb_display(&self) -> crate::reg::Reg<fb_display::FbDisplayReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x208).cast()) }
    }

    /// FB_CONTROL
    ///
    /// Scissor rectangle
    #[inline(always)]
    #[must_use]
    pub const fn fb_control(&self) -> crate::reg::Reg<fb_control::FbControlReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x218).cast()) }
    }

    /// MEM_FILL
    ///
    /// Hardware memory fill (write-triggers-fill).
    /// Writes a 16-bit constant value to a contiguous region of SDRAM.
    /// FILL_BASE uses the same 512-byte-granularity encoding as
    /// COLOR_BASE, Z_BASE, and texture BASE_ADDR.
    /// The fill unit generates sequential SDRAM burst writes for
    /// maximum throughput.  Blocks the GPU pipeline until complete;
    /// the SPI command FIFO continues accepting commands.
    #[inline(always)]
    #[must_use]
    pub const fn mem_fill(&self) -> crate::reg::Reg<mem_fill::MemFillReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x220).cast()) }
    }

    /// PERF_TIMESTAMP
    ///
    /// Command-stream timestamp marker.
    /// Write: DATA[22:0] = 23-bit SDRAM word address (32-bit word
    /// granularity, 32 MiB addressable).  When this command reaches
    /// the front of the command FIFO, the GPU captures the current
    /// frame-relative cycle counter (32-bit unsigned saturating,
    /// clk_core, resets to 0 on vsync rising edge) and writes it
    /// as a 32-bit word to the specified SDRAM address via the
    /// memory arbiter.
    /// Read: returns the live (instantaneous) cycle counter in
    /// bits [31:0], zero-extended to 64 bits.  Not FIFO-ordered.
    #[inline(always)]
    #[must_use]
    pub const fn perf_timestamp(
        &self,
    ) -> crate::reg::Reg<perf_timestamp::PerfTimestampReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x280).cast()) }
    }

    /// MEM_ADDR
    ///
    /// Memory access dword address pointer (22-bit, addresses 8-byte dwords
    /// in 32 MiB SDRAM).  Writing this register sets the SDRAM target
    /// address and triggers a read prefetch so that the next SPI read of
    /// MEM_DATA can return data immediately.
    #[inline(always)]
    #[must_use]
    pub const fn mem_addr(&self) -> crate::reg::Reg<mem_addr::MemAddrReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x380).cast()) }
    }

    /// MEM_DATA
    ///
    /// Memory data register (bidirectional 64-bit, auto-increments MEM_ADDR by 1).
    /// Write: stores DATA[63:0] to SDRAM at MEM_ADDR, then increments.
    /// Read: returns prefetched 64-bit SDRAM dword and triggers next prefetch.
    #[inline(always)]
    #[must_use]
    pub const fn mem_data(&self) -> crate::reg::Reg<mem_data::MemDataReg, crate::access::RW> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x388).cast()) }
    }

    /// ID
    ///
    /// GPU identification (read-only)
    #[inline(always)]
    #[must_use]
    pub const fn id(&self) -> crate::reg::Reg<id::IdReg, crate::access::R> {
        unsafe { crate::reg::Reg::from_ptr(self.ptr.wrapping_byte_add(0x3F8).cast()) }
    }
}
