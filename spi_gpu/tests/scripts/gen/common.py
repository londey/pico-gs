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
ADDR_UV0_UV1 = 0x01
ADDR_VERTEX_NOKICK = 0x06
ADDR_VERTEX_KICK_012 = 0x07
ADDR_VERTEX_KICK_021 = 0x08
ADDR_TEX0_CFG = 0x10
ADDR_CC_MODE = 0x18
ADDR_RENDER_MODE = 0x30
ADDR_FB_CONFIG = 0x40
ADDR_FB_CONTROL = 0x43
ADDR_MEM_FILL = 0x44

# Human-readable register names for comments
REG_NAMES = {
    0x00: "COLOR",
    0x01: "UV0_UV1",
    0x06: "VERTEX_NOKICK",
    0x07: "VERTEX_KICK_012",
    0x08: "VERTEX_KICK_021",
    0x10: "TEX0_CFG",
    0x18: "CC_MODE",
    0x30: "RENDER_MODE",
    0x40: "FB_CONFIG",
    0x43: "FB_CONTROL",
    0x44: "MEM_FILL",
}

# ---------------------------------------------------------------------------
# RENDER_MODE bit definitions
# ---------------------------------------------------------------------------

GOURAUD_EN = 1 << 0
Z_TEST_EN = 1 << 2
Z_WRITE_EN = 1 << 3
COLOR_WRITE_EN = 1 << 4

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
# Data packing helpers
# ---------------------------------------------------------------------------

def rgba(r: int, g: int, b: int, a: int = 0xFF) -> int:
    """Pack RGBA8888 color: {R[31:24], G[23:16], B[15:8], A[7:0]}."""
    return (r << 24) | (g << 16) | (b << 8) | a


def pack_color(diffuse: int, specular: int = 0xFF000000) -> int:
    """Pack COLOR register: diffuse in [63:32], specular in [31:0]."""
    return ((diffuse & 0xFFFFFFFF) << 32) | (specular & 0xFFFFFFFF)


def pack_vertex(x: int, y: int, z: int) -> int:
    """Pack VERTEX register from integer pixel coordinates.

    X, Y are converted to Q12.4 (multiply by 16).
    Z is 16-bit unsigned.  Q (1/W) is set to 0.
    """
    x_q4 = (x * 16) & 0xFFFF
    y_q4 = (y * 16) & 0xFFFF
    z = z & 0xFFFF
    q = 0
    return (q << 48) | (z << 32) | (y_q4 << 16) | x_q4


def pack_vertex_q4(x_q4: int, y_q4: int, z: int) -> int:
    """Pack VERTEX register from Q12.4 fixed-point coordinates directly."""
    x_q4 = x_q4 & 0xFFFF
    y_q4 = y_q4 & 0xFFFF
    z = z & 0xFFFF
    q = 0
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


def pack_fb_control(x: int, y: int, width: int, height: int) -> int:
    """Pack FB_CONTROL (scissor) register."""
    return (
        ((height & 0x3FF) << 30) |
        ((width & 0x3FF) << 20) |
        ((y & 0x3FF) << 10) |
        (x & 0x3FF)
    )


def pack_uv(u0: float, v0: float) -> int:
    """Pack UV0_UV1 register.  UV1 is zero (TEX1 not used).

    Q1.15 encoding: value * 32768.
    """
    def to_q1_15(val: float) -> int:
        fixed = int(val * 32768.0)
        # Match C++ int16_t cast: wrap and mask to unsigned 16-bit
        return fixed & 0xFFFF

    u_packed = to_q1_15(u0)
    v_packed = to_q1_15(v0)
    return (v_packed << 16) | u_packed


def pack_tex0_cfg(enable: int, filt: int, fmt: int,
                  width_log2: int, height_log2: int,
                  u_wrap: int, v_wrap: int, mip_levels: int,
                  base_addr_512: int) -> int:
    """Pack TEX0_CFG register."""
    return (
        (enable & 0x1) |
        ((filt & 0x3) << 2) |
        ((fmt & 0x7) << 4) |
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


def vertex_comment_q4(x_q4: int, y_q4: int, z: int) -> str:
    """Format VERTEX comment from Q12.4 coords."""
    x_px = x_q4 / 16.0
    y_px = y_q4 / 16.0
    x_str = f"{x_px:g}"
    y_str = f"{y_px:g}"
    return f"x={x_str} y={y_str} z=0x{z:04X}"


def vertex_comment(x: int, y: int, z: int) -> str:
    """Format VERTEX comment from integer pixel coords."""
    return f"x={x} y={y} z=0x{z:04X}"


def uv_comment(u: float, v: float) -> str:
    """Format UV0_UV1 comment."""
    return f"u0={u:g} v0={v:g}"


def write_hex_file(path: str, lines: List[str]) -> None:
    """Write lines to a .hex file with trailing newline."""
    with open(path, 'w') as f:
        for line in lines:
            f.write(line + '\n')
