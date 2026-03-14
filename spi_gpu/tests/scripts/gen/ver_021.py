"""VER-021: RGBA8888 Texture Golden Image Test — hex generator.

Textured quad with 256x256 RGBA8888 uncompressed Skyline R32 texture atlas
rendered into a 512x480 framebuffer.
White vertex colors; MODULATE produces texture pass-through.
Tests RGBA8888 4x4-tiled uncompressed decode path.
"""

from common import *
from textures import TEX_SLOT_0_512


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-021: RGBA8888 Texture Golden Image Test"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("256x256 RGBA8888 uncompressed Skyline texture on a 512x480 quad."))
    lines.append(emit_comment("Tests 32bpp 4x4-tiled uncompressed decode path."))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(512, 480))
    lines.append(emit_phase("main"))
    lines.append(emit_blank())

    # Clear framebuffer (512x512 backing surface)
    lines.extend(emit_fb_clear(0x0000, 9, 9))
    lines.append(emit_blank())

    # Include shared RGBA8888 texture data
    lines.append("## INCLUDE: textures/skyline_256x256_rgba8888.hex")
    lines.append(emit_blank())

    # Framebuffer config: 512x512 backing surface (w_log2=9, h_log2=9)
    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, 0x0000, 9, 9),
                       "color_base=0x0000 z_base=0x0000 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 480),
                       "scissor x=0 y=0 w=512 h=480"))

    # TEX0_CFG: ENABLE=1, NEAREST, RGBA8888 (format 5), 256x256, REPEAT, 0 mips
    tex_cfg = pack_tex0_cfg(1, 0, 5, 8, 8, 0, 0, 0, TEX_SLOT_0_512)
    lines.append(emit(ADDR_TEX0_CFG, tex_cfg,
                       "ENABLE=1 NEAREST RGBA8888 256x256 REPEAT base=0x%04X"
                       % TEX_SLOT_0_512))

    # Color combiner: MODULATE
    lines.append(emit(ADDR_CC_MODE, CC_MODE_MODULATE,
                       "MODULATE: cycle0=TEX0*SHADE0 cycle1=COMBINED*ONE"))

    # Render mode: COLOR_WRITE only
    mode = COLOR_WRITE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    white = rgba(0xFF, 0xFF, 0xFF)
    spec = rgba(0x00, 0x00, 0x00)

    # Quad as two triangles covering the 512x480 viewport
    for tri in [((0,0,0.0,0.0), (512,0,1.0,0.0), (512,480,1.0,1.0)),
                ((0,0,0.0,0.0), (512,480,1.0,1.0), (0,480,0.0,1.0))]:
        for vi, (x, y, u, v) in enumerate(tri):
            lines.append(emit(ADDR_COLOR, pack_color(white, spec),
                               color_comment(white, spec)))
            lines.append(emit(ADDR_ST0_ST1, pack_st(u, v), st_comment(u, v)))
            kick = ADDR_VERTEX_KICK_012 if vi == 2 else ADDR_VERTEX_NOKICK
            lines.append(emit(kick, pack_vertex(x, y, 0x0000, Q_AFFINE),
                               vertex_comment(x, y, 0x0000)))
            lines.append(emit_blank())

    return lines
