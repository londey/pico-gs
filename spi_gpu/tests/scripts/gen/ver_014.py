"""VER-014: Textured Cube Golden Image Test — hex generator.

12-triangle cube (6 faces) with depth testing and white/black checker
texture.  Three phases: zclear, setup, triangles.
"""

from common import *

ZBUFFER_BASE_512 = 0x0800
TEX0_BASE_ADDR_512 = 0x0800
TEX0_BASE_WORD = 0x80000


def _zclear_phase() -> list[str]:
    """Z-buffer clear for 512x512 surface."""
    lines = []
    lines.append(emit_phase("zclear"))
    lines.append(emit_blank())

    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, ZBUFFER_BASE_512, 9, 9),
                       "color_base=0x0000 z_base=0x0800 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 512),
                       "scissor x=0 y=0 w=512 h=512"))

    mode = Z_TEST_EN | Z_WRITE_EN | Z_COMPARE_ALWAYS
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    blk = rgba(0x00, 0x00, 0x00)
    spec = rgba(0x00, 0x00, 0x00)

    lines.append(emit_comment("Z-clear triangle 1: (0,0)-(511,0)-(0,511)"))
    for (x, y, kick) in [(0, 0, False), (511, 0, False), (0, 511, True)]:
        lines.append(emit(ADDR_COLOR, pack_color(blk, spec), color_comment(blk, spec)))
        addr = ADDR_VERTEX_KICK_012 if kick else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex(x, y, 0xFFFF), vertex_comment(x, y, 0xFFFF)))

    lines.append(emit_blank())

    lines.append(emit_comment("Z-clear triangle 2: (511,0)-(511,511)-(0,511)"))
    for (x, y, kick) in [(511, 0, False), (511, 511, False), (0, 511, True)]:
        lines.append(emit(ADDR_COLOR, pack_color(blk, spec), color_comment(blk, spec)))
        addr = ADDR_VERTEX_KICK_012 if kick else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex(x, y, 0xFFFF), vertex_comment(x, y, 0xFFFF)))

    lines.append(emit_blank())
    lines.append(emit(ADDR_COLOR, 0, "dummy NOP (FIFO FWFT workaround)"))
    return lines


def _setup_phase() -> list[str]:
    """Configure texture and render mode for depth-tested textured rendering."""
    lines = []
    lines.append(emit_phase("setup"))
    lines.append(emit_blank())

    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, ZBUFFER_BASE_512, 9, 9),
                       "color_base=0x0000 z_base=0x0800 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 512),
                       "scissor x=0 y=0 w=512 h=512"))

    tex_cfg = pack_tex0_cfg(1, 0, 4, 4, 4, 0, 0, 0, TEX0_BASE_ADDR_512)
    lines.append(emit(ADDR_TEX0_CFG, tex_cfg,
                       "ENABLE=1 NEAREST RGB565 16x16 REPEAT base=0x0800"))

    mode = GOURAUD_EN | Z_TEST_EN | Z_WRITE_EN | COLOR_WRITE_EN | Z_COMPARE_LEQUAL
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))

    lines.append(emit_blank())
    lines.append(emit(ADDR_COLOR, 0, "dummy NOP (FIFO FWFT workaround)"))
    return lines


def _emit_tri(lines, verts, kick_addr):
    """Emit one textured white triangle.

    verts: [(x, y, z, u, v), ...] — 3 vertices.
    kick_addr: ADDR_VERTEX_KICK_012 or ADDR_VERTEX_KICK_021.
    """
    white = rgba(0xFF, 0xFF, 0xFF)
    spec = rgba(0x00, 0x00, 0x00)

    for i, (x, y, z, u, v) in enumerate(verts):
        lines.append(emit(ADDR_COLOR, pack_color(white, spec),
                           color_comment(white, spec)))
        lines.append(emit(ADDR_UV0_UV1, pack_uv(u, v), uv_comment(u, v)))
        is_kick = (i == 2)
        addr = kick_addr if is_kick else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex(x, y, z), vertex_comment(x, y, z)))


def _triangles_phase() -> list[str]:
    """All 12 cube triangles."""
    lines = []
    lines.append(emit_phase("triangles"))
    lines.append(emit_blank())

    # Face 1: -Z (back face, Z=0x5800) — KICK_021
    lines.append(emit_comment("Face 1: -Z (back face, Z=0x5800)"))
    _emit_tri(lines, [
        (192, 192, 0x5800, 0.0, 0.0),
        (192, 320, 0x5800, 0.0, 1.0),
        (320, 192, 0x5800, 1.0, 0.0),
    ], ADDR_VERTEX_KICK_021)
    lines.append(emit_blank())

    _emit_tri(lines, [
        (320, 192, 0x5800, 1.0, 0.0),
        (192, 320, 0x5800, 0.0, 1.0),
        (320, 320, 0x5800, 1.0, 1.0),
    ], ADDR_VERTEX_KICK_021)
    lines.append(emit_blank())

    # Face 2: -X (left face) — KICK_021
    lines.append(emit_comment("Face 2: -X (left face)"))
    _emit_tri(lines, [
        (128, 128, 0x3800, 1.0, 0.0),
        ( 64, 192, 0x4800, 0.0, 0.0),
        (128, 384, 0x3800, 1.0, 1.0),
    ], ADDR_VERTEX_KICK_021)
    lines.append(emit_blank())

    _emit_tri(lines, [
        ( 64, 192, 0x4800, 0.0, 0.0),
        ( 64, 320, 0x4800, 0.0, 1.0),
        (128, 384, 0x3800, 1.0, 1.0),
    ], ADDR_VERTEX_KICK_021)
    lines.append(emit_blank())

    # Face 3: -Y (bottom face) — KICK_021
    lines.append(emit_comment("Face 3: -Y (bottom face)"))
    _emit_tri(lines, [
        (128, 384, 0x3800, 0.0, 0.0),
        (384, 384, 0x3800, 1.0, 0.0),
        (192, 448, 0x4800, 0.0, 1.0),
    ], ADDR_VERTEX_KICK_021)
    lines.append(emit_blank())

    _emit_tri(lines, [
        (384, 384, 0x3800, 1.0, 0.0),
        (320, 448, 0x4800, 1.0, 1.0),
        (192, 448, 0x4800, 0.0, 1.0),
    ], ADDR_VERTEX_KICK_021)
    lines.append(emit_blank())

    # Face 4: +X (right face) — KICK_012
    lines.append(emit_comment("Face 4: +X (right face, front-visible)"))
    _emit_tri(lines, [
        (384, 128, 0x3800, 0.0, 0.0),
        (448, 192, 0x4800, 1.0, 0.0),
        (384, 384, 0x3800, 0.0, 1.0),
    ], ADDR_VERTEX_KICK_012)
    lines.append(emit_blank())

    _emit_tri(lines, [
        (448, 192, 0x4800, 1.0, 0.0),
        (448, 320, 0x4800, 1.0, 1.0),
        (384, 384, 0x3800, 0.0, 1.0),
    ], ADDR_VERTEX_KICK_012)
    lines.append(emit_blank())

    # Face 5: +Y (top face) — KICK_012
    lines.append(emit_comment("Face 5: +Y (top face, front-visible)"))
    _emit_tri(lines, [
        (128, 128, 0x3800, 0.0, 0.0),
        (384, 128, 0x3800, 1.0, 0.0),
        (192,  64, 0x4800, 0.5, 1.0),
    ], ADDR_VERTEX_KICK_012)
    lines.append(emit_blank())

    _emit_tri(lines, [
        (384, 128, 0x3800, 1.0, 0.0),
        (320,  64, 0x4800, 1.0, 1.0),
        (192,  64, 0x4800, 0.5, 1.0),
    ], ADDR_VERTEX_KICK_012)
    lines.append(emit_blank())

    # Face 6: +Z (front face, Z=0x3800) — KICK_012
    lines.append(emit_comment("Face 6: +Z (front face, nearest)"))
    _emit_tri(lines, [
        (128, 128, 0x3800, 0.0, 0.0),
        (384, 128, 0x3800, 1.0, 0.0),
        (128, 384, 0x3800, 0.0, 1.0),
    ], ADDR_VERTEX_KICK_012)
    lines.append(emit_blank())

    _emit_tri(lines, [
        (384, 128, 0x3800, 1.0, 0.0),
        (384, 384, 0x3800, 1.0, 1.0),
        (128, 384, 0x3800, 0.0, 1.0),
    ], ADDR_VERTEX_KICK_012)
    lines.append(emit_blank())

    lines.append(emit(ADDR_COLOR, 0, "dummy NOP (FIFO FWFT workaround)"))
    return lines


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-014: Textured Cube Golden Image Test"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("12-triangle cube with depth testing and checker texture."))
    lines.append(emit_comment("Phase 'zclear': initialize Z-buffer to 0xFFFF"))
    lines.append(emit_comment("Phase 'setup': configure texture and render mode"))
    lines.append(emit_comment("Phase 'triangles': submit 12 cube triangles"))
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
