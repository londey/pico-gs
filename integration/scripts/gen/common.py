"""Common helpers for GPU test script hex generation.

Register addresses, data packing functions, and hex line emitters shared
by all VER-NNN generators.  The packing math is identical to the C++
helpers in ver_010_gouraud.cpp and the Rust helpers in integration.rs.
"""

from __future__ import annotations

import struct
from typing import List

# ---------------------------------------------------------------------------
# INT-010 Register Addresses (from register_file.sv / gpu_regs.rdl)
# ---------------------------------------------------------------------------

ADDR_COLOR = 0x00
ADDR_ST0_ST1 = 0x01
ADDR_VERTEX_NOKICK = 0x06
ADDR_VERTEX_KICK_012 = 0x07
ADDR_VERTEX_KICK_021 = 0x08
ADDR_TEX0_CFG = 0x10
ADDR_CC_MODE = 0x18
ADDR_CC_MODE_2 = 0x1A
ADDR_RENDER_MODE = 0x30
ADDR_FB_CONFIG = 0x40
ADDR_FB_CONTROL = 0x43
ADDR_MEM_FILL = 0x44
ADDR_STIPPLE_PATTERN = 0x32
ADDR_MEM_ADDR = 0x70
ADDR_MEM_DATA = 0x71

# Human-readable register names for comments
REG_NAMES = {
    0x00: "COLOR",
    0x01: "ST0_ST1",
    0x06: "VERTEX_NOKICK",
    0x07: "VERTEX_KICK_012",
    0x08: "VERTEX_KICK_021",
    0x10: "TEX0_CFG",
    0x18: "CC_MODE",
    0x1A: "CC_MODE_2",
    0x30: "RENDER_MODE",
    0x40: "FB_CONFIG",
    0x43: "FB_CONTROL",
    0x44: "MEM_FILL",
    0x32: "STIPPLE_PATTERN",
    0x70: "MEM_ADDR",
    0x71: "MEM_DATA",
}

# ---------------------------------------------------------------------------
# Texture format codes (matching TexFormatE in gpu_regs.rdl)
# ---------------------------------------------------------------------------

TEX_FMT_BC1 = 0
TEX_FMT_BC2 = 1
TEX_FMT_BC3 = 2
TEX_FMT_BC4 = 3
# 4 is reserved (BC5 removed)
TEX_FMT_RGB565 = 5
TEX_FMT_RGBA8888 = 6
TEX_FMT_R8 = 7

# ---------------------------------------------------------------------------
# RENDER_MODE bit definitions
# ---------------------------------------------------------------------------

GOURAUD_EN = 1 << 0
Z_TEST_EN = 1 << 2
Z_WRITE_EN = 1 << 3
COLOR_WRITE_EN = 1 << 4
STIPPLE_EN = 1 << 16

# Z compare function codes (3-bit, shifted to bits [15:13])
Z_COMPARE_LESS = 0 << 13
Z_COMPARE_LEQUAL = 1 << 13
Z_COMPARE_EQUAL = 2 << 13
Z_COMPARE_GEQUAL = 3 << 13
Z_COMPARE_GREATER = 4 << 13
Z_COMPARE_NOTEQUAL = 5 << 13
Z_COMPARE_ALWAYS = 6 << 13
Z_COMPARE_NEVER = 7 << 13


# ---------------------------------------------------------------------------
# CC_MODE presets
#
# Equation: (A - B) * C + D, independent RGB and alpha.
# Per-cycle layout (32-bit):
#   [3:0]=A  [7:4]=B  [11:8]=C  [15:12]=D  (RGB)
#   [19:16]=A  [23:20]=B  [27:24]=C  [31:28]=D  (Alpha)
# Full register: [63:32]=cycle1  [31:0]=cycle0
# ---------------------------------------------------------------------------

# SHADE_PASSTHROUGH: output = SHADE0 (vertex color)
#   Cycle 0: A=SHADE0(3), B=ZERO(7), C=ONE(6), D=ZERO(7)
#   Cycle 1: A=COMBINED(0), B=ZERO(7), C=ONE(6), D=ZERO(7)
CC_MODE_SHADE_PASSTHROUGH = 0x7670_7670_7673_7673

# MODULATE: output = TEX0 * SHADE0
#   Cycle 0: A=TEX0(1), B=ZERO(7), C=SHADE0(3), D=ZERO(7)
#   Cycle 1: A=COMBINED(0), B=ZERO(7), C=ONE(6), D=ZERO(7)
CC_MODE_MODULATE = 0x7670_7670_7371_7371

# SHADE_PREMUL_ALPHA: pre-multiply RGB by SHADE0_ALPHA in cycle 0.
#   Cycle 0 RGB:   A=SHADE0(3), B=ZERO(7), C=SHADE0_ALPHA(0xA), D=ZERO(7)
#   Cycle 0 Alpha: A=SHADE0(3), B=ZERO(7), C=ONE(6),            D=ZERO(7)
#   Cycle 1: passthrough COMBINED
# Useful for alpha blending tests where the source color should fade
# with its own alpha value.
CC_MODE_SHADE_PREMUL_ALPHA = 0x7670_7670_7673_7A73


# ---------------------------------------------------------------------------
# CC_MODE_2 presets (pass 2 / blend stage)
#
# Equation: (A - B) * C + D  with CcSourceE selectors for A/B/D and
# CcRgbCSourceE selectors for the RGB C position.
# Field layout (32-bit):
#   [3:0]=A_rgb  [7:4]=B_rgb  [11:8]=C_rgb  [15:12]=D_rgb
#   [19:16]=A_a  [23:20]=B_a  [27:24]=C_a  [31:28]=D_a
# All templates leave the alpha channel as pass-through
# (A=COMBINED(0), B=ZERO(7), C=ONE(6), D=ZERO(7)) -> 0x7670.
# ---------------------------------------------------------------------------

# DISABLED: RGB pass-through (COMBINED-ZERO)*ONE+ZERO.
CC_MODE_2_DISABLED = 0x7670_7670

# PREMUL_OVERWRITE: (COMBINED-ZERO)*COMBINED_ALPHA + ZERO = src*alpha.
# Source is pre-multiplied by its own alpha and overwrites the destination.
# Useful for tests that want to show an alpha fade without any blend math.
#   RGB: A=COMBINED(0) B=ZERO(7) C=COMBINED_ALPHA(0xC) D=ZERO(7)
CC_MODE_2_PREMUL_OVERWRITE = 0x7670_7C70

# ADD: (COMBINED-ZERO)*COMBINED_ALPHA + DST_COLOR = src*alpha + dst.
#   RGB: A=COMBINED(0) B=ZERO(7) C=COMBINED_ALPHA(0xC) D=DST_COLOR(9)
CC_MODE_2_ADD = 0x7670_9C70

# SUBTRACT: (ZERO-COMBINED)*COMBINED_ALPHA + DST_COLOR = dst - src*alpha.
#   RGB: A=ZERO(7) B=COMBINED(0) C=COMBINED_ALPHA(0xC) D=DST_COLOR(9)
CC_MODE_2_SUBTRACT = 0x7670_9C07

# BLEND (Porter-Duff source-over): (COMBINED-DST_COLOR)*COMBINED_ALPHA + DST_COLOR
#   = src*alpha + dst*(1-alpha).
#   RGB: A=COMBINED(0) B=DST_COLOR(9) C=COMBINED_ALPHA(0xC) D=DST_COLOR(9)
CC_MODE_2_BLEND = 0x7670_9C90


# ---------------------------------------------------------------------------
# Data packing helpers
# ---------------------------------------------------------------------------

def rgba(r: int, g: int, b: int, a: int = 0xFF) -> int:
    """Pack RGBA8888 color: {R[31:24], G[23:16], B[15:8], A[7:0]}."""
    return (r << 24) | (g << 16) | (b << 8) | a


def pack_color(diffuse: int, specular: int = 0xFF000000) -> int:
    """Pack COLOR register: diffuse in [63:32], specular in [31:0]."""
    return ((diffuse & 0xFFFFFFFF) << 32) | (specular & 0xFFFFFFFF)


# Q field value for affine (non-perspective) texture mapping.
# Q is encoded as UQ1.15: value = raw / 32768.
# Q=0x8000 means 1.0, so recip_q produces 1.0 in UQ4.14, passing UVs
# through unchanged.
Q_AFFINE = 0x8000


def q_perspective(w: float) -> int:
    """Encode Q = 1/W as UQ1.15 for the VERTEX register Q field.

    UQ1.15: 1 integer bit, 15 fractional bits, 16 bits total.
    Value = raw / 32768.  Range [0, ~2.0).
    """
    q_val = 1.0 / w
    raw = int(round(q_val * 32768.0))
    return max(0, min(0xFFFF, raw))


def pack_st_perspective(u: float, v: float, w: float) -> int:
    """Pack ST0_ST1 with perspective-divided texture coordinates.

    Writes S=U/W, T=V/W as Q4.12.  ST1 is zero (TEX1 not used).
    """
    return pack_st(u / w, v / w)


def pack_vertex(x: int, y: int, z: int, q: int = 0) -> int:
    """Pack VERTEX register from integer pixel coordinates.

    X, Y are converted to Q12.4 (multiply by 16).
    Z is 16-bit unsigned.
    Q is UQ1.15 (1/W); use Q_AFFINE for textured triangles without
    perspective correction.
    """
    x_q4 = (x * 16) & 0xFFFF
    y_q4 = (y * 16) & 0xFFFF
    z = z & 0xFFFF
    q = q & 0xFFFF
    return (q << 48) | (z << 32) | (y_q4 << 16) | x_q4


def pack_vertex_q4(x_q4: int, y_q4: int, z: int, q: int = 0) -> int:
    """Pack VERTEX register from Q12.4 fixed-point coordinates directly."""
    x_q4 = x_q4 & 0xFFFF
    y_q4 = y_q4 & 0xFFFF
    z = z & 0xFFFF
    q = q & 0xFFFF
    return (q << 48) | (z << 32) | (y_q4 << 16) | x_q4


def pack_fb_config(color_base: int, z_base: int,
                   width_log2: int, height_log2: int) -> int:
    """Pack FB_CONFIG register.

    color_base, z_base: in 512-byte units.
    width_log2, height_log2: log2 of surface dimensions.
    """
    return (
        ((height_log2 & 0xF) << 36) |
        ((width_log2 & 0xF) << 32) |
        ((z_base & 0xFFFF) << 16) |
        (color_base & 0xFFFF)
    )


def pack_mem_fill(base_word: int, value: int, count: int) -> int:
    """Pack MEM_FILL register.

    base_word: target word address (byte_addr = base_word * 2), 24-bit.
    value: 16-bit constant to write (RGB565 or Z16).
    count: number of 16-bit words to fill.
    """
    return (
        ((count & 0xFFFFF) << 40) |
        ((value & 0xFFFF) << 24) |
        (base_word & 0xFFFFFF)
    )


def pack_fb_control(x: int, y: int, width: int, height: int) -> int:
    """Pack FB_CONTROL (scissor) register."""
    return (
        ((height & 0x3FF) << 30) |
        ((width & 0x3FF) << 20) |
        ((y & 0x3FF) << 10) |
        (x & 0x3FF)
    )


def pack_st(u0: float, v0: float) -> int:
    """Pack ST0_ST1 register.  ST1 is zero (TEX1 not used).

    Q4.12 encoding: value * 4096.  Range +/-8.0.
    """
    def to_q4_12(val: float) -> int:
        fixed = int(val * 4096.0)
        return fixed & 0xFFFF

    u_packed = to_q4_12(u0)
    v_packed = to_q4_12(v0)
    return (v_packed << 16) | u_packed


def pack_tex0_cfg(enable: int, filt: int, fmt: int,
                  width_log2: int, height_log2: int,
                  u_wrap: int, v_wrap: int, mip_levels: int,
                  base_addr_512: int) -> int:
    """Pack TEX0_CFG register."""
    return (
        (enable & 0x1) |
        ((filt & 0x3) << 2) |
        ((fmt & 0xF) << 4) |
        ((width_log2 & 0xF) << 8) |
        ((height_log2 & 0xF) << 12) |
        ((u_wrap & 0x3) << 16) |
        ((v_wrap & 0x3) << 18) |
        ((mip_levels & 0xF) << 20) |
        ((base_addr_512 & 0xFFFF) << 32)
    )


# ---------------------------------------------------------------------------
# Hex file emitters
# ---------------------------------------------------------------------------

def fmt_data(data: int) -> str:
    """Format 64-bit data as 16 hex chars with underscore separators."""
    raw = f"{data:016X}"
    # Group as 4-char chunks: XXXX_XXXX_XXXX_XXXX
    return f"{raw[0:4]}_{raw[4:8]}_{raw[8:12]}_{raw[12:16]}"


def emit(addr: int, data: int, comment: str = "") -> str:
    """Format one register-write line: '<addr> <data>  # <comment>'."""
    reg_name = REG_NAMES.get(addr, f"REG_0x{addr:02X}")
    full_comment = f"{reg_name}: {comment}" if comment else reg_name
    return f"{addr:02X} {fmt_data(data)}  # {full_comment}"


def emit_phase(name: str) -> str:
    """Emit a phase directive line."""
    return f"## PHASE: {name}"


def emit_framebuffer(width: int, height: int) -> str:
    """Emit a framebuffer dimension directive line."""
    return f"## FRAMEBUFFER: {width} {height}"


def emit_texture(tex_type: str, base_hex: str,
                 fmt: str, width_log2: int) -> str:
    """Emit a texture pre-load directive line."""
    return f"## TEXTURE: {tex_type} base=0x{base_hex} format={fmt} width_log2={width_log2}"


def emit_comment(text: str) -> str:
    """Emit a comment line."""
    return f"# {text}"


def emit_blank() -> str:
    """Emit a blank line."""
    return ""


def render_mode_comment(mode: int) -> str:
    """Decode RENDER_MODE value into human-readable flag list."""
    flags = []
    if mode & GOURAUD_EN:
        flags.append("GOURAUD_EN")
    if mode & Z_TEST_EN:
        flags.append("Z_TEST_EN")
    if mode & Z_WRITE_EN:
        flags.append("Z_WRITE_EN")
    if mode & COLOR_WRITE_EN:
        flags.append("COLOR_WRITE_EN")
    if mode & STIPPLE_EN:
        flags.append("STIPPLE_EN")
    z_cmp = (mode >> 13) & 0x7
    cmp_names = ["LESS", "LEQUAL", "EQUAL", "GEQUAL",
                 "GREATER", "NOTEQUAL", "ALWAYS", "NEVER"]
    if z_cmp != 0 or (mode & Z_TEST_EN):
        flags.append(f"Z_COMPARE={cmp_names[z_cmp]}")
    return " | ".join(flags) if flags else "NONE"


def color_name(rgba_val: int) -> str:
    """Return a short name for common RGBA8888 colors."""
    names = {
        0xFF0000FF: "red",
        0x00FF00FF: "green",
        0x0000FFFF: "blue",
        0xFFFFFFFF: "white",
        0x000000FF: "black",
        0xFF000000: "black(A=0)",
        0x00000000: "zero",
    }
    if rgba_val in names:
        return names[rgba_val]
    r = (rgba_val >> 24) & 0xFF
    g = (rgba_val >> 16) & 0xFF
    b = (rgba_val >> 8) & 0xFF
    a = rgba_val & 0xFF
    return f"({r},{g},{b},{a})"


def color_comment(diffuse: int, specular: int) -> str:
    """Format COLOR register comment with decoded channel values."""
    return f"diffuse={color_name(diffuse)} specular={color_name(specular)}"


def mem_fill_comment(base_word: int, value: int, count: int) -> str:
    """Format MEM_FILL register comment."""
    return f"base_word=0x{base_word:06X} value=0x{value:04X} count={count}"


def emit_fb_clear(color_base_512: int, w_log2: int, h_log2: int,
                  value: int = 0x0000) -> List[str]:
    """Emit MEM_FILL to clear the color framebuffer.

    Clears (1 << w_log2) * (1 << h_log2) words at the given base.
    color_base_512: base address in 512-byte units (converted to word address).
    """
    count = (1 << w_log2) * (1 << h_log2)
    base_word = color_base_512 * 256  # 512 bytes = 256 words
    lines = []
    lines.append(emit_comment(f"Clear color buffer: base_word=0x{base_word:06X}"
                               f" value=0x{value:04X} count={count}"))
    lines.append(emit(ADDR_MEM_FILL,
                       pack_mem_fill(base_word, value, count),
                       mem_fill_comment(base_word, value, count)))
    return lines


def vertex_comment_q4(x_q4: int, y_q4: int, z: int, q: int | None = None) -> str:
    """Format VERTEX comment from Q12.4 coords."""
    x_px = x_q4 / 16.0
    y_px = y_q4 / 16.0
    x_str = f"{x_px:g}"
    y_str = f"{y_px:g}"
    base = f"x={x_str} y={y_str} z=0x{z:04X}"
    if q is not None:
        return f"{base} q=0x{q:04X}"
    return base


def vertex_comment(x: int, y: int, z: int) -> str:
    """Format VERTEX comment from integer pixel coords."""
    return f"x={x} y={y} z=0x{z:04X}"


def st_comment(u: float, v: float) -> str:
    """Format ST0_ST1 comment."""
    return f"s0={u:g} t0={v:g}"


def st_persp_comment(u: float, v: float, w: float) -> str:
    """Format ST0_ST1 comment for perspective-divided coordinates."""
    return f"s0={u / w:g} t0={v / w:g} (u={u:g} v={v:g} w={w:.3f})"


def tiled_word_addr(base_word: int, width_log2: int, x: int, y: int) -> int:
    """Compute SDRAM word address for (x, y) in a 4x4 block-tiled surface.

    Mirrors the DT's mem::tiled_word_addr function (INT-011).
    """
    block_x = x >> 2
    block_y = y >> 2
    local_x = x & 3
    local_y = y & 3
    block_idx = (block_y << (width_log2 - 2)) | block_x
    return base_word + block_idx * 16 + local_y * 4 + local_x


def emit_checker_texture(base_word: int, width_log2: int,
                         color_a: int, color_b: int,
                         label: str = "checker") -> List[str]:
    """Emit MEM_ADDR + MEM_DATA writes to upload a checker texture.

    Generates a per-texel checkerboard in 4x4 block-tiled layout.
    Uses MEM_DATA (64-bit, 4 words per write) with auto-increment.

    base_word: SDRAM word address of texture (e.g. 0x80000).
    width_log2: log2 of texture dimension (square, e.g. 4 for 16x16).
    color_a: RGB565 color for even texels (x+y even).
    color_b: RGB565 color for odd texels (x+y odd).
    """
    size = 1 << width_log2
    total_words = size * size
    total_dwords = total_words // 4

    # Build flat word array in tiled order.
    words = [0] * total_words
    for y in range(size):
        for x in range(size):
            addr = tiled_word_addr(0, width_log2, x, y)
            color = color_a if (x + y) % 2 == 0 else color_b
            words[addr] = color

    # Set MEM_ADDR to the dword address of the texture base.
    dword_addr = base_word // 4
    lines = []
    lines.append(emit_comment(f"Upload {size}x{size} {label} texture at word 0x{base_word:05X}"))
    lines.append(emit(ADDR_MEM_ADDR, dword_addr,
                       f"dword_addr=0x{dword_addr:05X}"))

    # Write 64-bit dwords (4 words each), auto-incrementing.
    for i in range(total_dwords):
        w0 = words[i * 4 + 0]
        w1 = words[i * 4 + 1]
        w2 = words[i * 4 + 2]
        w3 = words[i * 4 + 3]
        data = w0 | (w1 << 16) | (w2 << 32) | (w3 << 48)
        lines.append(emit(ADDR_MEM_DATA, data, f"dwords[{i}]"))

    return lines


# RGB565 color constants for checker textures
RGB565_WHITE = 0xFFFF
RGB565_BLACK = 0x0000
RGB565_MID_GRAY = 0x7BEF  # (15,31,15) ≈ 50% gray


def write_hex_file(path: str, lines: List[str]) -> None:
    """Write lines to a .hex file with trailing newline."""
    with open(path, 'w') as f:
        for line in lines:
            f.write(line + '\n')
