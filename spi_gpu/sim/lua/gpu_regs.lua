-- gpu_regs.lua — GPU register helper functions for Verilator interactive simulator
--
-- Spec-ref: unit_037_verilator_interactive_sim.md `3247c7b012e2aedb` 2026-02-26
--
-- Implements REQ-010.02-LUA: one documented helper function per GPU register type.
-- Field packing matches registers/rdl/gpu_regs.rdl (register map v11.0).
--
-- Register index mapping (7-bit index, 64-bit data):
--   COLOR           = 0x00    UV0_UV1         = 0x01
--   VERTEX_NOKICK   = 0x06    VERTEX_KICK_012 = 0x07
--   VERTEX_KICK_021 = 0x08    TEX0_CFG        = 0x10
--   CC_MODE         = 0x18    CONST_COLOR     = 0x19
--   RENDER_MODE     = 0x30    Z_RANGE         = 0x31
--   FB_CONFIG       = 0x40    FB_DISPLAY      = 0x41
--   FB_CONTROL      = 0x43    MEM_FILL        = 0x44
--
-- Usage:
--   The sim app exposes gpu.write_reg(addr, data) as a C++ binding.
--   This script extends the gpu table with typed helper functions.
--   Load via: require "gpu_regs"

local gpu = gpu or {}

-- ============================================================================
-- Enumeration Constants
-- ============================================================================

--- Depth compare functions (RENDER_MODE.Z_COMPARE, bits [15:13]).
gpu.Z_COMPARE = {
    LESS     = 0,
    LEQUAL   = 1,
    EQUAL    = 2,
    GEQUAL   = 3,
    GREATER  = 4,
    NOTEQUAL = 5,
    ALWAYS   = 6,
    NEVER    = 7,
}

--- Alpha blend modes (RENDER_MODE.ALPHA_BLEND, bits [9:7]).
gpu.ALPHA_BLEND = {
    DISABLED = 0,
    ADD      = 1,
    SUBTRACT = 2,
    BLEND    = 3,
}

--- Backface cull modes (RENDER_MODE.CULL_MODE, bits [6:5]).
gpu.CULL_MODE = {
    NONE = 0,
    CW   = 1,
    CCW  = 2,
}

--- Texture formats (TEX0_CFG.FORMAT, bits [6:4]).
gpu.TEX_FORMAT = {
    BC1      = 0,
    BC2      = 1,
    BC3      = 2,
    BC4      = 3,
    RGB565   = 4,
    RGBA8888 = 5,
    R8       = 6,
}

--- Texture filter modes (TEX0_CFG.FILTER, bits [3:2]).
gpu.TEX_FILTER = {
    NEAREST   = 0,
    BILINEAR  = 1,
    TRILINEAR = 2,
}

--- UV wrap modes (TEX0_CFG.U_WRAP/V_WRAP, bits [17:16]/[19:18]).
gpu.WRAP_MODE = {
    REPEAT        = 0,
    CLAMP_TO_EDGE = 1,
    MIRROR        = 2,
    OCTAHEDRAL    = 3,
}

--- Color combiner input sources (cc_source_e, 4-bit).
--- Used for RGB A/B/D and all Alpha slots in CC_MODE.
gpu.CC_SRC = {
    COMBINED = 0,
    TEX0     = 1,
    TEX1     = 2,
    SHADE0   = 3,
    CONST0   = 4,
    CONST1   = 5,
    ONE      = 6,
    ZERO     = 7,
    SHADE1   = 8,
}

--- Alpha test functions (RENDER_MODE.ALPHA_TEST_FUNC, bits [18:17]).
gpu.ALPHA_TEST = {
    ALWAYS   = 0,
    LESS     = 1,
    GEQUAL   = 2,
    NOTEQUAL = 3,
}

--- Dither patterns (RENDER_MODE.DITHER_PATTERN, bits [12:11]).
gpu.DITHER_PATTERN = {
    BLUE_NOISE_16X16 = 0,
}

-- ============================================================================
-- Utility Functions
-- ============================================================================

--- Convert a floating-point value to Q12.4 signed fixed-point integer.
--- This is a convenience utility; the result is lossy for values outside
--- the representable range (-2048.0 to +2047.9375). Caller is responsible
--- for range checking.
--- @param f number Floating-point value
--- @return integer Q12.4 fixed-point integer (16-bit signed)
function gpu.f2q124(f)
    local v = math.floor(f * 16.0 + 0.5)
    -- Clamp to signed 16-bit range
    if v > 32767 then v = 32767 end
    if v < -32768 then v = -32768 end
    -- Convert to unsigned 16-bit representation for bit packing
    if v < 0 then v = v + 0x10000 end
    return v
end

--- Convert a floating-point value to S3.12 signed fixed-point integer.
--- Lossy for values outside the representable range (-8.0 to +7.999755859375).
--- @param f number Floating-point value
--- @return integer S3.12 fixed-point integer (16-bit signed)
function gpu.f2q312(f)
    local v = math.floor(f * 4096.0 + 0.5)
    if v > 32767 then v = 32767 end
    if v < -32768 then v = -32768 end
    if v < 0 then v = v + 0x10000 end
    return v
end

--- Mask a value to the given number of bits (unsigned).
--- @param val integer Input value
--- @param bits integer Number of bits
--- @return integer Masked value
local function mask(val, bits)
    return val & ((1 << bits) - 1)
end

-- ============================================================================
-- Register Helper Functions
-- ============================================================================

--- Write the COLOR register (index 0x00).
--- Packs two RGBA8888 vertex colors: COLOR0[31:0] + COLOR1[63:32].
--- Each component is a 0-255 integer (UNORM8).
--- @param r0 integer COLOR0 red   (0-255)
--- @param g0 integer COLOR0 green (0-255)
--- @param b0 integer COLOR0 blue  (0-255)
--- @param a0 integer COLOR0 alpha (0-255)
--- @param r1 integer COLOR1 red   (0-255)
--- @param g1 integer COLOR1 green (0-255)
--- @param b1 integer COLOR1 blue  (0-255)
--- @param a1 integer COLOR1 alpha (0-255)
function gpu.set_color(r0, g0, b0, a0, r1, g1, b1, a1)
    local data = mask(r0, 8)
               | (mask(g0, 8) << 8)
               | (mask(b0, 8) << 16)
               | (mask(a0, 8) << 24)
               | (mask(r1, 8) << 32)
               | (mask(g1, 8) << 40)
               | (mask(b1, 8) << 48)
               | (mask(a1, 8) << 56)
    gpu.write_reg(0x00, data)
end

--- Write the UV0_UV1 register (index 0x01).
--- Packs texture coordinates for units 0 and 1.
--- Each coordinate is a S3.12 signed fixed-point raw integer.
--- @param u0 integer UV0 U coordinate (S3.12 raw integer)
--- @param v0 integer UV0 V coordinate (S3.12 raw integer)
--- @param u1 integer UV1 U coordinate (S3.12 raw integer)
--- @param v1 integer UV1 V coordinate (S3.12 raw integer)
function gpu.set_uv0_uv1(u0, v0, u1, v1)
    local data = mask(u0, 16)
               | (mask(v0, 16) << 16)
               | (mask(u1, 16) << 32)
               | (mask(v1, 16) << 48)
    gpu.write_reg(0x01, data)
end

--- Write vertex data to a vertex register (shared implementation).
--- X,Y are Q12.4 signed fixed-point integers; Z is unsigned 16-bit;
--- Q is S3.12 signed fixed-point (1/W).
--- @param addr integer Register index
--- @param x integer X position (Q12.4 raw integer)
--- @param y integer Y position (Q12.4 raw integer)
--- @param z integer Z depth (unsigned 16-bit)
--- @param q integer 1/W (S3.12 raw integer)
local function write_vertex(addr, x, y, z, q)
    local data = mask(x, 16)
               | (mask(y, 16) << 16)
               | (mask(z, 16) << 32)
               | (mask(q, 16) << 48)
    gpu.write_reg(addr, data)
end

--- Write the VERTEX_NOKICK register (index 0x06).
--- Buffers vertex position without triggering rasterization.
--- X,Y are Q12.4 signed fixed-point; Z is unsigned 16-bit; Q is S3.12.
--- @param x integer X position (Q12.4 raw integer)
--- @param y integer Y position (Q12.4 raw integer)
--- @param z integer Z depth (unsigned 16-bit)
--- @param q integer 1/W reciprocal (S3.12 raw integer)
function gpu.set_vertex_nokick(x, y, z, q)
    write_vertex(0x06, x, y, z, q)
end

--- Write the VERTEX_KICK_012 register (index 0x07).
--- Submits vertex and triggers triangle rasterization (v0, v1, v2 winding).
--- X,Y are Q12.4 signed fixed-point; Z is unsigned 16-bit; Q is S3.12.
--- @param x integer X position (Q12.4 raw integer)
--- @param y integer Y position (Q12.4 raw integer)
--- @param z integer Z depth (unsigned 16-bit)
--- @param q integer 1/W reciprocal (S3.12 raw integer)
function gpu.set_vertex_kick_012(x, y, z, q)
    write_vertex(0x07, x, y, z, q)
end

--- Write the VERTEX_KICK_021 register (index 0x08).
--- Submits vertex and triggers triangle rasterization (v0, v2, v1 winding).
--- X,Y are Q12.4 signed fixed-point; Z is unsigned 16-bit; Q is S3.12.
--- @param x integer X position (Q12.4 raw integer)
--- @param y integer Y position (Q12.4 raw integer)
--- @param z integer Z depth (unsigned 16-bit)
--- @param q integer 1/W reciprocal (S3.12 raw integer)
function gpu.set_vertex_kick_021(x, y, z, q)
    write_vertex(0x08, x, y, z, q)
end

--- Write the RENDER_MODE register (index 0x30).
--- Accepts a table of named options; unspecified fields default to 0/disabled.
---
--- Field bit assignments (from gpu_regs.rdl):
---   [0]     GOURAUD         [2]     Z_TEST_EN       [3]     Z_WRITE_EN
---   [4]     COLOR_WRITE_EN  [6:5]   CULL_MODE       [9:7]   ALPHA_BLEND
---   [10]    DITHER_EN       [12:11] DITHER_PATTERN   [15:13] Z_COMPARE
---   [16]    STIPPLE_EN      [18:17] ALPHA_TEST_FUNC  [26:19] ALPHA_REF
---
--- @param opts table|nil Options table with named fields:
---   gouraud        (boolean)  Enable Gouraud shading
---   z_test         (boolean)  Enable depth test
---   z_write        (boolean)  Enable depth buffer write
---   color_write    (boolean)  Enable color buffer write
---   cull_mode      (integer)  gpu.CULL_MODE.* enum value (default NONE)
---   alpha_blend    (integer)  gpu.ALPHA_BLEND.* enum value (default DISABLED)
---   dither         (boolean)  Enable dithering
---   dither_pattern (integer)  gpu.DITHER_PATTERN.* enum value (default BLUE_NOISE_16X16)
---   z_compare      (integer)  gpu.Z_COMPARE.* enum value (default LESS)
---   stipple        (boolean)  Enable stipple test
---   alpha_test     (integer)  gpu.ALPHA_TEST.* enum value (default ALWAYS)
---   alpha_ref      (integer)  Alpha reference value 0-255
function gpu.set_render_mode(opts)
    opts = opts or {}
    local data = 0
    if opts.gouraud     then data = data | (1 << 0)  end
    -- bit 1 is reserved
    if opts.z_test      then data = data | (1 << 2)  end
    if opts.z_write     then data = data | (1 << 3)  end
    if opts.color_write then data = data | (1 << 4)  end
    data = data | (mask(opts.cull_mode      or 0, 2) << 5)
    data = data | (mask(opts.alpha_blend    or 0, 3) << 7)
    if opts.dither      then data = data | (1 << 10) end
    data = data | (mask(opts.dither_pattern or 0, 2) << 11)
    data = data | (mask(opts.z_compare      or 0, 3) << 13)
    if opts.stipple     then data = data | (1 << 16) end
    data = data | (mask(opts.alpha_test     or 0, 2) << 17)
    data = data | (mask(opts.alpha_ref      or 0, 8) << 19)
    gpu.write_reg(0x30, data)
end

--- Write the Z_RANGE register (index 0x31).
--- Sets depth range clipping (Z scissor) min/max values.
--- @param z_min integer Minimum Z value (unsigned 16-bit, default 0x0000)
--- @param z_max integer Maximum Z value (unsigned 16-bit, default 0xFFFF)
function gpu.set_z_range(z_min, z_max)
    z_min = z_min or 0x0000
    z_max = z_max or 0xFFFF
    local data = mask(z_min, 16)
               | (mask(z_max, 16) << 16)
    gpu.write_reg(0x31, data)
end

--- Write the FB_CONFIG register (index 0x40).
--- Configures render target color/Z-buffer base addresses and surface dimensions.
--- Base addresses use 512-byte granularity (address >> 9).
--- @param color_base integer Color buffer base address in 512-byte units (16-bit)
--- @param z_base integer Z-buffer base address in 512-byte units (16-bit)
--- @param width_log2 integer Surface width as log2(pixels), e.g. 9 for 512
--- @param height_log2 integer Surface height as log2(pixels), e.g. 9 for 512
function gpu.set_fb_config(color_base, z_base, width_log2, height_log2)
    local data = mask(color_base, 16)
               | (mask(z_base, 16) << 16)
               | (mask(width_log2, 4) << 32)
               | (mask(height_log2, 4) << 36)
    gpu.write_reg(0x40, data)
end

--- Write the FB_CONTROL register (index 0x43).
--- Sets the scissor rectangle for fragment clipping.
--- @param scissor_x integer Scissor X origin (10-bit, 0-1023)
--- @param scissor_y integer Scissor Y origin (10-bit, 0-1023)
--- @param scissor_width integer Scissor width (10-bit, 0-1023)
--- @param scissor_height integer Scissor height (10-bit, 0-1023)
function gpu.set_fb_control(scissor_x, scissor_y, scissor_width, scissor_height)
    local data = mask(scissor_x, 10)
               | (mask(scissor_y, 10) << 10)
               | (mask(scissor_width, 10) << 20)
               | (mask(scissor_height, 10) << 30)
    gpu.write_reg(0x43, data)
end

--- Write the FB_DISPLAY register (index 0x41).
--- Configures display scanout; write blocks until next vsync.
--- Base addresses use 512-byte granularity (address >> 9).
--- @param opts table|nil Options table with named fields:
---   color_grade (boolean)  Enable color grading LUT
---   line_double (boolean)  Enable line doubling (240 source rows -> 480 display)
---   lut_addr    (integer)  LUT base address in 512-byte units (16-bit)
---   fb_addr     (integer)  Framebuffer base address in 512-byte units (16-bit)
---   fb_width_log2 (integer) Display FB width as log2(pixels)
function gpu.set_fb_display(opts)
    opts = opts or {}
    local data = 0
    if opts.color_grade then data = data | (1 << 0) end
    if opts.line_double then data = data | (1 << 1) end
    data = data | (mask(opts.lut_addr      or 0, 16) << 16)
    data = data | (mask(opts.fb_addr       or 0, 16) << 32)
    data = data | (mask(opts.fb_width_log2 or 0, 4)  << 48)
    gpu.write_reg(0x41, data)
end

--- Write the TEX0_CFG register (index 0x10).
--- Full texture unit 0 configuration.
---
--- Field bit assignments (from gpu_regs.rdl):
---   [0]     ENABLE      [3:2]   FILTER       [6:4]   FORMAT
---   [11:8]  WIDTH_LOG2  [15:12] HEIGHT_LOG2  [17:16] U_WRAP
---   [19:18] V_WRAP      [23:20] MIP_LEVELS   [47:32] BASE_ADDR
---
--- @param opts table Options table with named fields:
---   enable      (boolean)  Enable texture unit
---   filter      (integer)  gpu.TEX_FILTER.* enum value
---   format      (integer)  gpu.TEX_FORMAT.* enum value
---   width_log2  (integer)  Texture width as log2(pixels)
---   height_log2 (integer)  Texture height as log2(pixels)
---   u_wrap      (integer)  gpu.WRAP_MODE.* enum value
---   v_wrap      (integer)  gpu.WRAP_MODE.* enum value
---   mip_levels  (integer)  Number of mipmap levels
---   base_addr   (integer)  Base address in 512-byte units (16-bit)
function gpu.set_tex0_cfg(opts)
    opts = opts or {}
    local data = 0
    if opts.enable then data = data | (1 << 0) end
    data = data | (mask(opts.filter      or 0, 2) << 2)
    data = data | (mask(opts.format      or 0, 3) << 4)
    data = data | (mask(opts.width_log2  or 0, 4) << 8)
    data = data | (mask(opts.height_log2 or 0, 4) << 12)
    data = data | (mask(opts.u_wrap      or 0, 2) << 16)
    data = data | (mask(opts.v_wrap      or 0, 2) << 18)
    data = data | (mask(opts.mip_levels  or 0, 4) << 20)
    data = data | (mask(opts.base_addr   or 0, 16) << 32)
    gpu.write_reg(0x10, data)
end

--- Write the TEX0_CFG register (index 0x10) with only the FORMAT field set.
--- Convenience function for the common single-format use case.
--- Sets ENABLE=1 and the specified format; all other fields at reset values (0).
--- @param format integer Texture format (gpu.TEX_FORMAT.* enum value)
function gpu.set_tex0_fmt(format)
    local data = (1 << 0)                     -- ENABLE = 1
               | (mask(format or 0, 3) << 4)  -- FORMAT
    gpu.write_reg(0x10, data)
end

--- Write the CC_MODE register (index 0x18).
--- Configures the two-stage color combiner equation: result = (A - B) * C + D.
--- Each source is a 4-bit enum value from gpu.CC_SRC.
---
--- Field bit assignments (from gpu_regs.rdl):
---   Cycle 0: [3:0] RGB_A, [7:4] RGB_B, [11:8] RGB_C, [15:12] RGB_D,
---            [19:16] ALPHA_A, [23:20] ALPHA_B, [27:24] ALPHA_C, [31:28] ALPHA_D
---   Cycle 1: [35:32] RGB_A, [39:36] RGB_B, [43:40] RGB_C, [47:44] RGB_D,
---            [51:48] ALPHA_A, [55:52] ALPHA_B, [59:56] ALPHA_C, [63:60] ALPHA_D
---
--- @param opts table Options table with named fields:
---   c0_rgb_a   (integer)  Cycle 0 RGB A source
---   c0_rgb_b   (integer)  Cycle 0 RGB B source
---   c0_rgb_c   (integer)  Cycle 0 RGB C source (extended cc_rgb_c_source_e)
---   c0_rgb_d   (integer)  Cycle 0 RGB D source
---   c0_alpha_a (integer)  Cycle 0 Alpha A source
---   c0_alpha_b (integer)  Cycle 0 Alpha B source
---   c0_alpha_c (integer)  Cycle 0 Alpha C source
---   c0_alpha_d (integer)  Cycle 0 Alpha D source
---   c1_rgb_a   (integer)  Cycle 1 RGB A source
---   c1_rgb_b   (integer)  Cycle 1 RGB B source
---   c1_rgb_c   (integer)  Cycle 1 RGB C source (extended cc_rgb_c_source_e)
---   c1_rgb_d   (integer)  Cycle 1 RGB D source
---   c1_alpha_a (integer)  Cycle 1 Alpha A source
---   c1_alpha_b (integer)  Cycle 1 Alpha B source
---   c1_alpha_c (integer)  Cycle 1 Alpha C source
---   c1_alpha_d (integer)  Cycle 1 Alpha D source
function gpu.set_cc_mode(opts)
    opts = opts or {}
    local data = 0
    -- Cycle 0
    data = data | (mask(opts.c0_rgb_a   or 0, 4) << 0)
    data = data | (mask(opts.c0_rgb_b   or 0, 4) << 4)
    data = data | (mask(opts.c0_rgb_c   or 0, 4) << 8)
    data = data | (mask(opts.c0_rgb_d   or 0, 4) << 12)
    data = data | (mask(opts.c0_alpha_a or 0, 4) << 16)
    data = data | (mask(opts.c0_alpha_b or 0, 4) << 20)
    data = data | (mask(opts.c0_alpha_c or 0, 4) << 24)
    data = data | (mask(opts.c0_alpha_d or 0, 4) << 28)
    -- Cycle 1
    data = data | (mask(opts.c1_rgb_a   or 0, 4) << 32)
    data = data | (mask(opts.c1_rgb_b   or 0, 4) << 36)
    data = data | (mask(opts.c1_rgb_c   or 0, 4) << 40)
    data = data | (mask(opts.c1_rgb_d   or 0, 4) << 44)
    data = data | (mask(opts.c1_alpha_a or 0, 4) << 48)
    data = data | (mask(opts.c1_alpha_b or 0, 4) << 52)
    data = data | (mask(opts.c1_alpha_c or 0, 4) << 56)
    data = data | (mask(opts.c1_alpha_d or 0, 4) << 60)
    gpu.write_reg(0x18, data)
end

--- Write the CONST_COLOR register (index 0x19).
--- Packs two RGBA8888 constant colors: CONST0[31:0] + CONST1[63:32].
--- CONST1 doubles as the fog color. Each component is 0-255 (UNORM8).
--- @param r0 integer CONST0 red   (0-255)
--- @param g0 integer CONST0 green (0-255)
--- @param b0 integer CONST0 blue  (0-255)
--- @param a0 integer CONST0 alpha (0-255)
--- @param r1 integer CONST1 red   (0-255)
--- @param g1 integer CONST1 green (0-255)
--- @param b1 integer CONST1 blue  (0-255)
--- @param a1 integer CONST1 alpha (0-255)
function gpu.set_const_color(r0, g0, b0, a0, r1, g1, b1, a1)
    local data = mask(r0, 8)
               | (mask(g0, 8) << 8)
               | (mask(b0, 8) << 16)
               | (mask(a0, 8) << 24)
               | (mask(r1, 8) << 32)
               | (mask(g1, 8) << 40)
               | (mask(b1, 8) << 48)
               | (mask(a1, 8) << 56)
    gpu.write_reg(0x19, data)
end

--- Write the MEM_FILL register (index 0x44).
--- Triggers a hardware memory fill. Blocks the GPU pipeline until complete.
--- @param fill_base integer Target address in 512-byte units (16-bit)
--- @param fill_value integer 16-bit constant value (RGB565 or Z16)
--- @param fill_count integer Number of 16-bit words to fill (20-bit, up to 1048576)
function gpu.set_mem_fill(fill_base, fill_value, fill_count)
    local data = mask(fill_base, 16)
               | (mask(fill_value, 16) << 16)
               | (mask(fill_count, 20) << 32)
    gpu.write_reg(0x44, data)
end

-- ============================================================================
-- Example Usage (comment block)
-- ============================================================================
--[[
-- Render a Gouraud-shaded triangle (320x240 framebuffer, no textures)
--
-- 1. Configure framebuffer
gpu.set_fb_config(0, 0x0800, 9, 8)  -- color at 0, Z at 0x0800, 512x256
gpu.set_fb_control(0, 0, 320, 240)  -- scissor to 320x240
gpu.set_z_range(0x0000, 0xFFFF)     -- full depth range

-- 2. Clear color buffer (black) and Z-buffer (far plane)
gpu.set_mem_fill(0, 0x0000, 320*240)       -- clear color to black
gpu.set_mem_fill(0x0800, 0xFFFF, 320*240)  -- clear Z to far

-- 3. Set render mode: Gouraud + Z test + Z write + color write
gpu.set_render_mode({
    gouraud     = true,
    z_test      = true,
    z_write     = true,
    color_write = true,
    z_compare   = gpu.Z_COMPARE.LESS,
})

-- 4. Set color combiner: pass through shade color (single cycle)
--    Cycle 0: result = (SHADE0 - ZERO) * ONE + ZERO = SHADE0
--    Cycle 1: pass-through = (COMBINED - ZERO) * ONE + ZERO
gpu.set_cc_mode({
    c0_rgb_a   = gpu.CC_SRC.SHADE0,
    c0_rgb_b   = gpu.CC_SRC.ZERO,
    c0_rgb_c   = gpu.CC_SRC.ONE,
    c0_rgb_d   = gpu.CC_SRC.ZERO,
    c0_alpha_a = gpu.CC_SRC.SHADE0,
    c0_alpha_b = gpu.CC_SRC.ZERO,
    c0_alpha_c = gpu.CC_SRC.ONE,
    c0_alpha_d = gpu.CC_SRC.ZERO,
    c1_rgb_a   = gpu.CC_SRC.COMBINED,
    c1_rgb_b   = gpu.CC_SRC.ZERO,
    c1_rgb_c   = gpu.CC_SRC.ONE,
    c1_rgb_d   = gpu.CC_SRC.ZERO,
    c1_alpha_a = gpu.CC_SRC.COMBINED,
    c1_alpha_b = gpu.CC_SRC.ZERO,
    c1_alpha_c = gpu.CC_SRC.ONE,
    c1_alpha_d = gpu.CC_SRC.ZERO,
})

-- 5. Submit triangle vertices (Q12.4 for X/Y, unsigned 16-bit for Z)
-- Vertex 0: red, top-center
gpu.set_color(255, 0, 0, 255, 0, 0, 0, 255)
gpu.set_vertex_nokick(gpu.f2q124(160), gpu.f2q124(40), 0x8000, gpu.f2q312(1.0))

-- Vertex 1: green, bottom-left
gpu.set_color(0, 255, 0, 255, 0, 0, 0, 255)
gpu.set_vertex_nokick(gpu.f2q124(80), gpu.f2q124(200), 0x8000, gpu.f2q312(1.0))

-- Vertex 2: blue, bottom-right — kick triggers rasterization
gpu.set_color(0, 0, 255, 255, 0, 0, 0, 255)
gpu.set_vertex_kick_012(gpu.f2q124(240), gpu.f2q124(200), 0x8000, gpu.f2q312(1.0))

-- 6. Present frame
gpu.set_fb_display({ fb_addr = 0, fb_width_log2 = 9 })
gpu.wait_vsync()
--]]

return gpu
