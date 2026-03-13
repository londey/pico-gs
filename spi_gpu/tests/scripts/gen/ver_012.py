"""VER-012: Textured Triangle Golden Image Test — hex generator.

Single textured triangle with 16x16 RGB565 white/black checker pattern.
Vertex colors are white so MODULATE produces texture_color * 1.0.
"""

from common import *

# Texture base address: 0x100000 byte address -> 0x0800 in 512-byte units
TEX0_BASE_ADDR_512 = 0x0800
TEX0_BASE_WORD = 0x80000


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-012: Textured Triangle Golden Image Test"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("Single textured triangle with 16x16 RGB565 checker pattern."))
    lines.append(emit_comment("White vertex colors; MODULATE produces texture * 1.0."))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(512, 512))
    lines.append(emit_phase("main"))
    lines.append(emit_blank())

    # Clear framebuffer
    lines.extend(emit_fb_clear(0x0000, 9, 9))
    lines.append(emit_blank())

    # Upload 16x16 white/black checker texture
    lines.extend(emit_checker_texture(TEX0_BASE_WORD, 4,
                                       RGB565_WHITE, RGB565_BLACK,
                                       "white/black checker"))
    lines.append(emit_blank())

    # Framebuffer config
    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, 0x0000, 9, 9),
                       "color_base=0x0000 z_base=0x0000 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 512),
                       "scissor x=0 y=0 w=512 h=512"))

    # TEX0_CFG: ENABLE=1, NEAREST, RGB565, 16x16, REPEAT, 0 mips
    tex_cfg = pack_tex0_cfg(1, 0, 4, 4, 4, 0, 0, 0, TEX0_BASE_ADDR_512)
    lines.append(emit(ADDR_TEX0_CFG, tex_cfg,
                       "ENABLE=1 NEAREST RGB565 16x16 REPEAT base=0x0800"))

    # Color combiner: MODULATE (TEX0 * SHADE0); white verts → texture pass-through
    lines.append(emit(ADDR_CC_MODE, CC_MODE_MODULATE,
                       "MODULATE: cycle0=TEX0*SHADE0 cycle1=COMBINED*ONE"))

    # Render mode: COLOR_WRITE only (no Gouraud, no Z)
    mode = COLOR_WRITE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    white = rgba(0xFF, 0xFF, 0xFF)
    spec = rgba(0x00, 0x00, 0x00)

    # V0: (320, 60) ST=(0.5, 0.0)
    lines.append(emit(ADDR_COLOR, pack_color(white, spec),
                       color_comment(white, spec)))
    lines.append(emit(ADDR_ST0_ST1, pack_st(0.5, 0.0), st_comment(0.5, 0.0)))
    lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex(320, 60, 0x0000, Q_AFFINE),
                       vertex_comment(320, 60, 0x0000)))
    lines.append(emit_blank())

    # V1: (511, 380) ST=(1.0, 1.0)
    lines.append(emit(ADDR_COLOR, pack_color(white, spec),
                       color_comment(white, spec)))
    lines.append(emit(ADDR_ST0_ST1, pack_st(1.0, 1.0), st_comment(1.0, 1.0)))
    lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex(511, 380, 0x0000, Q_AFFINE),
                       vertex_comment(511, 380, 0x0000)))
    lines.append(emit_blank())

    # V2: (100, 380) ST=(0.0, 1.0) — kick
    lines.append(emit(ADDR_COLOR, pack_color(white, spec),
                       color_comment(white, spec)))
    lines.append(emit(ADDR_ST0_ST1, pack_st(0.0, 1.0), st_comment(0.0, 1.0)))
    lines.append(emit(ADDR_VERTEX_KICK_012, pack_vertex(100, 380, 0x0000, Q_AFFINE),
                       vertex_comment(100, 380, 0x0000)))
    lines.append(emit_blank())

    return lines
