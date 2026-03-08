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

// ── Register addresses (7-bit index, matching INT-010) ───────────────────────

/// COLOR register: `[63:32]=color0 RGBA8888`, `[31:0]=color1 RGBA8888`.
pub const ADDR_COLOR: u8 = 0x00;

/// UV0/UV1 texture coordinates.
pub const ADDR_UV0_UV1: u8 = 0x01;

/// VERTEX_NOKICK: store vertex + advance counter, no rasterization.
pub const ADDR_VERTEX_NOKICK: u8 = 0x06;

/// VERTEX_KICK_012: store vertex + trigger rasterization (0-1-2 winding).
pub const ADDR_VERTEX_KICK_012: u8 = 0x07;

/// RENDER_MODE: `[0]=GOURAUD_EN, [2]=Z_TEST_EN, [3]=Z_WRITE_EN, [4]=COLOR_WRITE_EN`.
pub const ADDR_RENDER_MODE: u8 = 0x30;

/// FB_CONFIG: `[15:0]=color_base, [31:16]=z_base, [35:32]=width_log2, [39:36]=height_log2`.
pub const ADDR_FB_CONFIG: u8 = 0x40;

/// FB_CONTROL: `[9:0]=scissor_x, [19:10]=scissor_y, [29:20]=scissor_w, [39:30]=scissor_h`.
pub const ADDR_FB_CONTROL: u8 = 0x43;

/// MEM_FILL: hardware memory fill (clear framebuffer/z-buffer).
pub const ADDR_MEM_FILL: u8 = 0x44;

// ── RGBA8888 color helper ────────────────────────────────────────────────────

/// Unpack RGBA8888 as `[31:24]=R, [23:16]=G, [15:8]=B, [7:0]=A`.
///
/// Matches the RTL's decode in rasterizer.sv (v0_color0[31:24] = R, etc.).
#[derive(Debug, Clone, Copy, Default)]
pub struct Rgba8888(pub u32);

impl Rgba8888 {
    pub fn r(self) -> u8 {
        (self.0 >> 24) as u8
    }
    pub fn g(self) -> u8 {
        (self.0 >> 16) as u8
    }
    pub fn b(self) -> u8 {
        (self.0 >> 8) as u8
    }
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

// ── Render mode flags ────────────────────────────────────────────────────────

/// Render mode register bit fields (from INT-010 / register_file.sv).
#[derive(Debug, Clone, Copy, Default)]
pub struct RenderMode {
    pub gouraud_en: bool,
    pub z_test_en: bool,
    pub z_write_en: bool,
    pub color_write_en: bool,
}

impl RenderMode {
    fn from_bits(data: u64) -> Self {
        Self {
            gouraud_en: (data & (1 << 0)) != 0,
            z_test_en: (data & (1 << 2)) != 0,
            z_write_en: (data & (1 << 3)) != 0,
            color_write_en: (data & (1 << 4)) != 0,
        }
    }
}

// ── Scissor rectangle ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub struct Scissor {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}

impl Default for Scissor {
    fn default() -> Self {
        Self {
            x: 0,
            y: 0,
            width: 0,
            height: 0,
        }
    }
}

// ── Register file state ──────────────────────────────────────────────────────

/// GPU register file state, mirroring register_file.sv.
///
/// Maintains vertex buffers, current color/UV latches, framebuffer
/// configuration, render mode, and scissor state.
pub struct RegisterFile {
    /// 3 vertex slots (filled by NOKICK/KICK writes).
    vertices: [VertexSlot; 3],
    /// Next vertex slot index (0, 1, 2, wraps).
    vertex_count: usize,
    /// Current color0/color1 latch (from COLOR register write).
    current_color0: u64,
    /// Current UV0/UV1 latch (from UV0_UV1 register write).
    current_uv01: u64,

    /// Framebuffer surface width (log2, e.g. 9 → 512 pixels).
    pub fb_width_log2: u8,
    /// Framebuffer surface height (log2).
    pub fb_height_log2: u8,
    /// Color buffer base address (×512 byte units).
    pub fb_color_base: u16,
    /// Z buffer base address (×512 byte units).
    pub fb_z_base: u16,

    /// Scissor rectangle.
    pub scissor: Scissor,

    /// Render mode flags.
    pub render_mode: RenderMode,
}

impl Default for RegisterFile {
    fn default() -> Self {
        Self {
            vertices: [VertexSlot::default(); 3],
            vertex_count: 0,
            current_color0: 0,
            current_uv01: 0,
            fb_width_log2: 0,
            fb_height_log2: 0,
            fb_color_base: 0,
            fb_z_base: 0,
            scissor: Scissor::default(),
            render_mode: RenderMode::default(),
        }
    }
}

impl RegisterFile {
    /// Process a single register write (addr + 64-bit data).
    ///
    /// This mirrors the RTL's register_file.sv combinational decode logic.
    /// On VERTEX_KICK_012, triggers rasterization and fragment processing.
    pub fn write(&mut self, addr: u8, data: u64, memory: &mut GpuMemory) {
        match addr {
            ADDR_COLOR => {
                self.current_color0 = data;
            }

            ADDR_UV0_UV1 => {
                self.current_uv01 = data;
            }

            ADDR_VERTEX_NOKICK => {
                self.latch_vertex(data);
                self.vertex_count = (self.vertex_count + 1) % 3;
            }

            ADDR_VERTEX_KICK_012 => {
                self.latch_vertex(data);
                self.vertex_count = (self.vertex_count + 1) % 3;
                self.kick_012(memory);
            }

            ADDR_RENDER_MODE => {
                self.render_mode = RenderMode::from_bits(data);
            }

            ADDR_FB_CONFIG => {
                self.fb_color_base = (data & 0xFFFF) as u16;
                self.fb_z_base = ((data >> 16) & 0xFFFF) as u16;
                self.fb_width_log2 = ((data >> 32) & 0xF) as u8;
                self.fb_height_log2 = ((data >> 36) & 0xF) as u8;
            }

            ADDR_FB_CONTROL => {
                self.scissor = Scissor {
                    x: (data & 0x3FF) as u16,
                    y: ((data >> 10) & 0x3FF) as u16,
                    width: ((data >> 20) & 0x3FF) as u16,
                    height: ((data >> 30) & 0x3FF) as u16,
                };
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
        let slot = &mut self.vertices[self.vertex_count];
        slot.x_raw = (data & 0xFFFF) as u16;
        slot.y_raw = ((data >> 16) & 0xFFFF) as u16;
        slot.z = ((data >> 32) & 0xFFFF) as u16;
        slot.q = ((data >> 48) & 0xFFFF) as u16;
        // COLOR register: [63:32] = diffuse, [31:0] = specular
        slot.color0 = Rgba8888((self.current_color0 >> 32) as u32);
        slot.color1 = Rgba8888((self.current_color0 & 0xFFFF_FFFF) as u32);
        // UV0/UV1 from current latch
        slot.uv0 = (self.current_uv01 & 0xFFFF_FFFF) as u32;
        slot.uv1 = ((self.current_uv01 >> 32) & 0xFFFF_FFFF) as u32;
    }

    /// Trigger rasterization with winding order (0, 1, 2).
    ///
    /// Matches RTL register_file.sv ADDR_VERTEX_KICK_012:
    /// - tri[0] = vertex_slot[0]
    /// - tri[1] = vertex_slot[1]
    /// - tri[2] = current vertex data (just latched)
    fn kick_012(&mut self, memory: &mut GpuMemory) {
        // Build the rasterizer input triangle from the 3 vertex slots
        // Note: KICK_012 outputs (slot[0], slot[1], just-latched).
        // The just-latched vertex was stored at vertex_count-1 (before increment).
        let kick_idx = if self.vertex_count == 0 { 2 } else { self.vertex_count - 1 };
        let tri_slots = [
            self.vertices[0],
            self.vertices[1],
            self.vertices[kick_idx],
        ];

        let fb_width = 1u32 << self.fb_width_log2;
        let fb_height = 1u32 << self.fb_height_log2;

        // Scissor clamp for bounding box
        let scissor_max_x = self.scissor.x.saturating_add(self.scissor.width).min(fb_width as u16);
        let scissor_max_y = self.scissor.y.saturating_add(self.scissor.height).min(fb_height as u16);

        // Build integer-pixel triangle for the rasterizer
        let tri = rasterize::IntTriangle {
            verts: [
                rasterize::IntVertex {
                    px: tri_slots[0].pixel_x(),
                    py: tri_slots[0].pixel_y(),
                    z: tri_slots[0].z,
                    color0: tri_slots[0].color0,
                },
                rasterize::IntVertex {
                    px: tri_slots[1].pixel_x(),
                    py: tri_slots[1].pixel_y(),
                    z: tri_slots[1].z,
                    color0: tri_slots[1].color0,
                },
                rasterize::IntVertex {
                    px: tri_slots[2].pixel_x(),
                    py: tri_slots[2].pixel_y(),
                    z: tri_slots[2].z,
                    color0: tri_slots[2].color0,
                },
            ],
            bbox_min_x: 0,
            bbox_max_x: scissor_max_x.saturating_sub(1),
            bbox_min_y: 0,
            bbox_max_y: scissor_max_y.saturating_sub(1),
            gouraud_en: self.render_mode.gouraud_en,
        };

        // Rasterize and write fragments
        let fragments = rasterize::rasterize_int_triangle(&tri);
        for frag in &fragments {
            if frag.x as u32 >= memory.framebuffer.width
                || frag.y as u32 >= memory.framebuffer.height
            {
                continue;
            }

            if self.render_mode.color_write_en {
                memory
                    .framebuffer
                    .put_pixel(frag.x as u32, frag.y as u32, frag.color);
            }
        }
    }
}

/// A single register write command (matching the RTL's 72-bit SPI frame).
#[derive(Debug, Clone, Copy)]
pub struct RegWrite {
    /// 7-bit register index (0..127).
    pub addr: u8,
    /// 64-bit register data.
    pub data: u64,
}
