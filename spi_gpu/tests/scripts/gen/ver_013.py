"""VER-013: Color-Combined Output Golden Image Test — hex generator.

Textured triangle with MODULATE color combiner.  White/mid-gray checker
texture, Gouraud-shaded red/green/blue vertex colors.
"""

from common import *

TEX0_BASE_ADDR_512 = 0x0800
TEX0_BASE_WORD = 0x80000

# MODULATE CC_MODE:
#   Cycle 0: A=TEX0(1), B=ZERO(7), C=SHADE0(3), D=ZERO(7)
#   Cycle 1: A=COMBINED(0), B=ZERO(7), C=ONE(6), D=ZERO(7) (pass-through)
CC_MODE_MODULATE = 0x7670767073717371


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-013: Color-Combined Output Golden Image Test"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("Textured triangle with MODULATE combiner (TEX0 * SHADE0)."))
    lines.append(emit_comment("16x16 white/mid-gray checker; red/green/blue vertex colors."))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(512, 512))
    lines.append(emit_texture("checker_wg", f"{TEX0_BASE_WORD:05X}", "RGB565", 4))
    lines.append(emit_phase("main"))
    lines.append(emit_blank())

    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, 0x0000, 9, 9),
                       "color_base=0x0000 z_base=0x0000 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 512),
                       "scissor x=0 y=0 w=512 h=512"))

    tex_cfg = pack_tex0_cfg(1, 0, 4, 4, 4, 0, 0, 0, TEX0_BASE_ADDR_512)
    lines.append(emit(ADDR_TEX0_CFG, tex_cfg,
                       "ENABLE=1 NEAREST RGB565 16x16 REPEAT base=0x0800"))

    lines.append(emit(ADDR_CC_MODE, CC_MODE_MODULATE,
                       "MODULATE: cycle0=TEX0*SHADE0 cycle1=COMBINED*ONE"))

    mode = GOURAUD_EN | COLOR_WRITE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    spec = rgba(0x00, 0x00, 0x00)

    # V0: red at (320, 60) ST=(0.5, 0.0)
    red = rgba(0xFF, 0x00, 0x00)
    lines.append(emit(ADDR_COLOR, pack_color(red, spec), color_comment(red, spec)))
    lines.append(emit(ADDR_ST0_ST1, pack_st(0.5, 0.0), st_comment(0.5, 0.0)))
    lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex(320, 60, 0x0000),
                       vertex_comment(320, 60, 0x0000)))
    lines.append(emit_blank())

    # V1: blue at (511, 380) ST=(1.0, 1.0)
    blue = rgba(0x00, 0x00, 0xFF)
    lines.append(emit(ADDR_COLOR, pack_color(blue, spec), color_comment(blue, spec)))
    lines.append(emit(ADDR_ST0_ST1, pack_st(1.0, 1.0), st_comment(1.0, 1.0)))
    lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex(511, 380, 0x0000),
                       vertex_comment(511, 380, 0x0000)))
    lines.append(emit_blank())

    # V2: green at (100, 380) ST=(0.0, 1.0) — kick
    green = rgba(0x00, 0xFF, 0x00)
    lines.append(emit(ADDR_COLOR, pack_color(green, spec), color_comment(green, spec)))
    lines.append(emit(ADDR_ST0_ST1, pack_st(0.0, 1.0), st_comment(0.0, 1.0)))
    lines.append(emit(ADDR_VERTEX_KICK_012, pack_vertex(100, 380, 0x0000),
                       vertex_comment(100, 380, 0x0000)))
    lines.append(emit_blank())

    lines.append(emit(ADDR_COLOR, 0, "dummy NOP (FIFO FWFT workaround)"))
    return lines
