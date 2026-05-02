"""VER-010: Gouraud Triangle Golden Image Test — hex generator.

Single Gouraud-shaded triangle with red (top), green (bottom-left),
and blue (bottom-right) vertices on a 512x480 framebuffer.
"""

from common import *


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-010: Gouraud Triangle Golden Image Test"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("Single Gouraud-shaded triangle: red top, blue bottom-right,"))
    lines.append(emit_comment("green bottom-left.  512x480 framebuffer, no Z testing."))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(512, 480))
    lines.append(emit_phase("main"))
    lines.append(emit_blank())

    # Clear framebuffer
    lines.extend(emit_fb_clear(0x0000, 9, 9))
    lines.append(emit_blank())

    # Framebuffer config
    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, 0x0000, 9, 9),
                       "color_base=0x0000 z_base=0x0000 w_log2=9 h_log2=9"))

    # Scissor
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 480),
                       "scissor x=0 y=0 w=512 h=480"))

    # Color combiner: shade0 pass-through
    lines.append(emit(ADDR_CC_MODE, CC_MODE_SHADE_PASSTHROUGH,
                       "SHADE_PASSTHROUGH: cycle0=SHADE0*ONE cycle1=COMBINED*ONE"))

    # Render mode
    mode = GOURAUD_EN | COLOR_WRITE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))

    lines.append(emit_blank())

    # V0: red at (256, 40)
    # C++ pack_color default specular = 0xFF000000
    diff = rgba(0xFF, 0x00, 0x00)
    lines.append(emit(ADDR_COLOR, pack_color(diff),
                       color_comment(diff, 0xFF000000)))
    lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex(256, 40, 0x0000),
                       vertex_comment(256, 40, 0x0000)))

    lines.append(emit_blank())

    # V1: blue at (448, 400)
    diff = rgba(0x00, 0x00, 0xFF)
    lines.append(emit(ADDR_COLOR, pack_color(diff),
                       color_comment(diff, 0xFF000000)))
    lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex(448, 400, 0x0000),
                       vertex_comment(448, 400, 0x0000)))

    lines.append(emit_blank())

    # V2: green at (64, 400) — kick
    diff = rgba(0x00, 0xFF, 0x00)
    lines.append(emit(ADDR_COLOR, pack_color(diff),
                       color_comment(diff, 0xFF000000)))
    lines.append(emit(ADDR_VERTEX_KICK_012, pack_vertex(64, 400, 0x0000),
                       vertex_comment(64, 400, 0x0000)))

    lines.append(emit_blank())

    lines.extend(emit_fb_cache_flush())

    return lines
