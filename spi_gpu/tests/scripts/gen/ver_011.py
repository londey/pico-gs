"""VER-011: Depth-Tested Overlapping Triangles — hex generator.

Two overlapping flat-colored triangles at different depths.
Triangle A (far, red, Z=0x8000) rendered first; Triangle B (near, blue,
Z=0x4000) rendered second.  A Z-buffer clear pass precedes drawing.
Three phases: zclear, tri_a, tri_b.
"""

from common import *

ZBUFFER_BASE_512 = 0x0800


def _zclear_phase() -> list[str]:
    """Z-buffer clear: two screen-covering triangles with Z=0xFFFF."""
    lines = []
    lines.append(emit_phase("zclear"))
    lines.append(emit_blank())

    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, ZBUFFER_BASE_512, 9, 9),
                       "color_base=0x0000 z_base=0x0800 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 480),
                       "scissor x=0 y=0 w=512 h=480"))

    mode = Z_TEST_EN | Z_WRITE_EN | Z_COMPARE_ALWAYS
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    # C++ zclear uses pack_color(rgba(0,0,0)) with default specular=0xFF000000
    blk = rgba(0x00, 0x00, 0x00)

    # Triangle 1: (0,0)-(511,0)-(0,479)
    lines.append(emit_comment("Z-clear triangle 1: (0,0)-(511,0)-(0,479)"))
    for (x, y, kick) in [(0, 0, False), (511, 0, False), (0, 479, True)]:
        lines.append(emit(ADDR_COLOR, pack_color(blk),
                           color_comment(blk, 0xFF000000)))
        addr = ADDR_VERTEX_KICK_012 if kick else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex(x, y, 0xFFFF),
                           vertex_comment(x, y, 0xFFFF)))

    lines.append(emit_blank())

    # Triangle 2: (511,0)-(511,479)-(0,479)
    lines.append(emit_comment("Z-clear triangle 2: (511,0)-(511,479)-(0,479)"))
    for (x, y, kick) in [(511, 0, False), (511, 479, False), (0, 479, True)]:
        lines.append(emit(ADDR_COLOR, pack_color(blk),
                           color_comment(blk, 0xFF000000)))
        addr = ADDR_VERTEX_KICK_012 if kick else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex(x, y, 0xFFFF),
                           vertex_comment(x, y, 0xFFFF)))

    lines.append(emit_blank())
    lines.append(emit(ADDR_COLOR, 0, "dummy NOP (FIFO FWFT workaround)"))
    return lines


def _tri_a_phase() -> list[str]:
    """Triangle A: far, red, Z=0x8000."""
    lines = []
    lines.append(emit_phase("tri_a"))
    lines.append(emit_blank())

    mode = GOURAUD_EN | Z_TEST_EN | Z_WRITE_EN | COLOR_WRITE_EN | Z_COMPARE_LEQUAL
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    red = rgba(0xFF, 0x00, 0x00)
    spec = rgba(0x00, 0x00, 0x00)

    verts = [(80, 100, False), (320, 100, False), (200, 380, True)]
    for (x, y, kick) in verts:
        lines.append(emit(ADDR_COLOR, pack_color(red, spec),
                           color_comment(red, spec)))
        addr = ADDR_VERTEX_KICK_012 if kick else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex(x, y, 0x8000),
                           vertex_comment(x, y, 0x8000)))

    lines.append(emit_blank())
    lines.append(emit(ADDR_COLOR, 0, "dummy NOP (FIFO FWFT workaround)"))
    return lines


def _tri_b_phase() -> list[str]:
    """Triangle B: near, blue, Z=0x4000."""
    lines = []
    lines.append(emit_phase("tri_b"))
    lines.append(emit_blank())

    blue = rgba(0x00, 0x00, 0xFF)
    spec = rgba(0x00, 0x00, 0x00)

    verts = [(160, 80, False), (400, 80, False), (280, 360, True)]
    for (x, y, kick) in verts:
        lines.append(emit(ADDR_COLOR, pack_color(blue, spec),
                           color_comment(blue, spec)))
        addr = ADDR_VERTEX_KICK_012 if kick else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex(x, y, 0x4000),
                           vertex_comment(x, y, 0x4000)))

    lines.append(emit_blank())
    lines.append(emit(ADDR_COLOR, 0, "dummy NOP (FIFO FWFT workaround)"))
    return lines


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-011: Depth-Tested Overlapping Triangles"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("Phase 'zclear': initialize Z-buffer to 0xFFFF"))
    lines.append(emit_comment("Phase 'tri_a': red triangle at Z=0x8000 (far)"))
    lines.append(emit_comment("Phase 'tri_b': blue triangle at Z=0x4000 (near, occludes A)"))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(512, 480))
    lines.append(emit_blank())
    lines.extend(_zclear_phase())
    lines.append(emit_blank())
    lines.extend(_tri_a_phase())
    lines.append(emit_blank())
    lines.extend(_tri_b_phase())
    return lines
