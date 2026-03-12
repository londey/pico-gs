"""VER-014: Textured Cube Golden Image Test — hex generator.

12-triangle cube (6 faces × 2 triangles) with depth testing and
white/black checker texture.  Each face has a distinct diffuse color.
All faces are submitted (no back-face culling); the Z-buffer resolves
visibility.  Each triangle is submitted as 3 independent vertices
(nokick, nokick, kick_012).

Three phases: zclear, setup, triangles.
"""

import math

from common import *
from transforms import (
    mat4_identity, mat4_mul, mat4_mul_vec4, mat4_rotate_x, mat4_rotate_y,
    mat4_look_at, mat4_perspective, perspective_divide, viewport_transform,
)
# Perspective-correct texturing: use pack_st_perspective, q_perspective from common

ZBUFFER_BASE_512 = 0x0800
# Place texture after the Z-buffer to avoid overlap.
# Color FB: 0x0000..0x03FF (512x512 = 256K words)
# Z-buffer: 0x0800..0x0BFF (512x512 = 256K words)
# Texture:  0x0C00 onwards
TEX0_BASE_ADDR_512 = 0x0C00
TEX0_BASE_WORD = 0x0C00 * 256

# ---------------------------------------------------------------------------
# Unit cube definition (model space)
# ---------------------------------------------------------------------------

# 8 vertices of a unit cube centered at the origin.
CUBE_VERTS = [
    (-1, -1, -1),  # 0: left  bottom back
    ( 1, -1, -1),  # 1: right bottom back
    ( 1,  1, -1),  # 2: right top    back
    (-1,  1, -1),  # 3: left  top    back
    (-1, -1,  1),  # 4: left  bottom front
    ( 1, -1,  1),  # 5: right bottom front
    ( 1,  1,  1),  # 6: right top    front
    (-1,  1,  1),  # 7: left  top    front
]

# 6 faces, each defined as (vertex_indices, uv_coords, diffuse_color).
# Indices are ordered for CCW front-facing when viewed from outside.
# UV corners map the checker texture across each face.
# Colors chosen so visible faces (+Z front, -X left, -Y bottom) are distinct.
CUBE_FACES = [
    # +Z front face (v4, v5, v6, v7)
    {"name": "+Z (front)",  "quad": (4, 5, 6, 7),
     "uv": ((0, 0), (1, 0), (1, 1), (0, 1)),
     "color": (0x00, 0x00, 0xFF)},       # blue
    # -Z back face (v1, v0, v3, v2) — reversed winding viewed from -Z
    {"name": "-Z (back)",   "quad": (1, 0, 3, 2),
     "uv": ((0, 0), (1, 0), (1, 1), (0, 1)),
     "color": (0xFF, 0xFF, 0x00)},       # yellow
    # +X right face (v5, v1, v2, v6)
    {"name": "+X (right)",  "quad": (5, 1, 2, 6),
     "uv": ((0, 0), (1, 0), (1, 1), (0, 1)),
     "color": (0xFF, 0x00, 0x00)},       # red
    # -X left face (v0, v4, v7, v3)
    {"name": "-X (left)",   "quad": (0, 4, 7, 3),
     "uv": ((0, 0), (1, 0), (1, 1), (0, 1)),
     "color": (0x00, 0xFF, 0xFF)},       # cyan
    # +Y top face (v7, v6, v2, v3)
    {"name": "+Y (top)",    "quad": (7, 6, 2, 3),
     "uv": ((0, 0), (1, 0), (1, 1), (0, 1)),
     "color": (0x00, 0xFF, 0x00)},       # green
    # -Y bottom face (v0, v1, v5, v4)
    {"name": "-Y (bottom)", "quad": (0, 1, 5, 4),
     "uv": ((0, 0), (1, 0), (1, 1), (0, 1)),
     "color": (0xFF, 0x00, 0xFF)},       # magenta
]


def _zclear_phase() -> list[str]:
    """Z-buffer clear via MEM_FILL (REQ-005.08)."""
    lines = []
    lines.append(emit_phase("zclear"))
    lines.append(emit_blank())

    # Clear color buffer
    lines.extend(emit_fb_clear(0x0000, 9, 9))
    lines.append(emit_blank())

    # Clear Z-buffer to 0x0000 (reverse-Z: far plane = 0)
    fill_count = 512 * 512  # 1 << 9 * 1 << 9
    lines.append(emit(ADDR_MEM_FILL,
                       pack_mem_fill(ZBUFFER_BASE_512 * 256, 0x0000, fill_count),
                       mem_fill_comment(ZBUFFER_BASE_512 * 256, 0x0000, fill_count)))

    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, ZBUFFER_BASE_512, 9, 9),
                       "color_base=0x0000 z_base=0x0800 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 512),
                       "scissor x=0 y=0 w=512 h=512"))
    return lines


def _setup_phase() -> list[str]:
    """Configure texture and render mode for depth-tested textured rendering."""
    lines = []
    lines.append(emit_phase("setup"))
    lines.append(emit_blank())

    # Upload 16x16 white/black checker texture
    lines.extend(emit_checker_texture(TEX0_BASE_WORD, 4,
                                       RGB565_WHITE, RGB565_BLACK,
                                       "white/black checker"))
    lines.append(emit_blank())

    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, ZBUFFER_BASE_512, 9, 9),
                       "color_base=0x0000 z_base=0x0800 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 512),
                       "scissor x=0 y=0 w=512 h=512"))

    tex_cfg = pack_tex0_cfg(1, 0, 4, 4, 4, 0, 0, 0, TEX0_BASE_ADDR_512)
    lines.append(emit(ADDR_TEX0_CFG, tex_cfg,
                       "ENABLE=1 NEAREST RGB565 16x16 REPEAT base=0x0C00"))

    lines.append(emit(ADDR_CC_MODE, CC_MODE_MODULATE,
                       "MODULATE: cycle0=TEX0*SHADE0 cycle1=COMBINED*ONE"))

    mode = GOURAUD_EN | Z_TEST_EN | Z_WRITE_EN | COLOR_WRITE_EN | Z_COMPARE_GEQUAL
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))

    lines.append(emit_blank())
    lines.append(emit(ADDR_COLOR, 0, "dummy NOP (FIFO FWFT workaround)"))
    return lines


def _emit_tri(lines, verts, diffuse):
    """Emit one textured triangle as 3 independent vertices (NK, NK, KICK_012).

    verts: [(sx_q4, sy_q4, z16, u, v, w), ...] — 3 vertices.
    diffuse: (r, g, b) tuple.
    """
    shade = rgba(diffuse[0], diffuse[1], diffuse[2])
    spec = rgba(0x00, 0x00, 0x00)

    for i, (sx, sy, z16, u, v, w) in enumerate(verts):
        q = q_perspective(w)
        lines.append(emit(ADDR_COLOR, pack_color(shade, spec),
                           color_comment(shade, spec)))
        lines.append(emit(ADDR_ST0_ST1, pack_st_perspective(u, v, w),
                           st_persp_comment(u, v, w)))
        addr = ADDR_VERTEX_KICK_012 if (i == 2) else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex_q4(sx, sy, z16, q),
                           vertex_comment_q4(sx, sy, z16, q)))


def _triangles_phase() -> list[str]:
    """Transform and emit all cube triangles via MVP pipeline."""
    lines = []
    lines.append(emit_phase("triangles"))
    lines.append(emit_blank())

    # --- Build MVP matrix ---
    # Model: gentle rotation to show +Z front, -X left, -Y bottom.
    model = mat4_mul(mat4_rotate_y(math.radians(25)),
                     mat4_rotate_x(math.radians(20)))

    # View: camera looking at origin from +Z.
    view = mat4_look_at(eye=(0, 0, 5), center=(0, 0, 0), up=(0, 1, 0))

    # Projection: perspective, 45° vertical FOV, square aspect.
    proj = mat4_perspective(math.radians(45), 1.0, 1.0, 100.0)

    mvp = mat4_mul(proj, mat4_mul(view, model))

    # Viewport dimensions.
    vp_w, vp_h = 512.0, 512.0

    # --- Transform all 8 cube vertices ---
    screen_verts = []  # (sx_q4, sy_q4, z16, w)
    for vx, vy, vz in CUBE_VERTS:
        clip = mat4_mul_vec4(mvp, (vx, vy, vz, 1.0))
        ndc_x, ndc_y, ndc_z, w = perspective_divide(clip)
        sx, sy, sz = viewport_transform(ndc_x, ndc_y, ndc_z, vp_w, vp_h)

        # Pack to GPU formats.
        sx_q4 = int(round(sx * 16.0))  # Q12.4
        sy_q4 = int(round(sy * 16.0))  # Q12.4
        z16 = int(round(sz * 65535.0))  # 16-bit unsigned
        z16 = max(0, min(0xFFFF, z16))

        screen_verts.append((sx_q4, sy_q4, z16, w))

    # --- Emit all faces (no back-face cull; Z-test resolves visibility) ---
    # Each quad is split into two independent triangles (0,1,2) and (0,2,3).
    for face in CUBE_FACES:
        i0, i1, i2, i3 = face["quad"]
        uv = face["uv"]
        color = face["color"]

        lines.append(emit_comment(f"Face: {face['name']}"))

        # Triangle 1: (v0, v1, v2)
        tri1 = []
        for idx, (u, v) in [(i0, uv[0]), (i1, uv[1]), (i2, uv[2])]:
            sv = screen_verts[idx]
            tri1.append((sv[0], sv[1], sv[2], u, v, sv[3]))
        _emit_tri(lines, tri1, color)
        lines.append(emit_blank())

        # Triangle 2: (v0, v2, v3)
        tri2 = []
        for idx, (u, v) in [(i0, uv[0]), (i2, uv[2]), (i3, uv[3])]:
            sv = screen_verts[idx]
            tri2.append((sv[0], sv[1], sv[2], u, v, sv[3]))
        _emit_tri(lines, tri2, color)
        lines.append(emit_blank())

    lines.append(emit(ADDR_COLOR, 0, "dummy NOP (FIFO FWFT workaround)"))
    return lines


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-014: Textured Cube Golden Image Test"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("12-triangle cube with per-face color, depth testing, checker texture."))
    lines.append(emit_comment("Phase 'zclear': initialize Z-buffer to 0x0000 (reverse-Z far)"))
    lines.append(emit_comment("Phase 'setup': configure texture and render mode"))
    lines.append(emit_comment("Phase 'triangles': submit cube triangles (MVP-transformed)"))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(512, 512))
    lines.append(emit_texture("checker_wb", f"{TEX0_BASE_WORD:05X}", "RGB565", 4))
    lines.append(emit_blank())
    lines.extend(_zclear_phase())
    lines.append(emit_blank())
    lines.extend(_setup_phase())
    lines.append(emit_blank())
    lines.extend(_triangles_phase())
    return lines
