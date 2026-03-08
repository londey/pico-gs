"""VER-015: Triangle Size Grid Golden Image Test — hex generator.

8 Gouraud-shaded triangles in a 4x2 grid with sizes 1, 2, 4, 8, 16, 32,
64, 128 pixels per side.  Same red/green/blue vertex coloring as VER-010.
Uses Q12.4 sub-pixel coordinates.
"""

from common import *

# Grid layout: 4 columns x 2 rows
# Column centers: 64, 192, 320, 448 pixels
# Row centers: 120, 360 pixels
# Sizes (pixels): 1, 2, 4, 8, 16, 32, 64, 128
# Half-sizes (Q12.4): 8, 16, 32, 64, 128, 256, 512, 1024

TRIANGLES = [
    # (cx_px, cy_px, half_size_q4, label)
    ( 64, 120,    8, "1px"),
    (192, 120,   16, "2px"),
    (320, 120,   32, "4px"),
    (448, 120,   64, "8px"),
    ( 64, 360,  128, "16px"),
    (192, 360,  256, "32px"),
    (320, 360,  512, "64px"),
    (448, 360, 1024, "128px"),
]


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-015: Triangle Size Grid Golden Image Test"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("8 Gouraud triangles in 4x2 grid, sizes 1-128px per side."))
    lines.append(emit_comment("Red top, blue bottom-right, green bottom-left."))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(512, 480))
    lines.append(emit_phase("main"))
    lines.append(emit_blank())

    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, 0x0000, 9, 9),
                       "color_base=0x0000 z_base=0x0000 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 480),
                       "scissor x=0 y=0 w=512 h=480"))

    mode = GOURAUD_EN | COLOR_WRITE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    red = rgba(0xFF, 0x00, 0x00)
    blue = rgba(0x00, 0x00, 0xFF)
    green = rgba(0x00, 0xFF, 0x00)
    spec_default = 0xFF000000  # pack_color default specular

    for i, (cx_px, cy_px, hs, label) in enumerate(TRIANGLES):
        cx = cx_px * 16  # Q12.4
        cy = cy_px * 16  # Q12.4

        lines.append(emit_comment(f"Triangle {i}: {label} (half-size={hs} Q12.4)"))

        # V0: top center — red
        x0, y0 = cx, cy - hs
        lines.append(emit(ADDR_COLOR, pack_color(red, spec_default),
                           color_comment(red, spec_default)))
        lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex_q4(x0, y0, 0),
                           vertex_comment_q4(x0, y0, 0)))

        # V1: bottom right — blue
        x1, y1 = cx + hs, cy + hs
        lines.append(emit(ADDR_COLOR, pack_color(blue, spec_default),
                           color_comment(blue, spec_default)))
        lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex_q4(x1, y1, 0),
                           vertex_comment_q4(x1, y1, 0)))

        # V2: bottom left — green (kick)
        x2, y2 = cx - hs, cy + hs
        lines.append(emit(ADDR_COLOR, pack_color(green, spec_default),
                           color_comment(green, spec_default)))
        lines.append(emit(ADDR_VERTEX_KICK_012, pack_vertex_q4(x2, y2, 0),
                           vertex_comment_q4(x2, y2, 0)))

        lines.append(emit_blank())

    # Trailing dummy
    lines.append(emit(ADDR_COLOR, 0, "dummy NOP (FIFO FWFT workaround)"))
    return lines
