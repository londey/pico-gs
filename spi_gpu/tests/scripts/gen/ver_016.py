"""VER-016: Perspective Road Z-Test — hex generator.

Two textured triangles forming a road that stretches from the bottom of the
screen into the distance.  Uses the full MVP pipeline so depth varies
smoothly from near (bottom) to far (top).  Checker texture shows perspective
foreshortening (affine — no per-pixel perspective correction).

Three phases: zclear, setup, triangles.
"""

import math

from common import *
from transforms import (
    mat4_mul, mat4_mul_vec4,
    mat4_look_at, mat4_perspective, perspective_divide, viewport_transform,
)

ZBUFFER_BASE_512 = 0x0800
# Place texture after the Z-buffer to avoid overlap.
TEX0_BASE_ADDR_512 = 0x0C00
TEX0_BASE_WORD = 0x0C00 * 256

# ---------------------------------------------------------------------------
# Road quad in world space
# ---------------------------------------------------------------------------
# A flat quad on the XZ plane (Y=0), stretching from z_near to z_far.
ROAD_WIDTH = 2.0
ROAD_NEAR = 2.0    # near edge (close to camera)
ROAD_FAR = 50.0    # far edge (vanishing point)

# 4 vertices: near-left, near-right, far-right, far-left
ROAD_VERTS = [
    (-ROAD_WIDTH, 0, -ROAD_NEAR),   # 0: near-left
    ( ROAD_WIDTH, 0, -ROAD_NEAR),   # 1: near-right
    ( ROAD_WIDTH, 0, -ROAD_FAR),    # 2: far-right
    (-ROAD_WIDTH, 0, -ROAD_FAR),    # 3: far-left
]

# UV: tile the checker texture multiple times along the road length.
UV_REPEATS_U = 2.0    # across the road
UV_REPEATS_V = 8.0    # along the road (Q4.12 max ~7.999; 16.0 overflows)

ROAD_UVS = [
    (0.0,           0.0),            # 0: near-left
    (UV_REPEATS_U,  0.0),            # 1: near-right
    (UV_REPEATS_U,  UV_REPEATS_V),   # 2: far-right
    (0.0,           UV_REPEATS_V),   # 3: far-left
]


def _zclear_phase() -> list[str]:
    """Z-buffer clear via MEM_FILL."""
    lines = []
    lines.append(emit_phase("zclear"))
    lines.append(emit_blank())

    # Clear color buffer
    lines.extend(emit_fb_clear(0x0000, 9, 9))
    lines.append(emit_blank())

    # Clear Z-buffer to 0x0000 (reverse-Z far plane; GEQUAL passes everything)
    fill_count = 512 * 512
    lines.append(emit(ADDR_MEM_FILL,
                       pack_mem_fill(ZBUFFER_BASE_512, 0x0000, fill_count),
                       mem_fill_comment(ZBUFFER_BASE_512, 0x0000, fill_count)))

    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, ZBUFFER_BASE_512, 9, 9),
                       "color_base=0x0000 z_base=0x0800 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 512),
                       "scissor x=0 y=0 w=512 h=512"))
    return lines


def _setup_phase() -> list[str]:
    """Configure texture and render mode."""
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


def _emit_tri(lines, verts, color):
    """Emit one textured triangle.

    verts: list of 3 tuples (sx_q4, sy_q4, z16, u, v, w).
    """
    shade = rgba(color[0], color[1], color[2])
    spec = rgba(0x00, 0x00, 0x00)

    for i, (sx, sy, z16, u, v, w) in enumerate(verts):
        q = q_perspective(w)
        lines.append(emit(ADDR_COLOR, pack_color(shade, spec),
                           color_comment(shade, spec)))
        lines.append(emit(ADDR_ST0_ST1, pack_st_perspective(u, v, w),
                           st_persp_comment(u, v, w)))
        is_kick = (i == 2)
        addr = ADDR_VERTEX_KICK_012 if is_kick else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex_q4(sx, sy, z16, q),
                           vertex_comment_q4(sx, sy, z16, q)))


def _triangles_phase() -> list[str]:
    """Transform road quad through MVP and emit two triangles."""
    lines = []
    lines.append(emit_phase("triangles"))
    lines.append(emit_blank())

    # Camera slightly above the road, looking down the -Z axis.
    eye = (0.0, 3.0, 2.0)
    center = (0.0, 0.0, -20.0)
    up = (0.0, 1.0, 0.0)

    view = mat4_look_at(eye=eye, center=center, up=up)
    proj = mat4_perspective(math.radians(60), 1.0, 1.0, 100.0)
    mvp = mat4_mul(proj, view)

    vp_w, vp_h = 512.0, 512.0

    # Transform all 4 road vertices.
    screen_verts = []
    for i, (vx, vy, vz) in enumerate(ROAD_VERTS):
        clip = mat4_mul_vec4(mvp, (vx, vy, vz, 1.0))
        ndc_x, ndc_y, ndc_z, w = perspective_divide(clip)
        sx, sy, sz = viewport_transform(ndc_x, ndc_y, ndc_z, vp_w, vp_h)

        sx_q4 = int(round(sx * 16.0))
        sy_q4 = int(round(sy * 16.0))
        z16 = int(round(sz * 65535.0))
        z16 = max(0, min(0xFFFF, z16))

        screen_verts.append((sx_q4, sy_q4, z16, ROAD_UVS[i][0], ROAD_UVS[i][1], w))

    # Two triangles: (0,1,2) and (0,2,3) — standard quad split.
    lines.append(emit_comment("Road triangle 1 (near-left, near-right, far-right)"))
    _emit_tri(lines, [screen_verts[0], screen_verts[1], screen_verts[2]],
              color=(0xFF, 0xFF, 0xFF))
    lines.append(emit_blank())

    lines.append(emit_comment("Road triangle 2 (near-left, far-right, far-left)"))
    _emit_tri(lines, [screen_verts[0], screen_verts[2], screen_verts[3]],
              color=(0xFF, 0xFF, 0xFF))
    lines.append(emit_blank())

    lines.append(emit(ADDR_COLOR, 0, "dummy NOP (FIFO FWFT workaround)"))
    return lines


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-016: Perspective Road Z-Test"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("Two-triangle road stretching into the distance."))
    lines.append(emit_comment("Tests Z interpolation and perspective depth gradient."))
    lines.append(emit_comment("Phase 'zclear': initialize Z-buffer to 0x0000 (reverse-Z far)"))
    lines.append(emit_comment("Phase 'setup': configure texture and render mode"))
    lines.append(emit_comment("Phase 'triangles': submit road quad (MVP-transformed)"))
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
