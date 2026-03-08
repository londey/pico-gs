//! Register-write interface matching the RTL's register_file.sv.
//!
//! The GPU accepts 72-bit SPI frames: `{rw(1), addr(7), data(64)}`.
//! This module models the register file's state machine and vertex
//! buffering, decoding register writes into pipeline operations.
//!
//! # RTL Implementation Notes
//! The register file (UNIT-003) latches vertex positions, colors, and
//! UVs on VERTEX_NOKICK writes, advancing a vertex counter. A
//! VERTEX_KICK_012 write stores the final vertex and triggers
//! rasterization with winding order (0, 1, 2).
//!
//! # References
//! - INT-010 (GPU Register Map)
//! - UNIT-003 (Register File)
//! - INT-021 (Render Command Format)

use crate::mem::GpuMemory;
use crate::pipeline::rasterize;
use crate::reg_ext::{reg_from_raw, reg_to_raw};
use gpu_registers::components::gpu_regs::named_types::{
    cc_mode_reg::CcModeReg, color_reg::ColorReg, const_color_reg::ConstColorReg,
    fb_config_reg::FbConfigReg, fb_control_reg::FbControlReg, fb_display_reg::FbDisplayReg,
    render_mode_reg::RenderModeReg, stipple_pattern_reg::StipplePatternReg, tex_cfg_reg::TexCfgReg,
    uv0_uv1_reg::Uv0Uv1Reg, vertex_reg::VertexReg, z_range_reg::ZRangeReg,
};

// ── Register addresses (7-bit index, matching INT-010) ───────────────────────

/// COLOR register: `[63:32]=color0 RGBA8888`, `[31:0]=color1 RGBA8888`.
pub const ADDR_COLOR: u8 = 0x00;

/// UV0/UV1 texture coordinates.
pub const ADDR_UV0_UV1: u8 = 0x01;

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

#[derive(Debug, Clone, Copy, Default)]
struct VertexSlot {
    /// Screen X, Q12.4 raw 16-bit value from register write.
    x_raw: u16,

    /// Screen Y, Q12.4 raw 16-bit value from register write.
    y_raw: u16,

    /// Depth, unsigned 16-bit.
    z: u16,

    /// 1/W reciprocal, unsigned 16-bit.
    q: u16,

    /// Diffuse color (RGBA8888).
    color0: Rgba8888,

    /// Specular color (RGBA8888).
    color1: Rgba8888,

    /// UV0 packed (from UV0_UV1 register [31:0]).
    uv0: u32,

    /// UV1 packed (from UV0_UV1 register [63:32]).
    uv1: u32,
}

impl VertexSlot {
    /// Extract integer pixel X from Q12.4, matching RTL: `v0_x[13:4]`.
    fn pixel_x(&self) -> u16 {
        (self.x_raw >> 4) & 0x3FF
    }

    /// Extract integer pixel Y from Q12.4, matching RTL: `v0_y[13:4]`.
    fn pixel_y(&self) -> u16 {
        (self.y_raw >> 4) & 0x3FF
    }
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

    /// UV0_UV1: texture coordinates (Q4.12 each).
    uv0_uv1: Uv0Uv1Reg,

    /// RENDER_MODE: unified rendering state flags.
    pub render_mode: RenderModeReg,

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
}

impl RegisterFile {
    /// Process a single register write (addr + 64-bit data).
    ///
    /// This mirrors the RTL's register_file.sv combinational decode logic.
    /// On VERTEX_KICK_012, triggers rasterization and fragment processing.
    ///
    /// # Arguments
    ///
    /// * `addr` - 7-bit register index.
    /// * `data` - 64-bit register data.
    /// * `memory` - GPU memory state (framebuffer, Z-buffer) for fragment writes.
    pub fn write(&mut self, addr: u8, data: u64, memory: &mut GpuMemory) {
        match addr {
            ADDR_COLOR => {
                self.color = reg_from_raw(data);
            }

            ADDR_UV0_UV1 => {
                self.uv0_uv1 = reg_from_raw(data);
            }

            ADDR_VERTEX_NOKICK => {
                self.latch_vertex(data);
                self.vertex_count = (self.vertex_count + 1) % 3;
            }

            ADDR_VERTEX_KICK_012 => {
                self.latch_vertex(data);
                self.vertex_count = (self.vertex_count + 1) % 3;
                self.kick(WindingOrder::V012, memory);
            }

            ADDR_VERTEX_KICK_021 => {
                self.latch_vertex(data);
                self.vertex_count = (self.vertex_count + 1) % 3;
                self.kick(WindingOrder::V021, memory);
            }

            ADDR_TEX0_CFG => {
                self.tex0_cfg = reg_from_raw(data);
            }

            ADDR_TEX1_CFG => {
                self.tex1_cfg = reg_from_raw(data);
            }

            ADDR_CC_MODE => {
                self.cc_mode = reg_from_raw(data);
            }

            ADDR_CONST_COLOR => {
                self.const_color = reg_from_raw(data);
            }

            ADDR_RENDER_MODE => {
                self.render_mode = reg_from_raw(data);
            }

            ADDR_Z_RANGE => {
                self.z_range = reg_from_raw(data);
            }

            ADDR_STIPPLE_PATTERN => {
                self.stipple_pattern = reg_from_raw(data);
            }

            ADDR_FB_CONFIG => {
                self.fb_config = reg_from_raw(data);
            }

            ADDR_FB_DISPLAY => {
                self.fb_display = reg_from_raw(data);
            }

            ADDR_FB_CONTROL => {
                self.fb_control = reg_from_raw(data);
            }

            _ => {
                // Unknown register — ignored (matches RTL default case)
            }
        }
    }

    /// Latch current vertex data + color/UV into the current slot.
    ///
    /// Matches RTL register_file.sv ADDR_VERTEX_NOKICK decode:
    /// ```text
    /// next_vertex_x[vertex_count]      = cmd_wdata[15:0];
    /// next_vertex_y[vertex_count]      = cmd_wdata[31:16];
    /// next_vertex_z[vertex_count]      = cmd_wdata[47:32];
    /// next_vertex_q[vertex_count]      = cmd_wdata[63:48];
    /// next_vertex_color0[vertex_count] = current_color0[63:32];
    /// next_vertex_color1[vertex_count] = current_color0[31:0];
    /// ```
    fn latch_vertex(&mut self, data: u64) {
        let vreg: VertexReg = reg_from_raw(data);
        let slot = &mut self.vertices[self.vertex_count];
        slot.x_raw = vreg.x();
        slot.y_raw = vreg.y();
        slot.z = vreg.z();
        slot.q = vreg.q();
        // COLOR register: [63:32] = diffuse, [31:0] = specular
        let color_raw = reg_to_raw(self.color);
        slot.color0 = Rgba8888((color_raw >> 32) as u32);
        slot.color1 = Rgba8888((color_raw & 0xFFFF_FFFF) as u32);
        // UV0/UV1 from current latch
        let uv_raw = reg_to_raw(self.uv0_uv1);
        slot.uv0 = (uv_raw & 0xFFFF_FFFF) as u32;
        slot.uv1 = ((uv_raw >> 32) & 0xFFFF_FFFF) as u32;
    }

    /// Trigger rasterization with the given winding order.
    ///
    /// KICK_012: (slot[0], slot[1], just-latched) — CCW winding.
    /// KICK_021: (slot[0], just-latched, slot[1]) — reversed (CW→CCW).
    fn kick(&mut self, winding: WindingOrder, memory: &mut GpuMemory) {
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

        let make_vert = |s: &VertexSlot| rasterize::IntVertex {
            px: s.pixel_x(),
            py: s.pixel_y(),
            z: s.z,
            color0: s.color0,
        };

        let tri = rasterize::IntTriangle {
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
        };

        // Rasterize and write fragments with optional Z-test
        let fragments = rasterize::rasterize_int_triangle(&tri);
        let rm = &self.render_mode;
        for frag in &fragments {
            self.write_fragment(frag, rm, memory);
        }
    }

    /// Write a single fragment to the framebuffer with optional Z-test.
    fn write_fragment(
        &self,
        frag: &rasterize::IntFragment,
        rm: &RenderModeReg,
        memory: &mut GpuMemory,
    ) {
        let (fx, fy) = (frag.x as u32, frag.y as u32);
        if fx >= memory.framebuffer.width || fy >= memory.framebuffer.height {
            return;
        }

        // Early Z-test (matching early_z.sv)
        if rm.z_test_en() {
            if !memory.raw_zbuf.test_and_set(fx, fy, frag.z, rm.z_compare()) {
                return;
            }
        } else if rm.z_write_en() {
            memory.raw_zbuf.set(fx, fy, frag.z);
        }

        if rm.color_write_en() {
            memory.framebuffer.put_pixel(fx, fy, frag.color);
        }
    }
}

/// Winding order for vertex kick.
enum WindingOrder {
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
