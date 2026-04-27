"""VER-016: Perspective Road Z-Test (INDEXED8_2X2) — hex generator.

Four textured triangles (two quads) forming a road that stretches from
the bottom of the screen into the distance.  Uses the full MVP pipeline
so depth varies smoothly from near (bottom) to far (top).  64x64
apparent INDEXED8_2X2 texture laid out as a 4x4 grid of 16x16 squares;
index 0 = solid white quadrants, index 1 = solid black quadrants
(uniform per-entry, so the visible pattern is encoded by the per-block
index variation rather than the quadrant trick).

The road is split into two strips to keep V coordinates within Q4.12
range (max 4.0 instead of 8.0 which would overflow).

Four phases: zclear, palette, setup, triangles.
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

PALETTE0_BASE_ADDR_512 = 0x0880

TEX_LOG2 = 6          # 64x64 apparent texture
SQUARE_SIZE = 16      # 16x16 apparent texel checker squares

# ---------------------------------------------------------------------------
# Road geometry in world space
# ---------------------------------------------------------------------------
ROAD_WIDTH = 2.0
ROAD_NEAR = 2.0    # near edge (close to camera)
ROAD_FAR = 50.0    # far edge (vanishing point)

NUM_STRIPS = 1     # 2 quads = 4 triangles

# UV: tile the checker texture along the road.
UV_REPEATS_U = 2.0    # across the road
UV_REPEATS_V = 7.0    # along the road (max V per vertex; fits Q4.12 signed)


def _build_indexed_checker(width_log2: int, square_size: int,
                           index_a: int, index_b: int) -> bytes:
    """Build the 4x4 block-tiled index array for a square checker texture.

    Each 16x16 apparent-pixel square corresponds to 2x2 INDEXED8_2X2
    blocks (one block covers 8x8 apparent texels).  All indices in a
    given block have the same value, so the per-quadrant lookup is
    trivial and the visible pattern is determined entirely by the
    inter-block checker.
    """
    apparent = 1 << width_log2
    index_dim = apparent >> 1
    blocks_per_row = index_dim >> 2
    # Each square is 2 blocks across (since 1 block = 8 apparent texels
    # and 1 square = 16 apparent texels).
    blocks_per_square = (square_size // 2) // 4

    out = bytearray(blocks_per_row * blocks_per_row * 16)
    for by in range(blocks_per_row):
        for bx in range(blocks_per_row):
            sq_x = bx // blocks_per_square
            sq_y = by // blocks_per_square
            value = index_b if (sq_x + sq_y) % 2 else index_a
            block_idx = by * blocks_per_row + bx
            base = block_idx * 16
            for i in range(16):
                out[base + i] = value
    return bytes(out)


def _zclear_phase() -> list[str]:
    """Z-buffer clear via MEM_FILL."""
    lines = []
    lines.append(emit_phase("zclear"))
    lines.append(emit_blank())

    lines.extend(emit_fb_clear(0x0000, 9, 9))
    lines.append(emit_blank())

    # Z-buffer clear is handled by the tile cache lazy-fill: FB_CONFIG
    # write resets Hi-Z metadata, and on cache miss to an uninitialised
    # tile the cache fills the line with 0x0000.
    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, ZBUFFER_BASE_512, 9, 9),
                       "color_base=0x0000 z_base=0x0800 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 512),
                       "scissor x=0 y=0 w=512 h=512"))
    return lines


def _palette_phase() -> list[str]:
    """Stage palette payload + index array, trigger PALETTE0 load."""
    lines = []
    lines.append(emit_phase("palette"))
    lines.append(emit_blank())

    # Two palette entries: 0 = solid white, 1 = solid black (opaque).
    palette_entries = [
        (RGBA_WHITE, RGBA_WHITE, RGBA_WHITE, RGBA_WHITE),
        (RGBA_BLACK, RGBA_BLACK, RGBA_BLACK, RGBA_BLACK),
    ]
    lines.extend(emit_palette_upload(PALETTE0_BASE_ADDR_512, palette_entries, slot=0))
    lines.append(emit_blank())

    indices = _build_indexed_checker(TEX_LOG2, SQUARE_SIZE,
                                     index_a=0, index_b=1)
    lines.extend(emit_indexed_texture_block(
        TEX0_BASE_WORD, indices,
        label=f"{1 << TEX_LOG2}x{1 << TEX_LOG2} INDEXED8_2X2 checker indices",
    ))
    lines.append(emit_blank())
    return lines


def _setup_phase() -> list[str]:
    """Configure texture and render mode."""
    lines = []
    lines.append(emit_phase("setup"))
    lines.append(emit_blank())

    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, ZBUFFER_BASE_512, 9, 9),
                       "color_base=0x0000 z_base=0x0800 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 512),
                       "scissor x=0 y=0 w=512 h=512"))

    tex_cfg = pack_tex_cfg_indexed(
        enable=1, width_log2=TEX_LOG2, height_log2=TEX_LOG2,
        u_wrap=0, v_wrap=0, palette_idx=0,
        base_addr_512=TEX0_BASE_ADDR_512,
    )
    lines.append(emit(ADDR_TEX0_CFG, tex_cfg,
                       f"ENABLE=1 NEAREST INDEXED8_2X2 {1 << TEX_LOG2}x"
                       f"{1 << TEX_LOG2} REPEAT PALETTE_IDX=0 "
                       f"base=0x{TEX0_BASE_ADDR_512:04X}"))

    lines.append(emit(ADDR_CC_MODE, CC_MODE_MODULATE,
                       "MODULATE: cycle0=TEX0*SHADE0 cycle1=COMBINED*ONE"))

    mode = GOURAUD_EN | Z_TEST_EN | Z_WRITE_EN | COLOR_WRITE_EN | Z_COMPARE_GEQUAL
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))

    lines.append(emit_blank())
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
    """Transform road strips through MVP and emit 4 triangles (2 quads)."""
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

    # Build NUM_STRIPS+1 rows of vertices along the road (left, right per row).
    rows = []
    for row in range(NUM_STRIPS + 1):
        t = row / NUM_STRIPS
        z_world = ROAD_NEAR + t * (ROAD_FAR - ROAD_NEAR)
        v_coord = (t * UV_REPEATS_V) - 4.0

        row_verts = []
        for side, u_coord in [(-ROAD_WIDTH, 0.0), (ROAD_WIDTH, UV_REPEATS_U)]:
            world = (side, 0.0, -z_world)
            clip = mat4_mul_vec4(mvp, (world[0], world[1], world[2], 1.0))
            ndc_x, ndc_y, ndc_z, w = perspective_divide(clip)
            sx, sy, sz = viewport_transform(ndc_x, ndc_y, ndc_z, vp_w, vp_h)

            sx_q4 = int(round(sx * 16.0))
            sy_q4 = int(round(sy * 16.0))
            z16 = int(round(sz * 65535.0))
            z16 = max(0, min(0xFFFF, z16))

            row_verts.append((sx_q4, sy_q4, z16, u_coord, v_coord, w))
        rows.append(row_verts)

    for s in range(NUM_STRIPS):
        nl, nr = rows[s]      # near-left, near-right
        fl, fr = rows[s + 1]  # far-left, far-right

        lines.append(emit_comment(
            f"Strip {s} tri 1 (near-left, near-right, far-right)"))
        _emit_tri(lines, [nl, nr, fr], color=(0xFF, 0x00, 0x00))
        lines.append(emit_blank())

        lines.append(emit_comment(
            f"Strip {s} tri 2 (near-left, far-right, far-left)"))
        _emit_tri(lines, [nl, fr, fl], color=(0x00, 0xFF, 0x00))
        lines.append(emit_blank())

    return lines


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-016: Perspective Road Z-Test (INDEXED8_2X2)"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("Four-triangle road (2 quads) stretching into the distance."))
    lines.append(emit_comment("64x64 apparent INDEXED8_2X2 texture: 4x4 grid of 16x16 squares,"))
    lines.append(emit_comment("index 0 = white, index 1 = black (uniform per-entry)."))
    lines.append(emit_comment("Road split into strips to keep V within Q4.12 range (max 4.0)."))
    lines.append(emit_comment("Phase 'zclear':    initialise Z-buffer to 0x0000 (reverse-Z far)"))
    lines.append(emit_comment("Phase 'palette':   stage palette + index array, trigger PALETTE0"))
    lines.append(emit_comment("Phase 'setup':     configure texture and render mode"))
    lines.append(emit_comment("Phase 'triangles': submit road strips (MVP-transformed)"))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(512, 512))
    lines.append(emit_blank())
    lines.extend(_zclear_phase())
    lines.append(emit_blank())
    lines.extend(_palette_phase())
    lines.append(emit_blank())
    lines.extend(_setup_phase())
    lines.append(emit_blank())
    lines.extend(_triangles_phase())
    return lines
