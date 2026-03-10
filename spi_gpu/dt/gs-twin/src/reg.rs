//! Register-write interface matching the RTL's register_file.sv.
//!
//! The GPU accepts 72-bit SPI frames: `{rw(1), addr(7), data(64)}`.
//! This module models the register file's state machine and vertex
//! buffering, decoding register writes into `GpuAction` values that
//! the caller (`Gpu`) dispatches.
//!
//! # RTL Implementation Notes
//! The register file (UNIT-003) latches vertex positions, colors, and
//! STs on VERTEX_NOKICK writes, advancing a vertex counter.
//! A VERTEX_KICK write stores the final vertex and returns a
//! `GpuAction::KickTriangle` containing the assembled `RasterTriangle`.
//!
//! # References
//! - INT-010 (GPU Register Map)
//! - UNIT-003 (Register File)
//! - INT-021 (Render Command Format)

use crate::pipeline::rasterize::{self, RasterTriangle};
use crate::reg_ext::{reg_from_raw, reg_to_raw};
use gpu_registers::components::gpu_regs::named_types::{
    cc_mode_reg::CcModeReg, color_reg::ColorReg, const_color_reg::ConstColorReg,
    fb_config_reg::FbConfigReg, fb_control_reg::FbControlReg, fb_display_reg::FbDisplayReg,
    mem_fill_reg::MemFillReg, render_mode_reg::RenderModeReg, st0_st1_reg::St0St1Reg,
    stipple_pattern_reg::StipplePatternReg, tex_cfg_reg::TexCfgReg, vertex_reg::VertexReg,
    z_range_reg::ZRangeReg,
};

// ── Register addresses (7-bit index, matching INT-010) ───────────────────────

/// COLOR register: `[63:32]=color0 RGBA8888`, `[31:0]=color1 RGBA8888`.
pub const ADDR_COLOR: u8 = 0x00;

/// ST0/ST1 pre-divided texture coordinates (S=U/W, T=V/W).
pub const ADDR_ST0_ST1: u8 = 0x01;

/// VERTEX_NOKICK: store vertex + advance counter, no rasterization.
pub const ADDR_VERTEX_NOKICK: u8 = 0x06;

/// VERTEX_KICK_012: store vertex + trigger rasterization (0-1-2 winding).
pub const ADDR_VERTEX_KICK_012: u8 = 0x07;

/// VERTEX_KICK_021: store vertex + trigger rasterization (0-2-1 winding, reversed).
pub const ADDR_VERTEX_KICK_021: u8 = 0x08;

/// VERTEX_KICK_RECT: store vertex + trigger axis-aligned rectangle rasterization.
pub const ADDR_VERTEX_KICK_RECT: u8 = 0x09;

/// TEX0_CFG: texture unit 0 configuration.
pub const ADDR_TEX0_CFG: u8 = 0x10;

/// TEX1_CFG: texture unit 1 configuration.
pub const ADDR_TEX1_CFG: u8 = 0x11;

/// CC_MODE: color combiner equation configuration.
pub const ADDR_CC_MODE: u8 = 0x18;

/// CONST_COLOR: per-draw constant colors (CONST0 + CONST1).
pub const ADDR_CONST_COLOR: u8 = 0x19;

/// RENDER_MODE: unified rendering state (Z, alpha, cull, dither, stipple).
pub const ADDR_RENDER_MODE: u8 = 0x30;

/// Z_RANGE: depth range clipping (min/max).
pub const ADDR_Z_RANGE: u8 = 0x31;

/// STIPPLE_PATTERN: 8x8 stipple bitmask.
pub const ADDR_STIPPLE_PATTERN: u8 = 0x32;

/// FB_CONFIG: `[15:0]=color_base, [31:16]=z_base, [35:32]=width_log2, [39:36]=height_log2`.
pub const ADDR_FB_CONFIG: u8 = 0x40;

/// FB_DISPLAY: display scanout configuration.
pub const ADDR_FB_DISPLAY: u8 = 0x41;

/// FB_CONTROL: `[9:0]=scissor_x, [19:10]=scissor_y, [29:20]=scissor_w, [39:30]=scissor_h`.
pub const ADDR_FB_CONTROL: u8 = 0x43;

/// MEM_FILL: hardware memory fill (clear framebuffer/z-buffer).
pub const ADDR_MEM_FILL: u8 = 0x44;

/// PERF_TIMESTAMP: command-stream timestamp marker.
pub const ADDR_PERF_TIMESTAMP: u8 = 0x50;

/// MEM_ADDR: memory access dword address pointer.
pub const ADDR_MEM_ADDR: u8 = 0x70;

/// MEM_DATA: memory data register (bidirectional, auto-increment).
pub const ADDR_MEM_DATA: u8 = 0x71;

// ── GPU action enum ──────────────────────────────────────────────────────────

/// Action resulting from a register write, dispatched by the caller.
///
/// `RegisterFile::write()` returns this enum to tell the `Gpu` what
/// side-effect (if any) the write requires.  This keeps the register
/// model passive — it latches state and assembles data, but never
/// touches GPU memory or pipeline components directly.
pub enum GpuAction {
    /// Pure register latch — no further action needed.
    None,

    /// Triangle kick — vertices assembled, ready for `triangle_setup()`.
    KickTriangle(RasterTriangle),

    /// Hardware memory fill (REQ-005.08).
    MemFill {
        /// Fill-base register field (byte address = `base << 9`).
        base: u16,
        /// 16-bit fill value.
        value: u16,
        /// Number of 16-bit words to fill.
        count: usize,
    },

    /// Texture unit 0 config changed — invalidate cache / reconfigure sampler.
    Tex0Config(TexCfgReg),

    /// Texture unit 1 config changed — invalidate cache / reconfigure sampler.
    Tex1Config(TexCfgReg),

    /// Write 64-bit dword to SDRAM at the given dword address.
    ///
    /// The register file auto-increments MEM_ADDR after each write.
    MemData {
        /// 22-bit dword address (byte address = `dword_addr * 8`).
        dword_addr: u32,
        /// 64-bit data to write.
        data: u64,
    },
}

// ── RGBA8888 color helper ────────────────────────────────────────────────────

/// Unpack RGBA8888 as `[31:24]=R, [23:16]=G, [15:8]=B, [7:0]=A`.
///
/// Matches the RTL's decode in rasterizer.sv (v0_color0[31:24] = R, etc.).
#[derive(Debug, Clone, Copy, Default)]
pub struct Rgba8888(pub u32);

impl Rgba8888 {
    /// Extract the red channel (bits [31:24]).
    pub fn r(self) -> u8 {
        (self.0 >> 24) as u8
    }

    /// Extract the green channel (bits [23:16]).
    pub fn g(self) -> u8 {
        (self.0 >> 16) as u8
    }

    /// Extract the blue channel (bits [15:8]).
    pub fn b(self) -> u8 {
        (self.0 >> 8) as u8
    }

    /// Extract the alpha channel (bits [7:0]).
    pub fn a(self) -> u8 {
        self.0 as u8
    }
}

// ── Per-vertex data stored in the register file ──────────────────────────────

/// Raw register bundle latched per vertex, matching the RTL's vertex storage.
///
/// Triangle setup extracts typed values (Q12.4 coords, RGBA8888 colors, etc.)
/// from these registers — no pre-unpacking in the register file.
#[derive(Debug, Clone, Copy, Default)]
struct VertexSlot {
    /// VERTEX register: X/Y Q12.4, Z u16, Q u16.
    vertex: VertexReg,

    /// COLOR register: diffuse + specular RGBA8888.
    color: ColorReg,

    /// ST0_ST1 register: texture coordinates for units 0 and 1.
    st0_st1: St0St1Reg,
}

// ── Register file state ──────────────────────────────────────────────────────

/// GPU register file state, mirroring register_file.sv.
///
/// Maintains vertex buffers and internal pipeline state alongside
/// register latches using generated types from the `gpu-registers` crate.
#[derive(Default)]
pub struct RegisterFile {
    // ── Internal pipeline state (not registers) ──────────────────────────
    /// 3 vertex slots (filled by NOKICK/KICK writes).
    vertices: [VertexSlot; 3],

    /// Next vertex slot index (0, 1, 2, wraps).
    vertex_count: usize,

    // ── Register latches (generated types from gpu-registers) ────────────
    /// COLOR: per-vertex diffuse + specular colors (RGBA8888 each).
    color: ColorReg,

    /// ST0_ST1: pre-divided texture coordinates S=U/W, T=V/W (Q4.12 each).
    st0_st1: St0St1Reg,

    /// RENDER_MODE: unified rendering state flags.
    render_mode: RenderModeReg,

    /// Z_RANGE: depth range clipping (min/max).
    z_range: ZRangeReg,

    /// STIPPLE_PATTERN: 8x8 stipple bitmask.
    stipple_pattern: StipplePatternReg,

    /// FB_CONFIG: framebuffer dimensions and base addresses.
    fb_config: FbConfigReg,

    /// FB_CONTROL: scissor rectangle.
    fb_control: FbControlReg,

    /// FB_DISPLAY: display scanout configuration.
    fb_display: FbDisplayReg,

    /// TEX0_CFG: texture unit 0 configuration.
    tex0_cfg: TexCfgReg,

    /// TEX1_CFG: texture unit 1 configuration.
    tex1_cfg: TexCfgReg,

    /// CC_MODE: color combiner equation configuration.
    cc_mode: CcModeReg,

    /// CONST_COLOR: per-draw constant colors.
    const_color: ConstColorReg,

    /// MEM_ADDR: 22-bit dword address pointer for MEM_DATA access.
    mem_addr: u32,
}

impl RegisterFile {
    /// Process a single register write (addr + 64-bit data).
    ///
    /// This mirrors the RTL's register_file.sv combinational decode logic.
    /// Returns a `GpuAction` describing what side-effect (if any) the
    /// caller must execute.  The register file itself never touches GPU
    /// memory or pipeline components.
    ///
    /// # Arguments
    ///
    /// * `addr` - 7-bit register index.
    /// * `data` - 64-bit register data.
    ///
    /// # Returns
    ///
    /// A `GpuAction` for the caller to dispatch.
    pub fn write(&mut self, addr: u8, data: u64) -> GpuAction {
        match addr {
            ADDR_COLOR => {
                self.color = reg_from_raw(data);
                GpuAction::None
            }

            ADDR_ST0_ST1 => {
                self.st0_st1 = reg_from_raw(data);
                GpuAction::None
            }

            ADDR_VERTEX_NOKICK => {
                self.latch_vertex(data);
                self.vertex_count = (self.vertex_count + 1) % 3;
                GpuAction::None
            }

            ADDR_VERTEX_KICK_012 => {
                self.latch_vertex(data);
                self.vertex_count = (self.vertex_count + 1) % 3;
                GpuAction::KickTriangle(self.assemble_triangle(WindingOrder::V012))
            }

            ADDR_VERTEX_KICK_021 => {
                self.latch_vertex(data);
                self.vertex_count = (self.vertex_count + 1) % 3;
                GpuAction::KickTriangle(self.assemble_triangle(WindingOrder::V021))
            }

            ADDR_TEX0_CFG => {
                self.tex0_cfg = reg_from_raw(data);
                GpuAction::Tex0Config(self.tex0_cfg)
            }

            ADDR_TEX1_CFG => {
                self.tex1_cfg = reg_from_raw(data);
                GpuAction::Tex1Config(self.tex1_cfg)
            }

            ADDR_CC_MODE => {
                self.cc_mode = reg_from_raw(data);
                GpuAction::None
            }

            ADDR_CONST_COLOR => {
                self.const_color = reg_from_raw(data);
                GpuAction::None
            }

            ADDR_RENDER_MODE => {
                self.render_mode = reg_from_raw(data);
                GpuAction::None
            }

            ADDR_Z_RANGE => {
                self.z_range = reg_from_raw(data);
                GpuAction::None
            }

            ADDR_STIPPLE_PATTERN => {
                self.stipple_pattern = reg_from_raw(data);
                GpuAction::None
            }

            ADDR_FB_CONFIG => {
                self.fb_config = reg_from_raw(data);
                GpuAction::None
            }

            ADDR_FB_DISPLAY => {
                self.fb_display = reg_from_raw(data);
                GpuAction::None
            }

            ADDR_FB_CONTROL => {
                self.fb_control = reg_from_raw(data);
                GpuAction::None
            }

            ADDR_MEM_FILL => {
                let reg: MemFillReg = reg_from_raw(data);
                GpuAction::MemFill {
                    base: reg.fill_base(),
                    value: reg.fill_value(),
                    count: reg.fill_count() as usize,
                }
            }

            ADDR_MEM_ADDR => {
                let reg: gpu_registers::components::gpu_regs::named_types::mem_addr_reg::MemAddrReg =
                    reg_from_raw(data);
                self.mem_addr = reg.addr();
                GpuAction::None
            }

            ADDR_MEM_DATA => {
                let addr = self.mem_addr;
                self.mem_addr = self.mem_addr.wrapping_add(1) & 0x3F_FFFF;
                GpuAction::MemData {
                    dword_addr: addr,
                    data,
                }
            }

            _ => {
                // Unknown register — ignored (matches RTL default case)
                GpuAction::None
            }
        }
    }

    /// Latch current vertex data + color/ST into the current slot.
    ///
    /// Matches RTL register_file.sv ADDR_VERTEX_NOKICK decode:
    /// stores the VERTEX register data and snapshots the current
    /// COLOR and ST0_ST1 register latches.
    fn latch_vertex(&mut self, data: u64) {
        let slot = &mut self.vertices[self.vertex_count];
        slot.vertex = reg_from_raw(data);
        slot.color = self.color;
        slot.st0_st1 = self.st0_st1;
    }

    /// Assemble a `RasterTriangle` from the current vertex buffer state.
    ///
    /// Resolves the winding order into concrete vertex slot selection,
    /// computes scissor-clamped bounding box, and packs per-vertex
    /// attributes into `RasterVertex` values ready for `triangle_setup()`.
    fn assemble_triangle(&self, winding: WindingOrder) -> RasterTriangle {
        let kick_idx = if self.vertex_count == 0 {
            2
        } else {
            self.vertex_count - 1
        };
        let tri_slots = match winding {
            WindingOrder::V012 => [self.vertices[0], self.vertices[1], self.vertices[kick_idx]],
            WindingOrder::V021 => [self.vertices[0], self.vertices[kick_idx], self.vertices[1]],
        };

        let fb_width = 1u32 << self.fb_config.width_log2();
        let fb_height = 1u32 << self.fb_config.height_log2();

        // Scissor clamp for bounding box
        let scissor_max_x = self
            .fb_control
            .scissor_x()
            .saturating_add(self.fb_control.scissor_width())
            .min(fb_width as u16);
        let scissor_max_y = self
            .fb_control
            .scissor_y()
            .saturating_add(self.fb_control.scissor_height())
            .min(fb_height as u16);

        let make_vert = |s: &VertexSlot| {
            let v = &s.vertex;
            // COLOR register: [63:32] = diffuse RGBA8888, [31:0] = specular
            let color_raw = reg_to_raw(s.color);
            rasterize::RasterVertex {
                px: (v.x() >> 4) & 0x3FF,
                py: (v.y() >> 4) & 0x3FF,
                z: v.z(),
                q: v.q(),
                color0: Rgba8888((color_raw >> 32) as u32),
                color1: Rgba8888(color_raw as u32),
                s0: s.st0_st1.s0(),
                t0: s.st0_st1.t0(),
                s1: s.st0_st1.s1(),
                t1: s.st0_st1.t1(),
            }
        };

        RasterTriangle {
            verts: [
                make_vert(&tri_slots[0]),
                make_vert(&tri_slots[1]),
                make_vert(&tri_slots[2]),
            ],
            bbox_min_x: 0,
            bbox_max_x: scissor_max_x.saturating_sub(1),
            bbox_min_y: 0,
            bbox_max_y: scissor_max_y.saturating_sub(1),
            gouraud_en: self.render_mode.gouraud(),
        }
    }

    /// Access the FB_CONFIG register latch.
    pub fn fb_config(&self) -> FbConfigReg {
        self.fb_config
    }

    /// Access the FB_CONTROL register latch.
    pub fn fb_control(&self) -> FbControlReg {
        self.fb_control
    }

    /// Access the RENDER_MODE register latch.
    pub fn render_mode(&self) -> RenderModeReg {
        self.render_mode
    }

    /// Access the CC_MODE register latch.
    pub fn cc_mode(&self) -> CcModeReg {
        self.cc_mode
    }

    /// Access the CONST_COLOR register latch.
    pub fn const_color(&self) -> ConstColorReg {
        self.const_color
    }

    /// Access the Z_RANGE register latch.
    pub fn z_range(&self) -> ZRangeReg {
        self.z_range
    }

    /// Access the STIPPLE_PATTERN register latch.
    pub fn stipple_pattern(&self) -> StipplePatternReg {
        self.stipple_pattern
    }
}

/// Winding order for vertex kick.
pub enum WindingOrder {
    /// (slot[0], slot[1], just-latched) — standard CCW.
    V012,
    /// (slot[0], just-latched, slot[1]) — reversed for back-facing triangles.
    V021,
}

/// A single register write command (matching the RTL's 72-bit SPI frame).
#[derive(Debug, Clone, Copy)]
pub struct RegWrite {
    /// 7-bit register index (0..127).
    pub addr: u8,
    /// 64-bit register data.
    pub data: u64,
}
